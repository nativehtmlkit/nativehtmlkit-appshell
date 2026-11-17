"""Real native host in headless test mode (NATIVEHTMLKIT_TEST_MODE=1) driving the AppShell Desktop."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

from nativehtmlkit_appshell.scaffold import generate_python
from nativehtmlkit_appshell.storage import Store, json_load

from showcase_extension import SHOWCASE

pytestmark = [pytest.mark.integration, pytest.mark.native,
              pytest.mark.skipif(shutil.which("uv") is None, reason="uv not found")]
HERE = Path(__file__).resolve().parent


def _alive(pid: int) -> bool:
    if os.name == "nt":
        out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True).stdout
        return str(pid) in out
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def test_desktop_scenario_on_native_host(tmp_path):
    project = generate_python("org.example.showcase", tmp_path / "showcase")
    pkg = next((project / "src").iterdir())
    (pkg / "__init__.py").write_text(SHOWCASE, encoding="utf-8")
    wheels = tmp_path / "wheels"
    build = subprocess.run(["uv", "build", "--offline", "--no-build-isolation", "--python", sys.executable,
                            "--wheel", "--out-dir", str(wheels)], cwd=project, capture_output=True, text=True)
    if build.returncode:
        pytest.skip("Offline wheel build backend unavailable: " + build.stderr[-300:])
    store = Store(tmp_path / "home")
    store.prepare()
    store.stage(str(next(wheels.glob("*.whl"))))
    out = tmp_path / "scenario.json"
    env = dict(os.environ, NATIVEHTMLKIT_TEST_MODE="1", APPSHELL_HOME=str(store.home),
               PYTHONPATH=str(HERE.parent / "src"))
    proc = subprocess.run([sys.executable, str(HERE / "desktop_scenario.py"), str(out)], env=env,
                          capture_output=True, text=True, timeout=600, cwd=tmp_path)
    assert out.is_file(), f"no scenario result; exit {proc.returncode}\n{proc.stdout[-2000:]}\n{proc.stderr[-4000:]}"
    results = json.loads(out.read_text("utf-8"))
    report = "\n".join(f"{'PASS' if c['ok'] else 'FAIL'} {c['name']} {'' if c['ok'] else c['detail']}"
                       for c in results["checks"])
    print(report)
    print("timings", results["timings"])
    assert results["finished"] and not results["failed"], report + "\n" + proc.stderr[-3000:]
    assert len(results["checks"]) >= 50
    assert proc.returncode == 0, proc.stderr[-3000:]
    assert not [p for p in results.get("worker_pids", []) if _alive(p)], "orphan extension workers"
    assert not store.session_path.exists(), "clean exit must remove the session marker"
    assert "org.example.showcase" in json_load(store.last_good_path, {})["extensions"]
    assert "Traceback" not in proc.stderr, proc.stderr[-3000:]
