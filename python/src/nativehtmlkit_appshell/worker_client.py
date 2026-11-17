"""Bounded, portable worker IPC (works with Windows anonymous pipes)."""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import subprocess
import threading
from typing import Any

from . import __version__
from .contract import FRAME_LIMIT, ContractError, validate_manifest, validate_result, validate_view


class WorkerError(RuntimeError):
    pass


class OutcomeUnknown(WorkerError):
    """The command may have executed; never automatically retry a write."""


class WorkerClient:
    def __init__(self, *, ident: str, version: str, python: Path, script: Path, data: Path,
                 log: Path):
        self.ident, self.version = ident, version
        self.python, self.script, self.data, self.log = python, script, data, log
        self.proc: subprocess.Popen | None = None
        self.messages: queue.Queue = queue.Queue(maxsize=16)
        self._lock = threading.RLock()
        self._serial = 0
        self.manifest: dict | None = None
        self._log_handle = None

    @staticmethod
    def _reader(stream, output: queue.Queue) -> None:
        try:
            while True:
                line = stream.readline(FRAME_LIMIT + 1)
                if not line:
                    break
                if len(line) > FRAME_LIMIT:
                    output.put({"type": "fatal", "error": "worker frame exceeds limit"})
                    break
                try:
                    value = json.loads(line)
                    if not isinstance(value, dict):
                        raise ValueError("worker output must be object")
                except (ValueError, UnicodeError):
                    output.put({"type": "fatal", "error": "invalid worker output (stdout contamination?)"})
                    break
                output.put(value)
        except Exception as exc:
            output.put({"type": "fatal", "error": f"reader failure: {exc}"})
        finally:
            output.put({"type": "eof"})

    def start(self, timeout: float = 15) -> dict:
        with self._lock:
            if self.manifest is not None and self.proc and self.proc.poll() is None:
                return self.manifest
            self.stop()
            self.data.mkdir(parents=True, exist_ok=True)
            self.log.parent.mkdir(parents=True, exist_ok=True)
            if self.log.exists() and self.log.stat().st_size > 2_000_000:
                self.log.replace(self.log.with_suffix(".log.1"))
            self._log_handle = self.log.open("ab")
            self.messages = queue.Queue(maxsize=16)
            env = os.environ.copy()
            env.pop("PYTHONPATH", None)
            env.pop("PYTHONHOME", None)
            env["PYTHONNOUSERSITE"] = "1"
            env["PYTHONUNBUFFERED"] = "1"
            try:
                self.proc = subprocess.Popen(
                    [str(self.python), "-u", str(self.script), self.ident, self.version, str(self.data), __version__],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self._log_handle,
                    cwd=str(self.data), env=env, bufsize=0,
                )
                threading.Thread(target=self._reader, args=(self.proc.stdout, self.messages), daemon=True,
                                 name=f"worker-reader-{self.ident}").start()
                ready = self._receive(timeout)
                if ready.get("type") != "ready":
                    raise WorkerError(f"Worker initialization failed: {ready.get('error', ready)}")
                self.manifest = validate_manifest(ready.get("manifest"), self.ident, self.version)
                return self.manifest
            except Exception:
                self.stop(force=True)
                raise

    def _receive(self, timeout: float) -> dict:
        try:
            value = self.messages.get(timeout=timeout)
        except queue.Empty as exc:
            raise WorkerError(f"Worker timed out after {timeout:g}s: {self.ident}") from exc
        if value.get("type") in ("fatal", "eof"):
            raise WorkerError(f"Worker disconnected: {self.ident}: {value.get('error', 'EOF')}")
        return value

    def request(self, op: str, *, timeout: float = 20, risk: str = "read", **kwargs) -> Any:
        if op not in {"page", "action", "ping"}:
            raise WorkerError("Invalid operation")
        with self._lock:
            self.start()
            self._serial += 1
            token = f"{self.ident}:{self._serial}"
            frame = {"id": token, "op": op, **kwargs}
            payload = json.dumps(frame, ensure_ascii=False, allow_nan=False).encode("utf-8") + b"\n"
            if len(payload) > 64 * 1024:
                raise WorkerError("Request too large")
            sent = False
            try:
                if self.proc is None or self.proc.stdin is None:
                    raise WorkerError("Worker not connected")
                self.proc.stdin.write(payload)
                self.proc.stdin.flush()
                sent = True
                response = self._receive(timeout)
                if response.get("id") != token or response.get("type") != "reply":
                    raise WorkerError("Unexpected worker response")
                if "error" in response:
                    raise WorkerError(f"Extension rejected request: {response['error']}")
                result = response.get("result")
                if op == "page":
                    return validate_view(result, self.manifest)
                if op == "action":
                    return validate_result(result)
                return result
            except WorkerError as exc:
                # Rejected actions remain definite; transport failures after send do not.
                definite = str(exc).startswith("Extension rejected request:")
                if not definite:
                    self.stop(force=True)
                if sent and risk != "read" and not definite:
                    raise OutcomeUnknown(f"Outcome unknown for {self.ident}; do not retry: {exc}") from exc
                raise
            except Exception as exc:
                self.stop(force=True)
                if sent and risk != "read":
                    raise OutcomeUnknown(f"Outcome unknown for {self.ident}; do not retry: {exc}") from exc
                raise WorkerError(str(exc)) from exc

    def stop(self, force: bool = False) -> None:
        # Called with lock held, or from owner at shutdown after background tasks end.
        proc, self.proc = self.proc, None
        self.manifest = None
        if proc:
            if proc.poll() is None and not force:
                try:
                    proc.stdin.write(b'{"id":"shutdown","op":"shutdown"}\n')
                    proc.stdin.flush()
                    proc.wait(timeout=1)
                except Exception:
                    pass
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2)
            for stream in (proc.stdin, proc.stdout):
                if stream:
                    stream.close()
        if self._log_handle:
            self._log_handle.close()
            self._log_handle = None
