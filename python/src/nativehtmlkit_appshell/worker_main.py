"""Standalone stdlib worker executed INSIDE the isolated extension interpreter.

No import of AppShell, NativeHTMLKit, or PowerShell. Runs one extension per process.
The host validates all results; this wrapper only enforces framing and operation dispatch.
"""
from __future__ import annotations

from importlib.metadata import entry_points
import json
import os
import sys
import traceback

GROUP = "nativehtmlkit.appshell.extensions"
MAX_FRAME = 1024 * 1024 + 65536


def send(writer, frame: dict) -> None:
    raw = (json.dumps(frame, separators=(",", ":"), ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
    if len(raw) > MAX_FRAME:
        raise ValueError("worker response too large")
    writer.write(raw)
    writer.flush()


def main() -> int:
    if len(sys.argv) != 5:
        raise SystemExit("usage: worker_main.py ID VERSION DATA_DIR APP_VERSION")
    ident, version, data, app_version = sys.argv[1:]
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    sys.stdout = sys.stderr  # plugin print() never contaminates protocol stdout
    context = {"data_dir": data, "extension_id": ident, "app_version": app_version}
    os.makedirs(data, exist_ok=True)
    obj = None
    try:
        matches = [ep for ep in entry_points(group=GROUP) if ep.name == ident]
        if len(matches) != 1:
            raise ValueError("expected exactly one entry point matching extension ID")
        target = matches[0].load()
        obj = target() if isinstance(target, type) else target
        if callable(obj) and not hasattr(obj, "manifest"):
            obj = obj()
        manifest = obj.manifest(context)
        send(protocol, {"type": "ready", "manifest": manifest})
    except BaseException as exc:
        send(protocol, {"type": "fatal", "error": f"{type(exc).__name__}: {str(exc)[:400]}"})
        traceback.print_exc()
        return 1
    for raw in sys.stdin.buffer:
        if len(raw) > MAX_FRAME:
            break
        try:
            frame = json.loads(raw)
            op, req = frame["op"], frame["id"]
            if op == "page":
                result = obj.page(frame["page_id"], context)
            elif op == "action":
                result = obj.action(frame["command_id"], frame.get("values", {}), frame.get("params", {}), context)
            elif op == "ping":
                result = {"pong": True}
            elif op == "shutdown":
                if hasattr(obj, "shutdown"):
                    obj.shutdown(context)
                send(protocol, {"type": "reply", "id": req, "result": True})
                break
            else:
                raise ValueError("invalid worker operation")
            send(protocol, {"type": "reply", "id": req, "result": result})
        except Exception as exc:
            traceback.print_exc()
            try:
                send(protocol, {"type": "reply", "id": frame.get("id"), "error": f"{type(exc).__name__}: {str(exc)[:400]}"})
            except Exception:
                break
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
