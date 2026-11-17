"""Language-native AppShell lifecycle: apply changes only on restart."""
from __future__ import annotations

from pathlib import Path
import shutil
import threading
from typing import Callable
import uuid

from . import __version__
from .installer import prepare_candidate, environment_python
from .storage import Store, StateError, fingerprint, is_dropin, safe_copy
from .worker_client import WorkerClient, WorkerError


class AppShellRuntime:
    def __init__(self, store: Store | None = None, *, safe_mode: bool = False):
        self.store = store or Store()
        self.safe_mode = safe_mode
        self.worker_script = Path(__file__).with_name("worker_main.py")
        self.workers: dict[str, WorkerClient] = {}
        self.manifests: dict[str, dict] = {}
        self.status: dict[str, str] = {}
        self.errors: dict[str, str] = {}
        self.message = ""
        self.registry: dict = {"version": 1, "extensions": {}}
        self._started = False
        self._boot_complete = False
        self._session = False
        # stop() may run while boot() is still installing on a background thread.
        self._stop_lock = threading.Lock()
        self._stopping = False

    def _keep(self, ident: str, worker: WorkerClient) -> bool:
        """Register a started worker unless shutdown began; never leave one running after stop()."""
        with self._stop_lock:
            if not self._stopping:
                old = self.workers.get(ident)
                self.workers[ident] = worker
                if old is not None and old is not worker:
                    old.stop(force=True)
                return True
        worker.stop(force=True)
        return False

    def _check_stopping(self) -> None:
        if self._stopping:
            raise StateError("AppShell is closing; remaining extension work skipped")

    def _worker_for(self, record: dict) -> WorkerClient:
        ident = record["id"]
        release = self.store.resolve_owned(record["release"], self.store.releases)
        python = environment_python(release / "env")
        if not python.is_file():
            raise StateError(f"Extension interpreter missing: {python}")
        return WorkerClient(ident=ident, version=record["version"], python=python,
                            script=self.worker_script, data=self.store.data / ident,
                            log=self.store.logs / (ident + ".log"))

    def _record_error(self, key: str, message: str) -> None:
        self.errors[key] = message[:800]
        self.status[key] = "FAILED"

    def _add(self, source: dict, *, label: str, fingerprint_key: str | None = None) -> None:
        snapshot = None
        try:
            self._check_stopping()
            if source.get("kind") == "package":
                for existing in self.registry["extensions"].values():
                    if existing.get("source") == source:
                        # Same pinned package already installed: nothing to download or build.
                        return
            install = source
            if is_dropin(source):
                # Never build inside the user's folder (setuptools writes build/ and *.egg-info
                # there) and never install what is edited while we install: snapshot first.
                folder = self.store.resolve_owned(source["path"], self.store.extensions)
                snapshot = self.store.incoming / ("dropin-" + uuid.uuid4().hex) / folder.name
                digest = safe_copy(folder, snapshot)
                if digest != source.get("fingerprint") or fingerprint(snapshot) != digest:
                    raise StateError("Drop-in changed while AppShell copied it; restart to retry")
                install = dict(source, path=snapshot.relative_to(self.store.home).as_posix())
            record, _ = prepare_candidate(self.store, install, worker_script=self.worker_script)
            record["source"] = source
            ident = record["id"]
            self._check_stopping()
            # Prove post-promotion interpreter can start before replacing the old release.
            worker = self._worker_for(record)
            try:
                manifest = worker.start()
            except Exception:
                worker.stop(force=True)
                raise
            if not self._keep(ident, worker):
                raise StateError("AppShell is closing; extension activation skipped")
            self.registry["extensions"][ident] = record
            self.manifests[ident] = manifest
            self.status[ident] = "ACTIVE"
            self.errors.pop(ident, None)
            if fingerprint_key:
                self.store.clear_failure(fingerprint_key)
            if source.get("kind") == "local" and not is_dropin(source):
                # The staged copy is installed into the release environment; drop the copy.
                staged = self.store.resolve_owned(source["path"], self.store.incoming)
                shutil.rmtree(staged.parent if staged.parent != self.store.incoming else staged,
                              ignore_errors=True)
        except Exception as exc:
            self._record_error(label, str(exc))
            if fingerprint_key and not self._stopping:
                self.store.mark_failure(fingerprint_key, str(exc))
        finally:
            if snapshot is not None:
                shutil.rmtree(snapshot.parent, ignore_errors=True)

    def _scan_dropins(self) -> list[tuple[str, dict, str]]:
        """User-managed folders are never modified by AppShell."""
        results = []
        # A removed drop-in stays suppressed only while its folder exists; deleting the folder
        # (and copying a package back later) makes it a new candidate again.
        present = {p.name for p in self.store.extensions.iterdir()}
        self.registry["suppressed_dropins"] = [n for n in self.registry.get("suppressed_dropins", [])
                                               if n in present]
        suppressed = set(self.registry["suppressed_dropins"])
        previous = {r.get("source", {}).get("path"): r.get("source", {}).get("fingerprint")
                    for r in self.registry["extensions"].values() if r.get("source", {}).get("kind") == "local"}
        for path in sorted(self.store.extensions.iterdir()):
            if path.name.startswith(".") or path.name in suppressed:
                continue
            if not ((path.is_dir() and (path / "pyproject.toml").is_file()) or (path.is_file() and path.suffix == ".whl")):
                continue
            rel = path.relative_to(self.store.home).as_posix()
            try:
                digest = fingerprint(path)
            except Exception as exc:
                self._record_error(path.name, str(exc))
                continue
            if previous.get(rel) == digest:
                continue
            source = {"kind": "local", "path": rel, "fingerprint": digest}
            key = f"dropin:{path.name}:{digest}"
            if key not in self.store.failed()["items"]:
                results.append((path.name, source, key))
        return results

    def boot(self, on_progress: Callable[[], None] | None = None) -> None:
        """Safe to call on a background thread after the native window has mounted."""
        if self._started:
            return
        self._started = True
        try:
            if self._stopping:
                return
            self.message = self.store.begin_session() or ""
            self._session = True
            if self.message and not self.store.last_good_path.exists():
                self.safe_mode = True
            self.registry = self.store.registry()
            if not isinstance(self.registry.get("extensions"), dict):
                raise StateError("Registry requires an extensions object")
            if self.safe_mode:
                self.message += " Safe mode: third-party workers not started."
                return
            # Apply user-requested enable/disable/remove changes before attempting candidates.
            operations = self.store.pop_pending()
            additions = []
            for op in operations:
                action = op.get("action")
                if action == "add":
                    additions.append(op)
                    continue
                ident = op.get("id", "")
                if ident not in self.registry["extensions"]:
                    self._record_error(ident, "Extension not installed")
                    continue
                record = self.registry["extensions"][ident]
                if action == "disable":
                    record["enabled"] = False
                elif action == "enable":
                    record["enabled"] = True
                elif action == "remove":
                    if is_dropin(record.get("source", {})):
                        name = str(record["source"]["path"]).replace("\\", "/").rsplit("/", 1)[-1]
                        self.registry.setdefault("suppressed_dropins", []).append(name)
                    del self.registry["extensions"][ident]
                    self.manifests.pop(ident, None)
                    self.status.pop(ident, None)
                else:
                    self._record_error(ident, "Unknown pending operation")
            self.store.save_registry(self.registry)
            for op in additions:
                label = op.get("operation_id", "pending")
                self._add(op["source"], label=label, fingerprint_key=f"pending:{label}")
                self.store.save_registry(self.registry)
                if on_progress:
                    on_progress()
            for label, source, key in self._scan_dropins():
                self._add(source, label=label, fingerprint_key=key)
                self.store.save_registry(self.registry)
                if on_progress:
                    on_progress()
            for ident, record in sorted(self.registry["extensions"].items()):
                if not record.get("enabled", True):
                    self.status[ident] = "DISABLED"
                    continue
                if ident in self.workers:
                    continue
                try:
                    self._check_stopping()
                    worker = self._worker_for(record)
                    manifest = worker.start()
                    if not self._keep(ident, worker):
                        break
                    self.manifests[ident] = manifest
                    self.status[ident] = "ACTIVE"
                except Exception as exc:
                    self._record_error(ident, str(exc))
                if on_progress:
                    on_progress()
            self.store.save_registry(self.registry)
            self._boot_complete = not self._stopping
        except Exception as exc:
            self._record_error("shell", str(exc))
            self.safe_mode = True
            self.message = f"Startup state error; recovery mode: {exc}"
        finally:
            if on_progress:
                on_progress()

    def get_pages(self) -> list[tuple[str, dict]]:
        result = []
        for ident, manifest in self.manifests.items():
            if self.status.get(ident) != "ACTIVE":
                continue
            for page in manifest["pages"]:
                result.append((ident, page))
        return sorted(result, key=lambda pair: (self.manifests[pair[0]]["title"].lower(),
                                                pair[1].get("order", 100), pair[1]["id"]))

    def page(self, ident: str, page_id: str) -> dict:
        if self.status.get(ident) != "ACTIVE":
            raise WorkerError("Extension not available")
        if page_id not in {p["id"] for p in self.manifests[ident]["pages"]}:
            raise WorkerError("Page not declared")
        return self.workers[ident].request("page", page_id=page_id, timeout=20)

    def action(self, ident: str, command_id: str, values: dict, params: dict) -> dict:
        if self.status.get(ident) != "ACTIVE":
            raise WorkerError("Extension not available")
        commands = {c["id"]: c for c in self.manifests[ident].get("commands", [])}
        if command_id not in commands:
            raise WorkerError("Command not declared")
        risk = commands[command_id]["risk"]
        return self.workers[ident].request("action", command_id=command_id, values=values,
                                           params=params, timeout=30, risk=risk)

    def stop(self, *, clean: bool = True) -> None:
        """Stop all workers. clean=False (host lost, crash) keeps the unclean-session marker."""
        with self._stop_lock:
            self._stopping = True
            workers = list(self.workers.values())
            self.workers.clear()
        for client in workers:
            try:
                client.stop(force=True)
            except Exception:
                pass
        if not self._session:
            return
        self._session = False
        if clean:
            healthy = (self._boot_complete and not self.safe_mode and
                       all(self.status.get(ident) == "ACTIVE"
                           for ident, rec in self.registry["extensions"].items()
                           if rec.get("enabled", True)))
            if healthy:
                self.store.clean_exit()
            else:
                # Do not overwrite the last working release set with failed candidates.
                self.store.end_session()
        else:
            self.store._release_session()
