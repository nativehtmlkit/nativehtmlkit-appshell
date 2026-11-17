"""Extension lifecycle and failure paths with real uv environments and worker processes.

No native GUI. Each test uses its own disposable AppShell home under pytest's tmp_path.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap
import threading
import time

import pytest

from nativehtmlkit_appshell.runtime import AppShellRuntime
from nativehtmlkit_appshell.scaffold import generate_python
from nativehtmlkit_appshell.storage import Store, StateError, json_load
from nativehtmlkit_appshell.worker_client import OutcomeUnknown, WorkerClient, WorkerError

pytestmark = [pytest.mark.integration,
              pytest.mark.skipif(shutil.which("uv") is None, reason="uv not found")]

CHAOS = '''
import os, subprocess, sys, time
from pathlib import Path

class Extension:
    def manifest(self, context):
        if (Path(context["data_dir"]) / "fail-manifest").exists():
            raise RuntimeError("manifest refused by test switch")
        return {"api_version": 1, "id": "org.example.chaos", "title": "Chaos", "version": "VERSION",
                "pages": [{"id": "overview", "title": "Overview"}, {"id": "bad", "title": "Bad"}],
                "commands": [
                    {"id": "noisy", "title": "Noisy", "risk": "read"},
                    {"id": "hang", "title": "Hang", "risk": "read"},
                    {"id": "crash", "title": "Crash", "risk": "read"},
                    {"id": "write_crash", "title": "Write then crash", "risk": "write",
                     "confirmation": "Write?"},
                    {"id": "write_hang", "title": "Write then hang", "risk": "destructive",
                     "confirmation": "Destroy?"},
                    {"id": "reject", "title": "Reject", "risk": "write", "confirmation": "Write?"},
                    {"id": "flood", "title": "Flood log", "risk": "read"},
                    {"id": "echo", "title": "Echo", "risk": "read"},
                ]}

    def page(self, page_id, context):
        if page_id == "bad":
            return {"title": "Bad", "blocks": [{"kind": "html", "text": "<script>x</script>"}]}
        return {"title": "Chaos", "blocks": [{"kind": "text", "text": "ok \\u00e9\\u4e2d\\U0001F600"}]}

    def action(self, command_id, values, params, context):
        data = Path(context["data_dir"])
        if command_id == "noisy":
            print("print to stdout")
            sys.stdout.write("sys.stdout write\\n")
            os.write(1, b"raw fd1 write\\n")
            subprocess.run([sys.executable, "-c", "print('child process stdout')"], check=True)
            return {"message": "noisy done"}
        if command_id == "hang":
            time.sleep(120)
        if command_id == "crash":
            os._exit(3)
        if command_id == "write_crash":
            (data / "written.txt").write_text("written", encoding="utf-8")
            os._exit(4)
        if command_id == "write_hang":
            (data / "destroyed.txt").write_text("done", encoding="utf-8")
            time.sleep(120)
        if command_id == "reject":
            raise ValueError("refused before writing")
        if command_id == "flood":
            chunk = "x" * 1023 + "\\n"
            for _ in range(6 * 1024):
                sys.stderr.write(chunk)
            sys.stderr.flush()
            return {"message": "flooded"}
        if command_id == "echo":
            return {"message": "values=" + ",".join(f"{k}:{values[k]}" for k in sorted(values))}
        raise ValueError("unknown")
'''


def _project(tmp: Path, ident: str, code: str, version: str = "0.1.0") -> Path:
    root = generate_python(ident, tmp / f"src-{ident}-{version}-{time.monotonic_ns()}")
    pkg = next((root / "src").iterdir())
    (pkg / "__init__.py").write_text(code.replace("VERSION", version), encoding="utf-8")
    pyproject = root / "pyproject.toml"
    pyproject.write_text(pyproject.read_text("utf-8").replace('version = "0.1.0"', f'version = "{version}"'),
                         encoding="utf-8")
    return root


def _wheel(project: Path, out: Path) -> Path:
    out.mkdir(parents=True, exist_ok=True)
    before = set(out.glob("*.whl"))
    proc = subprocess.run(["uv", "build", "--offline", "--no-build-isolation", "--python", sys.executable,
                           "--wheel", "--out-dir", str(out)], cwd=project, capture_output=True, text=True)
    if proc.returncode:
        pytest.skip("Offline wheel build backend unavailable: " + proc.stderr[-300:])
    return (set(out.glob("*.whl")) - before).pop()


@pytest.fixture
def store(tmp_path):
    s = Store(tmp_path / "home")
    s.prepare()
    return s


@pytest.fixture
def chaos(store, tmp_path):
    wheel = _wheel(_project(tmp_path, "org.example.chaos", CHAOS), tmp_path / "wheels")
    store.stage(str(wheel))
    runtime = AppShellRuntime(store)
    runtime.boot()
    assert runtime.status.get("org.example.chaos") == "ACTIVE", runtime.errors
    yield runtime
    runtime.stop()


def _pids(runtime) -> list[int]:
    return [w.proc.pid for w in runtime.workers.values() if w.proc]


def _alive(pid: int) -> bool:
    if os.name == "nt":  # os.kill(pid, 0) would TerminateProcess on Windows
        out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True).stdout
        return str(pid) in out
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    try:  # reaped zombies of our own children are not alive
        return os.waitpid(pid, os.WNOHANG) == (0, 0)
    except ChildProcessError:
        return True


# ------------------------------------------------------------------------------------ drop-ins
def test_dropin_is_snapshotted_not_modified_and_not_reinstalled(store, tmp_path):
    src = generate_python("org.example.drop", tmp_path / "gen")
    drop = store.extensions / "Drop"
    shutil.copytree(src, drop)
    before = sorted(p.relative_to(drop).as_posix() for p in drop.rglob("*"))
    first = AppShellRuntime(store)
    first.boot()
    assert first.status.get("org.example.drop") == "ACTIVE", first.errors
    release = first.registry["extensions"]["org.example.drop"]["release"]
    first.stop()
    assert sorted(p.relative_to(drop).as_posix() for p in drop.rglob("*")) == before, "user folder modified"
    assert not list(store.incoming.iterdir()), "snapshot left behind"
    second = AppShellRuntime(store)
    second.boot()
    assert second.registry["extensions"]["org.example.drop"]["release"] == release, "re-installed unchanged drop-in"
    second.stop()


def test_removed_dropin_is_suppressed_until_folder_is_deleted(store, tmp_path):
    src = generate_python("org.example.drop", tmp_path / "gen")
    shutil.copytree(src, store.extensions / "Drop")
    r = AppShellRuntime(store); r.boot(); r.stop()
    store.queue("remove", id="org.example.drop")
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert "org.example.drop" not in r.registry["extensions"]
    assert r.registry["suppressed_dropins"] == ["Drop"]
    shutil.rmtree(store.extensions / "Drop")
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert r.registry["suppressed_dropins"] == []
    shutil.copytree(src, store.extensions / "Drop")
    r = AppShellRuntime(store); r.boot()
    assert r.status.get("org.example.drop") == "ACTIVE", r.errors
    r.stop()


def test_broken_dropin_is_quarantined_by_fingerprint(store, tmp_path):
    src = generate_python("org.example.drop", tmp_path / "gen")
    drop = store.extensions / "Drop"
    shutil.copytree(src, drop)
    init = next((drop / "src").iterdir()) / "__init__.py"
    init.write_text("raise ImportError('broken on purpose')\n", encoding="utf-8")
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert "Drop" in r.errors and "org.example.drop" not in r.registry["extensions"]
    assert any(k.startswith("dropin:Drop:") for k in store.failed()["items"])
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert "Drop" not in r.errors, "same broken fingerprint retried"
    shutil.copy2(next((src / "src").iterdir()) / "__init__.py", init)
    r = AppShellRuntime(store); r.boot()
    assert r.status.get("org.example.drop") == "ACTIVE", r.errors
    r.stop()


# ------------------------------------------------------------------------------- install/upgrade
def test_upgrade_failure_keeps_previous_release_and_disable_enable_remove(store, tmp_path):
    wheels = tmp_path / "wheels"
    store.stage(str(_wheel(_project(tmp_path, "org.example.chaos", CHAOS, "0.1.0"), wheels)))
    r = AppShellRuntime(store); r.boot(); r.stop()
    old = r.registry["extensions"]["org.example.chaos"]
    assert old["version"] == "0.1.0"
    broken = CHAOS.replace('"version": "VERSION"', '"version": "9.9.9"')  # manifest != package version
    store.stage(str(_wheel(_project(tmp_path, "org.example.chaos", broken, "0.2.0"), wheels)))
    r = AppShellRuntime(store); r.boot()
    assert r.status["org.example.chaos"] == "ACTIVE"
    assert r.registry["extensions"]["org.example.chaos"]["release"] == old["release"]
    assert any("version differs" in e for e in r.errors.values()), r.errors
    assert not [p for p in store.releases.iterdir() if p.name.startswith(".candidate-")]
    r.stop()
    store.stage(str(_wheel(_project(tmp_path, "org.example.chaos", CHAOS, "0.3.0"), wheels)))
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert r.registry["extensions"]["org.example.chaos"]["version"] == "0.3.0"
    assert (store.home / old["release"]).is_dir(), "previous release must stay for last-known-good"
    store.queue("disable", id="org.example.chaos")
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert r.status["org.example.chaos"] == "DISABLED" and not r.workers
    store.queue("enable", id="org.example.chaos")
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert r.status["org.example.chaos"] == "ACTIVE"
    (store.data / "org.example.chaos" / "keep.txt").write_text("user data", encoding="utf-8")
    store.queue("remove", id="org.example.chaos")
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert "org.example.chaos" not in r.registry["extensions"]
    assert (store.data / "org.example.chaos" / "keep.txt").read_text("utf-8") == "user data"


def test_failing_manifest_fails_only_that_extension(store, tmp_path):
    wheels = tmp_path / "wheels"
    store.stage(str(_wheel(_project(tmp_path, "org.example.chaos", CHAOS), wheels)))
    store.stage(str(_wheel(generate_python("org.example.greeter", tmp_path / "greeter"), wheels)))
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert r.status == {"org.example.chaos": "ACTIVE", "org.example.greeter": "ACTIVE"}, r.errors
    (store.data / "org.example.chaos" / "fail-manifest").write_text("1")
    r = AppShellRuntime(store); r.boot()
    assert r.status["org.example.chaos"] == "FAILED"
    assert "manifest refused" in r.errors["org.example.chaos"]
    assert r.page("org.example.greeter", "overview")["title"]
    r.stop()
    assert not store.session_path.exists()
    assert json_load(store.last_good_path, {})["extensions"].keys() == {"org.example.chaos", "org.example.greeter"}


def test_corrupt_registry_starts_safe_mode_and_restore_recovers(store, tmp_path):
    store.stage(str(_wheel(generate_python("org.example.greeter", tmp_path / "g"), tmp_path / "w")))
    r = AppShellRuntime(store); r.boot(); r.stop()
    store.registry_path.write_bytes(b"{not json\xff")
    r = AppShellRuntime(store); r.boot()
    assert r.safe_mode and "recovery mode" in r.message and not r.workers
    r.stop()
    assert store.registry_path.read_bytes() == b"{not json\xff", "damaged state must not be silently reset"
    (store.home / "restore-on-next-start").write_text("1")
    r = AppShellRuntime(store); r.boot()
    assert r.status.get("org.example.greeter") == "ACTIVE", r.errors
    r.stop()
    backups = list((store.home / "backups").glob("registry-*.json"))
    assert any(b.read_bytes() == b"{not json\xff" for b in backups)


def test_unclean_exit_restores_last_good(store, tmp_path):
    store.stage(str(_wheel(generate_python("org.example.greeter", tmp_path / "g"), tmp_path / "w")))
    r = AppShellRuntime(store); r.boot(); r.stop()
    good = store.registry()
    store.stage(str(_wheel(_project(tmp_path, "org.example.chaos", CHAOS), tmp_path / "w")))
    r = AppShellRuntime(store); r.boot()
    assert r.status["org.example.chaos"] == "ACTIVE"
    r.stop(clean=False)  # e.g. host connection lost
    assert store.session_path.exists()
    r = AppShellRuntime(store); r.boot()
    assert "restored" in r.message.lower()
    assert set(r.registry["extensions"]) == set(good["extensions"])
    r.stop()


# --------------------------------------------------------------------------- worker failures
def test_worker_output_contamination_is_isolated(chaos, store):
    assert chaos.action("org.example.chaos", "noisy", {}, {})["message"] == "noisy done"
    log = (store.logs / "org.example.chaos.log").read_text("utf-8", "replace")
    for text in ("print to stdout", "sys.stdout write", "raw fd1 write", "child process stdout"):
        assert text in log
    assert chaos.page("org.example.chaos", "overview")["blocks"][0]["text"] == "ok é中\U0001F600"


def test_invalid_view_and_unicode_values(chaos):
    with pytest.raises(Exception, match="unsupported block"):
        chaos.page("org.example.chaos", "bad")
    values = {"b": "café 中", "a": "line1\nline2"}
    message = chaos.action("org.example.chaos", "echo", values, {})["message"]
    assert message == "values=a:line1\nline2,b:café 中"


def test_crash_on_read_is_definite_and_worker_restarts(chaos):
    with pytest.raises(WorkerError) as info:
        chaos.action("org.example.chaos", "crash", {}, {})
    assert not isinstance(info.value, OutcomeUnknown)
    assert chaos.page("org.example.chaos", "overview")["title"] == "Chaos"


def test_write_then_crash_is_outcome_unknown_and_not_retried(chaos, store):
    marker = store.data / "org.example.chaos" / "written.txt"
    with pytest.raises(OutcomeUnknown, match="do not retry"):
        chaos.action("org.example.chaos", "write_crash", {}, {})
    assert marker.read_text("utf-8") == "written"
    marker.unlink()
    time.sleep(0.5)
    assert not marker.exists(), "write was re-executed"


def test_rejected_write_is_definite(chaos):
    with pytest.raises(WorkerError, match="refused before writing") as info:
        chaos.action("org.example.chaos", "reject", {}, {})
    assert not isinstance(info.value, OutcomeUnknown)


def test_hung_write_times_out_kills_worker_and_reports_unknown(chaos, store, monkeypatch):
    import nativehtmlkit_appshell.worker_client as wc
    worker = chaos.workers["org.example.chaos"]
    pid = worker.proc.pid
    original = wc.WorkerClient.request

    def short(self, op, *, timeout=20, risk="read", **kw):
        return original(self, op, timeout=2, risk=risk, **kw)
    monkeypatch.setattr(wc.WorkerClient, "request", short)
    started = time.monotonic()
    with pytest.raises(OutcomeUnknown):
        chaos.action("org.example.chaos", "write_hang", {}, {})
    assert time.monotonic() - started < 10
    assert not _alive(pid), "timed-out worker still running"
    assert (store.data / "org.example.chaos" / "destroyed.txt").exists()
    with pytest.raises(WorkerError):
        chaos.action("org.example.chaos", "hang", {}, {})
    assert chaos.page("org.example.chaos", "overview")["title"] == "Chaos"


def test_worker_log_is_bounded(chaos, store):
    assert chaos.action("org.example.chaos", "flood", {}, {})["message"] == "flooded"
    chaos.stop()  # flush and close the log
    size = (store.logs / "org.example.chaos.log").stat().st_size
    assert size < 4 * 1024 * 1024 + 4096
    assert b"log limit reached" in (store.logs / "org.example.chaos.log").read_bytes()


def test_stop_leaves_no_worker_processes(chaos):
    pids = _pids(chaos)
    assert pids
    chaos.stop()
    assert not [p for p in pids if _alive(p)]


# ---------------------------------------------------------------------- client framing (no uv)
def _script(tmp_path: Path, body: str) -> Path:
    path = tmp_path / "fake_worker.py"
    path.write_text(textwrap.dedent(body), encoding="utf-8")
    return path


def _client(tmp_path, script):
    return WorkerClient(ident="org.example.fake", version="1.0", python=Path(sys.executable),
                        script=script, data=tmp_path / "data", log=tmp_path / "fake.log")


READY = ('{"type":"ready","manifest":{"api_version":1,"id":"org.example.fake","title":"F",'
         '"version":"1.0","pages":[{"id":"p","title":"P"}]}}')


@pytest.mark.parametrize("output", [b"\xff\xfe not utf-8\n", b"[1, 2]\n", b"not json\n"])
def test_malformed_worker_frames_fail_cleanly(tmp_path, output):
    script = _script(tmp_path, f"""
        import sys
        sys.stdout.buffer.write({READY!r}.encode() + b"\\n"); sys.stdout.buffer.flush()
        sys.stdin.buffer.readline()
        sys.stdout.buffer.write({output!r}); sys.stdout.buffer.flush()
        sys.stdin.buffer.readline()
    """)
    client = _client(tmp_path, script)
    client.start()
    with pytest.raises(WorkerError, match="invalid worker output|Worker disconnected"):
        client.request("page", page_id="p", timeout=5)
    assert client.proc is None
    client.stop()


def test_oversized_frame_is_rejected(tmp_path):
    script = _script(tmp_path, f"""
        import sys
        sys.stdout.buffer.write({READY!r}.encode() + b"\\n"); sys.stdout.buffer.flush()
        sys.stdin.buffer.readline()
        sys.stdout.buffer.write(b'"' + b"a" * (2 * 1024 * 1024) + b'"\\n'); sys.stdout.buffer.flush()
    """)
    client = _client(tmp_path, script)
    client.start()
    with pytest.raises(WorkerError, match="exceeds limit|disconnected"):
        client.request("page", page_id="p", timeout=10)
    client.stop()


def test_startup_hang_times_out(tmp_path):
    client = _client(tmp_path, _script(tmp_path, "import time; time.sleep(60)\n"))
    started = time.monotonic()
    with pytest.raises(WorkerError, match="timed out"):
        client.start(timeout=1)
    assert time.monotonic() - started < 8
    assert client.proc is None


# ------------------------------------------------------------------------------ session lock
def test_session_lock_blocks_second_instance_and_allows_restore_after_crash(store):
    assert not store.session_active()
    store.begin_session()
    assert store.session_active()
    other = Store(store.home)
    with pytest.raises(StateError, match="already running"):
        other.begin_session()
    from nativehtmlkit_appshell.cli import main
    store.save_registry({"version": 1, "extensions": {}})
    store.clean_exit()
    # Simulate a crash: marker present, no live process holds the lock.
    store.session_path.write_text("{}", encoding="utf-8")
    assert not store.session_active()
    assert main(["--home", str(store.home), "restore"]) == 0
    assert not store.session_path.exists()


def test_stop_during_boot_leaves_no_workers(store, tmp_path):
    wheels = tmp_path / "w"
    for n in range(3):
        store.stage(str(_wheel(generate_python(f"org.example.g{n}", tmp_path / f"g{n}"), wheels)))
    r = AppShellRuntime(store)
    t = threading.Thread(target=r.boot)
    t.start()
    while not r.workers and t.is_alive():
        time.sleep(0.01)
    r.stop()
    t.join(120)
    assert not t.is_alive()
    assert not r.workers
    children = subprocess.run(["pgrep", "-P", str(os.getpid()), "-f", "worker_main.py"],
                              capture_output=True, text=True).stdout.split() if os.name != "nt" else []
    assert not [c for c in children if _alive(int(c))]
    assert not store.session_active()


def test_stage_dot_source_and_cli_doctor(store, tmp_path, monkeypatch, capsys):
    project = generate_python("org.example.dot", tmp_path / "dot")
    monkeypatch.chdir(project)
    op = store.stage(".")
    record = store.pending()["operations"][0]
    assert op and record["source"]["path"].endswith("/dot")
    from nativehtmlkit_appshell.cli import main
    store.registry_path.write_text(json.dumps({"version": 1, "extensions": {"x.y": {"release": "../../etc"}}}))
    assert main(["--home", str(store.home), "doctor"]) == 1
    assert "Invalid release record" in capsys.readouterr().err


def test_pinned_package_source_installs_exact_version_from_index(store, tmp_path, monkeypatch):
    """name==version through uv, served by a local find-links index (no network, no code seam)."""
    index = tmp_path / "index"
    for version in ("0.1.0", "0.2.0"):
        _wheel(_project(tmp_path, "org.example.chaos", CHAOS, version), index)
    monkeypatch.setenv("UV_FIND_LINKS", str(index))
    monkeypatch.setenv("UV_NO_INDEX", "1")
    dist = "appshell-ext-org-example-chaos"
    store.stage(f"{dist}==0.1.0")
    r = AppShellRuntime(store); r.boot(); r.stop()
    record = r.registry["extensions"]["org.example.chaos"]
    assert record["version"] == "0.1.0" and record["source"] == {"kind": "package", "value": f"{dist}==0.1.0",
                                                               "fingerprint": f"{dist}==0.1.0"}
    store.stage(f"{dist}==0.1.0")  # same pinned source again: no new environment
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert r.registry["extensions"]["org.example.chaos"]["release"] == record["release"]
    store.stage(f"{dist}==9.9.9")  # not in the index: fails, installed release untouched
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert r.registry["extensions"]["org.example.chaos"]["release"] == record["release"]
    assert any("Package command failed" in e for e in r.errors.values()), r.errors
    store.stage(f"{dist}==0.2.0")
    r = AppShellRuntime(store); r.boot(); r.stop()
    assert r.registry["extensions"]["org.example.chaos"]["version"] == "0.2.0"
