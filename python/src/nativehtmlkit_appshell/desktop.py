"""Thin Python desktop shell built exclusively from public NativeHTMLKit SDK/UI APIs.

Threading: every handler that touches Desktop state or the DOM runs on the UI owner thread.
Sidebar buttons are UI components (already on the owner); delegated document events arrive on
the SDK event worker and are re-posted with ``UI.post``; worker results come back the same way.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from importlib.resources import files

from . import __version__
from .render import esc, render_view, RenderedView
from .runtime import AppShellRuntime


class Desktop:
    def __init__(self, runtime: AppShellRuntime):
        self.runtime = runtime
        self.ui = None
        self.doc = None
        self.nav_id = ""
        self.outlet_id = ""
        self.selected: tuple[str, str] | None = None
        self.generation = 0
        self.active_view: RenderedView | None = None
        self.special: dict[str, tuple[str, str]] = {}
        self.pending_command: tuple[str, str, dict, dict, int] | None = None
        self._confirm_origin: str | None = None
        self.nav_items: dict[str, tuple[str, str]] = {}
        self.executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="appshell-work")
        self.status_state = None
        self.title_state = None
        self._busy = False

    def launch(self, app) -> None:
        from nativehtmlkit_ui import UI, state
        css = files("nativehtmlkit_appshell").joinpath("resources/appshell.css").read_text("utf-8")
        self.title_state = state("Home")
        self.status_state = state("Starting extensions…")
        ui = UI(title="NativeHTMLKit AppShell", width=1110, height=700, theme="cobalt",
                density="compact", extra_css=css)
        self.ui = ui
        with ui.container(css_class="as-layout"):
            with ui.container(css_class="as-sidebar"):
                ui.raw_html('<div class="as-brand">AppShell</div>')
                ui.button("Home", on_click=lambda event: self.show_home(), variant="quiet")
                ui.button("Extensions", on_click=lambda event: self.show_extensions(), variant="quiet")
                ui.button("Settings", on_click=lambda event: self.show_settings(), variant="quiet")
                with ui.container(css_class="as-nav") as nav:
                    ui.text("Loading…", muted=True)
                    self.nav_id = nav.id
            with ui.container(css_class="as-content-shell"):
                with ui.container(css_class="as-toolbar"):
                    ui.heading(self.title_state, level=2)
                with ui.container(css_class="as-content") as region:
                    ui.text("Loading AppShell…", muted=True)
                    self.outlet_id = region.id
        with ui.container(css_class="as-footer", attrs={"role": "status", "aria-live": "polite"}):
            ui.text(self.status_state, muted=True)
        ui.raw_html('''<dialog id="as-confirm" aria-labelledby="as-confirm-title" aria-describedby="as-confirm-text">
          <h3 id="as-confirm-title">Confirm action</h3><p id="as-confirm-text"></p>
          <div class="as-row"><button id="as-confirm-ok" class="as-button" type="button">Confirm</button>
          <button id="as-confirm-cancel" class="as-button" type="button">Cancel</button></div>
          </dialog>''')
        ui.mount(app)
        self.doc = ui.document
        post = self.ui.post
        self.doc.on("click", lambda event: post(self._on_nav_click, event), element=self.nav_id)
        self.doc.on("click", lambda event: post(self._on_content_click, event), element=self.outlet_id)
        self.doc.on("click", lambda event: post(self._on_confirm_click, event), element="as-confirm")
        # Confirm, Cancel and Escape all end in the dialog's close event.
        self.doc.on("close", lambda event: post(self._on_confirm_closed, event), element="as-confirm")
        self.show_home()
        self.executor.submit(self._background_boot)

    def _background_boot(self) -> None:
        self.runtime.boot(on_progress=lambda: self.ui.post(self._refresh_nav))
        self.ui.post(self._ready)

    def _ready(self) -> None:
        if self.status_state:
            count = sum(1 for v in self.runtime.status.values() if v == "ACTIVE")
            self.status_state.set(f"{count} extensions active" +
                                  (f" · {len(self.runtime.errors)} errors" if self.runtime.errors else "") +
                                  (" · safe mode" if self.runtime.safe_mode else ""))
        self._refresh_nav()
        if self.runtime.message or self.runtime.errors:
            self.show_home()

    def _refresh_nav(self) -> None:
        if self.doc is None:
            return
        chunks = ['<div class="as-nav-label">Installed</div>']
        for i, (ident, page) in enumerate(self.runtime.get_pages()):
            eid = f"as-nav-{i}"
            active = "active" if self.selected == (ident, page["id"]) else ""
            chunks.append(f'<button type="button" class="as-nav-link {active}" id="{eid}">{esc(page["title"])}</button>')
        self.nav_items = {f"as-nav-{i}": (ident, page["id"])
                          for i, (ident, page) in enumerate(self.runtime.get_pages())}
        if self.selected is not None and self.selected not in self.nav_items.values():
            self.selected = None
        try:
            self.doc.replace_html(self.nav_id, "".join(chunks))
        except Exception:
            pass

    def _set_content(self, title: str, markup: str) -> None:
        self.generation += 1
        self.title_state.set(title)
        self.special = {}
        self.active_view = None
        self.doc.replace_html(self.outlet_id, markup)
        self._refresh_nav()

    def show_home(self) -> None:
        self.selected = None
        r = self.runtime
        rows = [f'<p class="as-text">NativeHTMLKit AppShell {esc(__version__)}. A native, local-first extension host.</p>']
        if r.message:
            rows.append(f'<div class="as-notice as-notice-warning">{esc(r.message)}</div>')
        if r.errors:
            rows.append(f'<div class="as-notice as-notice-danger">{len(r.errors)} extension errors. See Extensions for details.</div>')
        rows.append('<div class="as-card"><h3>Getting started</h3>'
                    '<p class="as-text">Copy a Python package project into the extensions folder, or stage a pinned package. '
                    'Restart AppShell to activate it.</p></div>')
        self._set_content("Home", "".join(rows))

    def show_extensions(self) -> None:
        self.selected = None
        r = self.runtime
        self.special = {}
        rows = ['<p class="as-caption">Install from a local wheel/project or a pinned PyPI/GitHub source. '
                'Changes apply after restart.</p>',
                '<div class="as-card"><label class="as-field-label" for="as-new-source">Package source</label>',
                '<input id="as-new-source" type="text" placeholder="./project or name==1.2.3 or git+https://github.com/owner/repo@SHA">',
                '<label class="as-field-label"><input type="checkbox" id="as-trust"> I trust this source to execute with my user privileges.</label>',
                '<button class="as-button" id="as-stage" type="button">Add for next restart</button></div>',
                f'<p class="as-caption">Drop-in directory: {esc(r.store.extensions)}</p>']
        for ident, record in sorted(r.registry.get("extensions", {}).items()):
            status = r.status.get(ident, "NOT LOADED")
            ident_key = f"as-ext-{len(self.special)}"
            action = "enable" if not record.get("enabled", True) else "disable"
            self.special[ident_key] = (action, ident)
            remove_key = ident_key + "-remove"
            self.special[remove_key] = ("remove", ident)
            rows.append(f'<div class="as-extension"><strong>{esc(ident)}</strong>'
                        f'<p class="as-meta">{esc(record.get("version"))} · {esc(status)} · {esc(record.get("distribution", ""))}</p>'
                        f'<button id="{ident_key}" type="button" class="as-button">{esc(action.title())} on restart</button>'
                        f'<button id="{remove_key}" type="button" class="as-button">Remove</button>'
                        '</div>')
        for key, error in sorted(r.errors.items()):
            rows.append(f'<div class="as-notice as-notice-danger"><strong>{esc(key)}</strong>: {esc(error)}</div>')
        self.generation += 1
        self.active_view = None
        self.title_state.set("Extensions")
        self.doc.replace_html(self.outlet_id, "".join(rows))
        self._refresh_nav()

    def show_settings(self) -> None:
        self.selected = None
        self._set_content("Settings", '<div class="as-card"><h3>Local configuration</h3>'
                          f'<p class="as-text">Data: {esc(self.runtime.store.home)}</p>'
                          f'<p class="as-text">Extensions: {esc(self.runtime.store.extensions)}</p>'
                          '<p class="as-text">No telemetry, marketplace backend, or remote server.</p>'
                          '</div><div class="as-card">'
                          '<button class="as-button" id="as-restore" type="button">Restore last-known-good on next restart</button>'
                          '</div>')

    def show_page(self, ident: str, page_id: str) -> None:
        self.selected = (ident, page_id)
        self.generation += 1
        token = self.generation
        self.active_view = None
        self.title_state.set(self.runtime.manifests[ident]["title"])
        self.doc.replace_html(self.outlet_id, '<p class="as-caption">Loading extension page…</p>')
        self._refresh_nav()
        future = self.executor.submit(self.runtime.page, ident, page_id)
        future.add_done_callback(lambda f: self.ui.post(self._page_loaded, token, f))

    def _page_loaded(self, token, future) -> None:
        if token != self.generation:
            return
        try:
            view = future.result()
            manifest = self.runtime.manifests[self.selected[0]]
            rendered = render_view(view, manifest, generation=token)
            self.doc.replace_html(self.outlet_id, rendered.html)
            self.active_view = rendered
            self.title_state.set(view["title"])
        except Exception as exc:
            self.doc.replace_html(self.outlet_id, f'<div class="as-notice as-notice-danger">{esc(exc)}</div>')

    def _on_nav_click(self, event: dict) -> None:
        for identifier in [event.get("element", ""), *event.get("path", [])]:
            if identifier in self.nav_items:
                self.show_page(*self.nav_items[identifier])
                return

    def _on_content_click(self, event: dict) -> None:
        clicked = event.get("element")
        if clicked == "as-stage":
            source = self.doc.get_value("as-new-source")
            if not self.doc.get_checked("as-trust"):
                self.status_state.set("Confirm that you trust the extension source")
                return
            if not source.strip():
                self.status_state.set("Enter a source first")
                return
            self.status_state.set("Staging package…")
            future = self.executor.submit(self.runtime.store.stage, source)
            future.add_done_callback(lambda f: self.ui.post(self._stage_finished, f))
            return
        if clicked == "as-restore":
            (self.runtime.store.home / "restore-on-next-start").write_text("1", encoding="ascii")
            self.status_state.set("Restore requested. Restart AppShell.")
            return
        if clicked in self.special:
            action, ident = self.special[clicked]
            self.runtime.store.queue(action, id=ident)
            self.status_state.set(f"{action.title()} queued for {ident} · Restart required")
            return
        if not self.active_view or not self.selected:
            return
        for identifier in [clicked, *event.get("path", [])]:
            if identifier in self.active_view.buttons:
                command_id, params = self.active_view.buttons[identifier]
                commands = {c["id"]: c for c in self.runtime.manifests[self.selected[0]].get("commands", [])}
                command = commands[command_id]
                values = {}
                for name, (element, kind) in self.active_view.fields.items():
                    values[name] = self.doc.get_checked(element) if kind == "checkbox" else self.doc.get_value(element)
                if self._busy:
                    self.status_state.set("Another action is still running; wait for it to finish")
                    return
                self.pending_command = (self.selected[0], command_id, values, params, self.generation)
                if command["risk"] != "read":
                    self._confirm_origin = identifier
                    self.doc.set_text("as-confirm-title", command["title"])
                    self.doc.set_text("as-confirm-text", command["confirmation"])
                    self.doc.show_dialog("as-confirm")
                    # Explicit initial focus: Cancel for destructive commands, so Enter is safe.
                    self.doc.focus("as-confirm-cancel" if command["risk"] == "destructive" else "as-confirm-ok")
                else:
                    self._dispatch_action()
                return

    def _on_confirm_click(self, event: dict) -> None:
        if event.get("element") == "as-confirm-cancel":
            self.doc.close_dialog("as-confirm", "cancel")
        elif event.get("element") == "as-confirm-ok":
            self.doc.close_dialog("as-confirm", "ok")

    def _on_confirm_closed(self, event: dict) -> None:
        confirmed = event.get("return_value") == "ok"
        origin, self._confirm_origin = self._confirm_origin, None
        if not confirmed:
            self.pending_command = None
            self.status_state.set("Cancelled")
        if origin and self.active_view and origin in self.active_view.buttons:
            try:
                self.doc.focus(origin)  # give keyboard focus back to the button that asked
            except Exception:
                pass
        if confirmed:
            self._dispatch_action()

    def _dispatch_action(self) -> None:
        if self._busy or self.pending_command is None:
            return
        ident, command, values, params, token = self.pending_command
        self.pending_command = None
        if self.selected is None or self.selected[0] != ident or self.generation != token:
            return
        self._busy = True
        self.status_state.set(f"Running {command}…")
        future = self.executor.submit(self.runtime.action, ident, command, values, params)
        future.add_done_callback(lambda f: self.ui.post(self._action_finished, ident, token, f))

    def _action_finished(self, ident, token, future) -> None:
        self._busy = False
        try:
            result = future.result()
            self.status_state.set(result.get("message", "Action completed"))
            if result.get("refresh") and self.selected and self.selected[0] == ident and token == self.generation:
                self.show_page(*self.selected)
        except Exception as exc:
            self.status_state.set(str(exc)[:500])
            if self.selected and self.selected[0] == ident and token == self.generation:
                # Keep page visible; never retry a timed-out destructive action. The notice is
                # scrolled into view: on a long page the button that failed may be far below it.
                notice = f"as-action-error-{token}"
                self.doc.insert_html(self.outlet_id, f'<div id="{notice}" role="alert" class="as-notice as-notice-danger">'
                                     f'{esc(exc)}</div>', position="afterbegin")
                self.doc.scroll_into_view(notice)

    def _stage_finished(self, future) -> None:
        try:
            future.result()
            self.status_state.set("Package staged · Restart AppShell to install and activate")
            self.show_extensions()
        except Exception as exc:
            self.status_state.set(f"Install request failed: {exc}")

    def close(self, *, clean: bool = True) -> None:
        self.executor.shutdown(wait=False, cancel_futures=True)
        self.runtime.stop(clean=clean)
