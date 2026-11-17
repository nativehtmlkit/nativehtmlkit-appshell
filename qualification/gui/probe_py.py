"""GUI probe (test tooling): the real Python AppShell desktop plus a read-only state channel.

usage: python probe_py.py CHANNEL_DIR      (APPSHELL_HOME names the AppShell home)

Starts exactly what ``appshell run`` starts (Application.start, Desktop, AppShellRuntime). A
probe thread answers the GUI driver's questions through files in CHANNEL_DIR (request
``req-N.json`` -> response ``resp-N.json``): element rectangles, text, values, focus, dialog and
shell state, the accessibility tree. It never injects events: all input comes from the OS.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import threading
import time
import traceback

from nativehtmlkit import Application

from nativehtmlkit_appshell.desktop import Desktop
from nativehtmlkit_appshell.runtime import AppShellRuntime
from nativehtmlkit_appshell.storage import Store

CHANNEL = Path(sys.argv[1])


def answer(desktop: Desktop, request: dict):
    doc = desktop.doc
    cmd = request["cmd"]
    if cmd == "state":
        view = desktop.active_view
        return {
            "booted": desktop.runtime._boot_complete, "safe_mode": desktop.runtime.safe_mode,
            "status": desktop.status_state.value if desktop.status_state else "",
            "title": desktop.title_state.value if desktop.title_state else "",
            "selected": list(desktop.selected) if desktop.selected else None,
            "page_ready": view is not None, "generation": desktop.generation,
            "nav": {k: list(v) for k, v in desktop.nav_items.items()}, "nav_container": desktop.nav_id,
            "outlet": desktop.outlet_id,
            "buttons": {cmd_id: bid for bid, (cmd_id, _) in (view.buttons.items() if view else [])},
            "fields": {name: fid for name, (fid, _) in (view.fields.items() if view else [])},
            "special": {k: list(v) for k, v in desktop.special.items()},
            "pending": desktop.pending_command is not None, "busy": desktop._busy,
            "dialog_open": doc.command("get_dialog", element="as-confirm").get("open"),
            "focused": (doc.focused_element() or {}).get("element"),
            "workers": [w.proc.pid for w in desktop.runtime.workers.values() if w.proc],
            "ui_errors": list(desktop.ui.diagnostics["errors"]),
        }
    if cmd == "rect":
        if request.get("reveal"):
            # The only non-OS action: scroll the target into view, as a user would with the wheel.
            doc.command("scroll_into_view", element=request["id"])
        rect = doc.command("get_rect", element=request["id"])["rect"]
        rect["scroll_y"] = doc.command("get_scroll").get("y", 0)
        return rect
    if cmd == "text":
        return doc.get_text(request["id"])
    if cmd == "value":
        return doc.get_value(request["id"])
    if cmd == "checked":
        return doc.get_checked(request["id"])
    if cmd == "query":
        return doc.query(request["selector"])
    if cmd == "sidebar_button":
        # Sidebar buttons are UI components with generated ids: find one by its label.
        for bid in doc.query(".as-sidebar button")["ids"]:
            if doc.get_text(bid).strip() == request["label"]:
                return bid
        return None
    if cmd == "a11y":
        return doc.command("get_accessibility_tree")
    raise ValueError("unknown probe command " + cmd)


def serve(app: Application, desktop: Desktop) -> None:
    seq = 0
    while True:
        req = CHANNEL / f"req-{seq}.json"
        if not req.exists():
            time.sleep(0.03)
            continue
        request = json.loads(req.read_text("utf-8"))
        done = threading.Event()
        box: dict = {}

        def call():
            try:
                box["result"] = answer(desktop, request)
            except Exception as exc:
                box["error"] = f"{type(exc).__name__}: {exc}"
            finally:
                done.set()
        try:
            desktop.ui.post(call)  # same owner thread as every Desktop handler
            if not done.wait(10):
                box["error"] = "probe call timed out on the UI owner thread"
        except Exception as exc:
            box["error"] = "".join(traceback.format_exception(exc))[-500:]
        tmp = CHANNEL / f"resp-{seq}.tmp"
        tmp.write_text(json.dumps(box, default=str), encoding="utf-8")
        tmp.replace(CHANNEL / f"resp-{seq}.json")
        seq += 1


def main() -> int:
    store = Store(Path(os.environ["APPSHELL_HOME"]))
    store.prepare()
    with Application.start(name="NativeHTMLKit AppShell", app_id="org.nativehtmlkit.AppShell.PythonGuiProbe",
                           instance="multiple") as app:
        desktop = Desktop(AppShellRuntime(store))
        clean = False
        try:
            desktop.launch(app)
            threading.Thread(target=serve, args=(app, desktop), daemon=True).start()
            (CHANNEL / "ready").write_text(str(os.getpid()), encoding="utf-8")
            app.run()
            clean = True
        finally:
            desktop.close(clean=clean)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
