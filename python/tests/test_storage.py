import json
from pathlib import Path
import pytest

from nativehtmlkit_appshell.scaffold import generate_python
from nativehtmlkit_appshell.storage import Store, StateError, json_load


def test_generator_builds_python_package(tmp_path):
    result=generate_python('org.example.greeter', tmp_path/'generated', title='Greeter')
    assert (result/'pyproject.toml').exists()
    assert 'nativehtmlkit.appshell.extensions' in (result/'pyproject.toml').read_text()
    with pytest.raises(ValueError): generate_python('org.example.greeter', result)


def test_staging_and_pending(tmp_path):
    store=Store(tmp_path/'home'); store.prepare()
    source=generate_python('org.example.greeter', tmp_path/'project')
    token=store.stage(str(source))
    assert len(token) == 16
    pending=store.pending()['operations']
    assert len(pending)==1
    assert pending[0]['source']['kind']=='local'
    copied=store.resolve_owned(pending[0]['source']['path'])
    assert (copied/'pyproject.toml').is_file()
    assert len(store.pop_pending())==1
    assert store.pending()['operations'] == []


def test_requires_pinned_package(tmp_path):
    store=Store(tmp_path/'home'); store.prepare()
    assert store.stage('demo_package==1.2.3')
    for bad in ('not-pinned', 'git+https://github.com/user/repo@main',
                'https://malicious.example/evil.whl', '-e /etc/shadow', 'abc;uname -a'):
        with pytest.raises(StateError): store.stage(bad)


def test_symlinks_and_size_rejected(tmp_path):
    store=Store(tmp_path/'home'); store.prepare()
    src=tmp_path/'code'; src.mkdir(); (src/'pyproject.toml').write_text('[project]\n')
    (src/'unsafe').symlink_to(tmp_path)
    with pytest.raises(StateError): store.stage(str(src))


def test_last_known_good_recovery(tmp_path):
    store=Store(tmp_path/'home'); store.prepare()
    assert store.begin_session() is None
    original={"version":1,"extensions":{"org.example.a":{"id":"org.example.a"}}}
    store.save_registry(original)
    store.clean_exit()
    assert store.last_good_path.is_file()
    store.begin_session()
    store.save_registry({"version":1,"extensions":{"org.example.bad":{"id":"org.example.bad"}}})
    # Unexpected termination leaves the marker; the OS releases a dead process's session lock.
    store._release_session()
    reason=store.begin_session()
    assert 'restored' in reason.lower()
    assert store.registry()['extensions'] == original['extensions']


def test_manual_restore_on_start(tmp_path):
    store=Store(tmp_path/'home'); store.prepare()
    store.save_registry({"version":1,"extensions":{"org.example.a":{}}})
    store.begin_session(); store.clean_exit()
    store.save_registry({"version":1,"extensions":{"org.example.new":{}}})
    (store.home/'restore-on-next-start').write_text('1')
    store.begin_session()
    assert 'org.example.a' in store.registry()['extensions']
    store.end_session()
