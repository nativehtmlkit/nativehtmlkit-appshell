"""Desktop scenario: run the real AppShell Desktop on the native host and drive it.

usage: python desktop_scenario.py OUT.json   (APPSHELL_HOME names a prepared home)

Started directly, ``Application.start`` launches the packaged host, which re-runs this file as
its backend. The backend mounts the real Desktop, then a driver thread posts the same calls
the delegated SDK click/close handlers post (``Desktop._on_*`` on the UI owner thread) and
reads the resulting DOM back through public SDK document methods. This proves AppShell logic,
SDK/UI compatibility and DOM output against the real host; it does not prove native input
(see docs/VERIFICATION.md for the real-input GUI runs).
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

OUT = Path(sys.argv[1])
RESULTS: dict = {"checks": [], "failed": [], "timings": {}}
T0 = time.monotonic()


def check(name: str, ok: bool, detail: object = "") -> None:
    RESULTS["checks"].append({"name": name, "ok": bool(ok), "detail": str(detail)[:600]})
    if not ok:
        RESULTS["failed"].append(name)


def on_owner(desktop: Desktop, fn, *args, timeout: float = 10):
    """Run fn on the UI owner thread (where Desktop handlers run) and return its result."""
    done = threading.Event()
    box: dict = {}

    def call():
        try:
            box["value"] = fn(*args)
        except BaseException as exc:  # reported to the driver
            box["error"] = exc
        finally:
            done.set()
    desktop.ui.post(call)
    if not done.wait(timeout):
        raise TimeoutError(f"owner call timed out: {fn}")
    if "error" in box:
        raise box["error"]
    return box.get("value")


def wait_for(predicate, timeout: float = 20, what: str = "condition"):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise TimeoutError("timed out waiting for " + what)


def settle(desktop: Desktop) -> None:
    """Two owner round-trips: work posted by a handler (including SDK events) has run."""
    on_owner(desktop, lambda: None)
    time.sleep(0.05)
    on_owner(desktop, lambda: None)


def drive(app: Application, desktop: Desktop) -> None:
    doc = desktop.doc
    store = desktop.runtime.store
    data = store.data / "org.example.showcase"
    try:
        RESULTS["timings"]["mounted_s"] = round(time.monotonic() - T0, 3)
        check("home visible before boot finishes", "AppShell" in doc.get_text(desktop.outlet_id))
        wait_for(lambda: desktop.runtime._boot_complete or desktop.runtime.safe_mode, 120, "boot")
        settle(desktop)
        RESULTS["timings"]["booted_s"] = round(time.monotonic() - T0, 3)
        nav = doc.get_text(desktop.nav_id)
        check("nav lists extension pages", "Controls" in nav and "Second page" in nav, nav)
        check("status reports active extensions", "1 extensions active" in desktop.status_state.value,
              desktop.status_state.value)
        nav_ids = {v: k for k, v in desktop.nav_items.items()}
        controls = nav_ids[("org.example.showcase", "controls")]
        second = nav_ids[("org.example.showcase", "second")]

        def open_page(nav_id, path=()):
            on_owner(desktop, desktop._on_nav_click, {"type": "click", "element": nav_id, "path": list(path)})
            wait_for(lambda: desktop.active_view is not None, 20, "page " + nav_id)
            settle(desktop)

        # Delegated event: click lands on a child; the nav id is only in the event path.
        open_page("", (controls, desktop.nav_id))
        view = desktop.active_view
        text = doc.get_text(desktop.outlet_id)
        check("page rendered", "Level one" in text and "Saved:" in text, text[:200])
        check("hostile text shown as text", "<script>alert(1)</script>" in text, text[:300])
        scripts = doc.query("#%s script, #%s b" % (desktop.outlet_id, desktop.outlet_id))
        check("no script/b element from extension text", scripts["matched_nodes"] == 0, scripts)
        for selector, label in (("h1.as-heading", "heading 1"), ("h4.as-heading", "heading 4"),
                                ("small.as-caption", "caption"), ("pre.as-code", "code"),
                                ("span.as-badge", "badge"), (".as-notice-danger", "danger notice"),
                                ("hr.as-divider", "divider"), (".as-card .as-row .as-column", "containers"),
                                ("table.as-table th", "table header"), ("input[type=password]", "password"),
                                ("textarea", "textarea"), ("input[type=checkbox]", "checkbox"),
                                ("select option", "select options")):
            found = doc.query(f"#{desktop.outlet_id} {selector}")["matched_nodes"]
            check(f"control rendered: {label}", found > 0, selector)
        fields = view.fields
        check("all fields registered", set(fields) == {"title", "secret", "notes", "agree", "level"}, fields)
        check("input initial value", doc.get_value(fields["title"][0]) == "café 中")
        check("textarea initial value", doc.get_value(fields["notes"][0]) == "a\nb")
        check("checkbox initial", doc.get_checked(fields["agree"][0]) is True)
        check("select initial", doc.get_value(fields["level"][0]) == "two")
        options = [o.get("value") for o in doc.options(fields["level"][0])]
        check("select option values escaped", options == ["one", "two", "x\"<"], options)
        buttons = {cmd: bid for bid, (cmd, _) in view.buttons.items()}

        def click(element, path=()):
            on_owner(desktop, desktop._on_content_click, {"type": "click", "element": element,
                                                          "path": list(path) + [desktop.outlet_id]})
            settle(desktop)

        def dialog_open():
            return doc.command("get_dialog", element="as-confirm").get("open")

        # Read action: no confirmation, exact current values and params.
        doc.set_value(fields["title"][0], "typed é <x>")
        doc.set_value(fields["secret"][0], "hunter2")
        doc.set_checked(fields["agree"][0], False)
        doc.set_value(fields["level"][0], "x\"<")
        click(buttons["echo"])
        wait_for(lambda: desktop.status_state.value.startswith("echo"), 20, "echo")
        status = desktop.status_state.value
        check("read action sends current values and params",
              "title='typed é <x>'" in status and "agree=False" in status and "level='x\"<'" in status
              and "secret='hunter2'" in status and "params={'p': 'param é'}" in status, status)
        check("read action shows no dialog", not dialog_open())

        # Write: dialog, focus, cancel, then confirm.
        click(buttons["save"])
        check("write opens confirm dialog", dialog_open())
        check("confirm text is the manifest confirmation",
              doc.get_text("as-confirm-text") == "Save the form values?", doc.get_text("as-confirm-text"))
        focused = (doc.focused_element() or {}).get("element")
        check("write dialog focuses Confirm", focused == "as-confirm-ok", focused)
        on_owner(desktop, desktop._on_confirm_click, {"type": "click", "element": "as-confirm-cancel"})
        wait_for(lambda: not dialog_open(), 10, "dialog close")
        settle(desktop)
        check("cancel runs nothing", not (data / "saved.txt").exists() and desktop.pending_command is None)
        check("cancel status", desktop.status_state.value == "Cancelled", desktop.status_state.value)
        focused = (doc.focused_element() or {}).get("element")
        check("focus returns to the Save button after cancel", focused == buttons["save"], focused)

        click(buttons["save"])
        on_owner(desktop, desktop._on_confirm_click, {"type": "click", "element": "as-confirm-ok"})
        wait_for(lambda: (data / "saved.txt").exists(), 20, "save")
        wait_for(lambda: desktop.active_view is not None and desktop.active_view is not view, 20, "refresh")
        settle(desktop)
        check("confirmed write ran once with typed value",
              (data / "saved.txt").read_text("utf-8") == "typed é <x>")
        check("refresh shows saved value", "Saved: typed é <x>" in doc.get_text(desktop.outlet_id))
        view = desktop.active_view
        buttons = {cmd: bid for bid, (cmd, _) in view.buttons.items()}

        # Destructive: Cancel focused by default; Escape (close without "ok") cancels.
        click(buttons["wipe"])
        focused = (doc.focused_element() or {}).get("element")
        check("destructive dialog focuses Cancel", focused == "as-confirm-cancel", focused)
        doc.close_dialog("as-confirm")  # what Escape produces: close with no "ok" return value
        wait_for(lambda: not dialog_open(), 10, "escape close")
        settle(desktop)
        check("escape cancels destructive", (data / "saved.txt").exists() and desktop.pending_command is None)

        # Stale page event: navigate away while the dialog is open, then confirm.
        click(buttons["wipe"])
        open_page(second)
        on_owner(desktop, desktop._on_confirm_click, {"type": "click", "element": "as-confirm-ok"})
        settle(desktop)
        time.sleep(0.5)
        check("confirm after navigation does not run the stale command", (data / "saved.txt").exists())
        click(buttons["wipe"])  # a button id from the old generation
        check("stale button id from previous page ignored", not dialog_open())

        # Rapid navigation and repeated refresh.
        for i in range(100):
            on_owner(desktop, desktop._on_nav_click, {"type": "click", "element": controls if i % 2 else second,
                                                      "path": []})
        wait_for(lambda: desktop.active_view is not None and desktop.selected == ("org.example.showcase", "controls"),
                 30, "rapid navigation")
        settle(desktop)
        check("rapid navigation ends on the last page", "Level one" in doc.get_text(desktop.outlet_id)
              and desktop.title_state.value == "Controls", desktop.title_state.value)
        started = time.monotonic()
        for i in range(100):
            view = desktop.active_view
            buttons = {cmd: bid for bid, (cmd, _) in view.buttons.items()}
            click(buttons["count"])
            wait_for(lambda: desktop.active_view is not None and desktop.active_view is not view, 20, "count refresh")
        settle(desktop)
        RESULTS["timings"]["refresh_100_s"] = round(time.monotonic() - started, 2)
        check("100 refresh actions all applied", (data / "count.txt").read_text("utf-8") == "100"
              and "Count: 100" in doc.get_text(desktop.outlet_id))
        check("UI library reports no errors", not desktop.ui.diagnostics["errors"], desktop.ui.diagnostics)

        # Worker crash during a write: unknown outcome shown, never retried, shell keeps working.
        view = desktop.active_view
        buttons = {cmd: bid for bid, (cmd, _) in view.buttons.items()}
        click(buttons["crash_write"])
        on_owner(desktop, desktop._on_confirm_click, {"type": "click", "element": "as-confirm-ok"})
        wait_for(lambda: "Outcome unknown" in desktop.status_state.value, 20, "unknown outcome")
        settle(desktop)
        check("crash during write reports unknown outcome",
              "do not retry" in doc.get_text(desktop.outlet_id), desktop.status_state.value)
        (data / "crash-write.txt").unlink()
        time.sleep(1)
        check("crashed write not retried", not (data / "crash-write.txt").exists())
        open_page(controls)
        check("extension usable again after crash", "Level one" in doc.get_text(desktop.outlet_id))

        # Shell pages.
        on_owner(desktop, desktop.show_extensions)
        text = doc.get_text(desktop.outlet_id)
        check("extensions page lists extension", "org.example.showcase" in text and "ACTIVE" in text, text[:300])
        key = next(k for k, v in desktop.special.items() if v == ("disable", "org.example.showcase"))
        click(key)
        check("disable queued for restart", store.pending()["operations"][-1]["action"] == "disable")
        store.pop_pending()
        click("as-stage")
        check("staging requires trust confirmation", "trust" in desktop.status_state.value.lower())
        on_owner(desktop, desktop.show_settings)
        check("settings page", "No telemetry" in doc.get_text(desktop.outlet_id))
        on_owner(desktop, desktop.show_home)
        check("home page", "Getting started" in doc.get_text(desktop.outlet_id))
        footer = doc.query(".as-footer[role=status]")["matched_nodes"]
        check("status footer is a live region", footer == 1, footer)
        RESULTS["worker_pids"] = [w.proc.pid for w in desktop.runtime.workers.values() if w.proc]
    except BaseException as exc:
        check("driver exception", False, "".join(traceback.format_exception(exc))[-1500:])
    finally:
        RESULTS["finished"] = True
        OUT.write_text(json.dumps(RESULTS, indent=1), encoding="utf-8")
        app.request_quit()


def main() -> None:
    store = Store(Path(os.environ["APPSHELL_HOME"]))
    store.prepare()
    with Application.start(name="AppShell scenario", app_id="org.nativehtmlkit.AppShell.PythonScenario",
                           instance="multiple") as app:
        desktop = Desktop(AppShellRuntime(store))
        clean = False
        try:
            desktop.launch(app)
            threading.Thread(target=drive, args=(app, desktop), daemon=True).start()
            app.run()
            clean = True
        finally:
            desktop.close(clean=clean)


if __name__ == "__main__":
    main()
