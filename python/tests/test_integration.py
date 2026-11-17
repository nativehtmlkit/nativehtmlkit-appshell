"""Real uv/worker integration, opt-in or runs when uv is available. No native GUI required."""
import shutil
import subprocess
from pathlib import Path
import pytest

from nativehtmlkit_appshell.scaffold import generate_python
from nativehtmlkit_appshell.runtime import AppShellRuntime
from nativehtmlkit_appshell.storage import Store


@pytest.mark.integration
@pytest.mark.skipif(shutil.which('uv') is None, reason='uv not found')
def test_local_uv_install_worker_and_actions(tmp_path):
    source=generate_python('org.example.greeter',tmp_path/'greeter')
    # Build from host toolchain without fetching build requirements; install the wheel
    # with uv in an independent extension venv. Source-install with fresh deps is
    # separately qualified on a machine with internet or an internal package mirror.
    wheels=tmp_path/'wheels'
    process=subprocess.run(['uv','build','--offline','--no-build-isolation','--out-dir',str(wheels)],
                           cwd=source, capture_output=True,text=True)
    if process.returncode:
        pytest.skip('Offline wheel build backend unavailable: '+process.stderr[-200:])
    wheel=next(wheels.glob('*.whl'))
    store=Store(tmp_path/'home');store.prepare()
    store.stage(str(wheel))
    r=AppShellRuntime(store)
    try:
        r.boot()
        assert r.status.get('org.example.greeter') == 'ACTIVE', r.errors
        view=r.page('org.example.greeter','overview')
        assert view['title'] == 'Greeter'
        result=r.action('org.example.greeter','refresh',{}, {})
        assert result['refresh'] is True
        result=r.action('org.example.greeter','save',{'message':'hello'}, {})
        assert result['refresh'] is True
        assert (store.data/'org.example.greeter'/'message.txt').read_text()=='hello'
    finally:
        r.stop()
    # No pending installs on next boot; worker still operates from promoted release.
    again=AppShellRuntime(store)
    try:
        again.boot()
        assert again.page('org.example.greeter','overview')['title'] == 'Greeter'
    finally:
        again.stop()
