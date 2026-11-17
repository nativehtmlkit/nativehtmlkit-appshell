"""Staged uv installer: no mutation of AppShell's environment, no hot reload."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

from .contract import ContractError, validate_manifest
from .storage import StateError, Store
from .worker_client import WorkerClient

INSPECT = '''
import json
from importlib.metadata import entry_points
items = list(entry_points(group="nativehtmlkit.appshell.extensions"))
print(json.dumps([{"id": x.name, "version": x.dist.version, "distribution": x.dist.name} for x in items]))
'''


def environment_python(path: Path) -> Path:
    return path / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def run_command(args: list[str], *, timeout: int = 180, cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(args, text=True, encoding="utf-8", errors="replace",
                                capture_output=True, cwd=cwd, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise StateError(f"Package command failed: {exc}") from exc
    if result.returncode:
        raise StateError(f"Package command failed ({result.returncode}): {(result.stderr or result.stdout)[-1700:]}")
    return result.stdout


def prepare_candidate(store: Store, source: dict, *, worker_script: Path) -> tuple[dict, Path]:
    store.prepare()
    if shutil.which("uv") is None:
        raise StateError("uv is required to install Python extensions")
    token = uuid.uuid4().hex[:16]
    staged = store.releases / (".candidate-" + token)
    environment = staged / "env"
    try:
        staged.mkdir()
        run_command(["uv", "venv", "--python", sys.executable, str(environment)], timeout=60)
        python = environment_python(environment)
        kind = source.get("kind")
        if kind == "local":
            # Local source must be an owned staged or manual drop-in path.
            rel = source["path"]
            local = store.resolve_owned(rel)
            if not local.exists() or not local.is_relative_to(store.incoming) and not local.is_relative_to(store.extensions):
                raise StateError("Local source must live under AppShell incoming/extensions")
            if local.is_symlink():
                raise StateError("Local extension source symlink forbidden")
            requirement = str(local)
            if local.is_dir() and not (local / "pyproject.toml").is_file():
                raise StateError("Python extension directory requires pyproject.toml")
            if local.is_file() and local.suffix != ".whl":
                raise StateError("Local Python package file must be .whl")
        elif kind == "package":
            requirement = source["value"]
            if not (re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*==[A-Za-z0-9][A-Za-z0-9_.!+-]*", requirement)
                    or re.fullmatch(r"git\+https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[a-fA-F0-9]{40}", requirement)):
                raise StateError("Unsafe or unpinned package source")
        else:
            raise StateError("Unknown package source kind")
        run_command(["uv", "pip", "install", "--python", str(python), requirement], timeout=300)
        found = json.loads(run_command([str(python), "-I", "-c", INSPECT], timeout=15))
        if len(found) != 1:
            raise StateError(f"Expected exactly one entry point, got {len(found)}")
        entry = found[0]
        ident, version = entry["id"], entry["version"]
        if not isinstance(ident, str) or not isinstance(version, str):
            raise StateError("Invalid entry point metadata")
        # Contract validation without importing extension code into the main application.
        validate_manifest({"api_version": 1, "id": ident, "title": "Metadata", "version": version,
                           "pages": [{"id": "placeholder", "title": "Metadata"}]}, ident, version)
        client = WorkerClient(ident=ident, version=version, python=python, script=worker_script,
                              data=store.data / ident, log=store.logs / (ident + ".log"))
        try:
            manifest = client.start()
        finally:
            client.stop(force=True)
        # Only validated releases are promoted. Old releases are untouched.
        release = store.releases / ident / token
        release.parent.mkdir(parents=True, exist_ok=True)
        staged.replace(release)
        record = {"id": ident, "version": version, "release": str(release.relative_to(store.home)),
                  "source": source, "enabled": True, "distribution": entry["distribution"]}
        return record, release
    except Exception:
        shutil.rmtree(staged, ignore_errors=True)
        raise
