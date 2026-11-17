"""Small durable state store with portable locks and separate extension data.

The user owns the extension and data directories. This is not a security sandbox.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
import uuid


class StateError(RuntimeError):
    pass


def default_home() -> Path:
    override = os.environ.get("APPSHELL_HOME")
    if override:
        return Path(override).expanduser().resolve()
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / "NativeHTMLKit" / "AppShell" / "Python"
    return Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))) / "nativehtmlkit" / "appshell" / "python"


def json_load(path: Path, fallback: dict) -> dict:
    if not path.is_file():
        return json.loads(json.dumps(fallback))
    try:
        if path.stat().st_size > 2_000_000:
            raise ValueError("state file too large")
        value = json.loads(path.read_text("utf-8"))
        if not isinstance(value, dict):
            raise ValueError("state root must be object")
        return value
    except (OSError, UnicodeError, ValueError) as exc:
        raise StateError(f"Invalid state {path}: {exc}. Use 'appshell doctor' or restore.") from exc


def json_save(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".appshell-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if os.name != "nt":
            os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def _try_lock(fd) -> bool:
    """Non-blocking exclusive lock of byte 0; released automatically when the process dies."""
    try:
        if os.name == "nt":
            import msvcrt
            fd.seek(0)
            if fd.read(1) == b"":
                fd.write(b"0")
                fd.flush()
            fd.seek(0)
            msvcrt.locking(fd.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except (BlockingIOError, OSError):
        return False


def _unlock(fd) -> None:
    if os.name == "nt":
        import msvcrt
        fd.seek(0)
        msvcrt.locking(fd.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        fcntl.flock(fd.fileno(), fcntl.LOCK_UN)


@contextmanager
def locked(path: Path):
    """Cross-platform short-lived advisory lock for registry mutations."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as fd:
        start = time.monotonic()
        while not _try_lock(fd):
            if time.monotonic() - start > 5:
                raise StateError("AppShell state is busy; retry shortly")
            time.sleep(.05)
        try:
            yield
        finally:
            _unlock(fd)


def is_dropin(source: dict) -> bool:
    """True for a source recorded from the user-managed extensions/ folder (any OS separator)."""
    return str(source.get("path", "")).replace("\\", "/").startswith("extensions/")


def safe_copy(source: Path, destination: Path, *, max_total: int = 128 * 1024 * 1024) -> str:
    """Copy user-supplied project or wheel, rejecting symlinks and oversized trees."""
    source = source.expanduser().absolute()
    if not source.exists() or source.is_symlink():
        raise StateError(f"Missing source or symlink: {source}")
    digest = hashlib.sha256()
    total = 0
    count = 0
    files = [source] if source.is_file() else sorted(p for p in source.rglob("*") if p.is_file() or p.is_symlink())
    if len(files) > 2500:
        raise StateError("Extension contains more than 2500 files")
    for f in files:
        if f.is_symlink():
            raise StateError(f"Symlinks not accepted in local extensions: {f}")
        rel = f.name if source.is_file() else f.relative_to(source).as_posix()
        if any(x in {".git", ".venv", "__pycache__", ".pytest_cache"} for x in Path(rel).parts):
            continue
        total += f.stat().st_size
        count += 1
        if total > max_total:
            raise StateError("Extension local copy exceeds size limit")
        digest.update(rel.encode("utf-8"))
        with f.open("rb") as content:
            while chunk := content.read(1024 * 1024):
                digest.update(chunk)
    if count == 0:
        raise StateError("Extension source is empty")
    if destination.exists():
        raise StateError(f"Destination exists: {destination}")
    if source.is_file():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    else:
        shutil.copytree(source, destination,
                        ignore=shutil.ignore_patterns(".git", ".venv", "__pycache__", ".pytest_cache"),
                        symlinks=False)
    return digest.hexdigest()


def fingerprint(path: Path) -> str:
    """Hash local contents, not modification times, to detect manual drop-in updates."""
    h = hashlib.sha256()
    total = 0
    files = [path] if path.is_file() else sorted(p for p in path.rglob("*") if p.is_file() or p.is_symlink())
    if len(files) > 2500:
        raise StateError("Too many files in drop-in")
    for f in files:
        if f.is_symlink():
            raise StateError("Symlinks forbidden inside drop-in")
        rel = f.name if path.is_file() else f.relative_to(path).as_posix()
        if any(x in {".git", ".venv", "__pycache__", ".pytest_cache"} for x in Path(rel).parts):
            continue
        total += f.stat().st_size
        if total > 128 * 1024 * 1024:
            raise StateError("Drop-in too large")
        h.update(rel.encode("utf-8"))
        with f.open("rb") as stream:
            while data := stream.read(1024 * 1024):
                h.update(data)
    return h.hexdigest()


class Store:
    def __init__(self, home: Path | None = None):
        self.home = (home or default_home()).expanduser().resolve()
        self.registry_path = self.home / "registry.json"
        self.last_good_path = self.home / "last-good.json"
        self.pending_path = self.home / "pending.json"
        self.failed_path = self.home / "failed-candidates.json"
        self.session_path = self.home / "running.json"
        self.lock_path = self.home / ".state.lock"
        # Held for the whole desktop session; the OS drops it if the process dies.
        self.session_lock_path = self.home / ".session.lock"
        self._session_fd = None
        self.releases = self.home / "releases"
        self.extensions = self.home / "extensions"
        self.incoming = self.home / "incoming"
        self.data = self.home / "extension-data"
        self.logs = self.home / "logs"

    def prepare(self) -> None:
        for path in (self.home, self.releases, self.extensions, self.incoming, self.data, self.logs):
            path.mkdir(parents=True, exist_ok=True)
            if os.name != "nt":
                path.chmod(0o700)

    def registry(self) -> dict:
        return json_load(self.registry_path, {"version": 1, "extensions": {}})

    def pending(self) -> dict:
        return json_load(self.pending_path, {"version": 1, "operations": []})

    def queue(self, action: str, **kwargs) -> str:
        if action not in {"add", "enable", "disable", "remove"}:
            raise StateError("Unknown operation")
        op_id = uuid.uuid4().hex[:16]
        with locked(self.lock_path):
            state = self.pending()
            state["operations"].append({"operation_id": op_id, "action": action, **kwargs})
            json_save(self.pending_path, state)
        return op_id

    def stage(self, source: str) -> str:
        value = source.strip()
        if not value or len(value) > 2048:
            raise StateError("Invalid package source")
        path = Path(value).expanduser()
        if path.exists():
            # ".", ".." or a drive root have no usable name of their own.
            dest = self.incoming / uuid.uuid4().hex / (path.absolute().resolve().name or "source")
            digest = safe_copy(path, dest)
            record = {"kind": "local", "path": dest.relative_to(self.home).as_posix(), "fingerprint": digest}
        else:
            # No arbitrary shell commands, moving Git branches, HTTP or requirement expressions.
            import re
            pep = re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*==[A-Za-z0-9][A-Za-z0-9_.!+-]*", value)
            git = re.fullmatch(r"git\+https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[a-fA-F0-9]{40}", value)
            if not (pep or git):
                raise StateError("Package source must be local, package==version, or GitHub pinned to full SHA")
            record = {"kind": "package", "value": value, "fingerprint": value}
        return self.queue("add", source=record)

    def resolve_owned(self, relative: str, root: Path | None = None) -> Path:
        base = (root or self.home).resolve()
        result = (self.home / relative).resolve()
        if not result.is_relative_to(base):
            raise StateError("Path escapes AppShell's owned directory")
        return result

    def save_registry(self, value: dict) -> None:
        with locked(self.lock_path):
            json_save(self.registry_path, value)

    def pop_pending(self) -> list[dict]:
        with locked(self.lock_path):
            state = self.pending()
            json_save(self.pending_path, {"version": 1, "operations": []})
        return state["operations"]

    def failed(self) -> dict:
        return json_load(self.failed_path, {"items": {}})

    def mark_failure(self, key: str, error: str) -> None:
        state = self.failed()
        state["items"][key] = error[:500]
        json_save(self.failed_path, state)

    def clear_failure(self, key: str) -> None:
        state = self.failed()
        state["items"].pop(key, None)
        json_save(self.failed_path, state)

    def backup_registry(self) -> Path | None:
        """Keep original bytes before an explicit/automatic restore; never silently erase damage."""
        if not self.registry_path.is_file():
            return None
        folder = self.home / "backups"
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / f"registry-{int(time.time() * 1000)}-{uuid.uuid4().hex[:8]}.json"
        shutil.copy2(self.registry_path, target)
        return target

    def session_active(self) -> bool:
        """True while some process (this one included) holds the desktop session lock."""
        if self._session_fd is not None:
            return True
        self.home.mkdir(parents=True, exist_ok=True)
        with self.session_lock_path.open("a+b") as fd:
            if _try_lock(fd):
                _unlock(fd)
                return False
            return True

    def _acquire_session(self) -> None:
        fd = self.session_lock_path.open("a+b")
        if not _try_lock(fd):
            fd.close()
            raise StateError(f"AppShell is already running with this home: {self.home}")
        self._session_fd = fd

    def _release_session(self) -> None:
        fd, self._session_fd = self._session_fd, None
        if fd is not None:
            try:
                _unlock(fd)
            finally:
                fd.close()

    def begin_session(self) -> str | None:
        """Recover last clean configuration after an unclean process exit."""
        self.prepare()
        self._acquire_session()
        try:
            return self._begin_session()
        except BaseException:
            self._release_session()
            raise

    def _begin_session(self) -> str | None:
        reason = None
        restore_request = self.home / "restore-on-next-start"
        if self.session_path.exists() or restore_request.exists():
            if self.last_good_path.exists():
                old = json_load(self.last_good_path, {"version": 1, "extensions": {}})
                # Don't reactivate a changed manual drop-in after it crashed the app.
                if self.session_path.exists() and self.registry_path.exists():
                    unstable = self.registry()
                    old_records = old.get("extensions", {})
                    for ident, candidate in unstable.get("extensions", {}).items():
                        if old_records.get(ident, {}).get("release") == candidate.get("release"):
                            continue
                        src = candidate.get("source", {})
                        if is_dropin(src):
                            name = str(src["path"]).replace("\\", "/").rsplit("/", 1)[-1]
                            key = f"dropin:{name}:{src.get('fingerprint', '')}"
                            self.mark_failure(key, "Quarantined after unclean shutdown; edit source to retry")
                self.backup_registry()
                json_save(self.registry_path, old)
                reason = "Last-known-good extension versions restored after an interrupted session or request; previous registry backed up."
            else:
                reason = "Unclean shutdown without last-known-good snapshot: start in safe mode."
        restore_request.unlink(missing_ok=True)
        json_save(self.session_path, {"pid": os.getpid(), "started": time.time()})
        return reason

    def clean_exit(self) -> None:
        # Commit the version set only after the application has closed normally.
        try:
            json_save(self.last_good_path, self.registry())
            self.session_path.unlink(missing_ok=True)
        finally:
            self._release_session()

    def end_session(self) -> None:
        """Orderly exit that must not become last-known-good (failed or partial boot)."""
        try:
            self.session_path.unlink(missing_ok=True)
        finally:
            self._release_session()
