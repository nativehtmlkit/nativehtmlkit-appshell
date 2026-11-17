"""AppShell-owned semantic HTML renderer. Plugin values never become markup."""
from __future__ import annotations

from dataclasses import dataclass
import html
from typing import Any

from .contract import validate_view


def esc(value: Any) -> str:
    return html.escape("" if value is None else str(value), quote=True)


@dataclass
class RenderedView:
    html: str
    fields: dict[str, tuple[str, str]]
    buttons: dict[str, tuple[str, dict]]


def render_view(value: dict, manifest: dict, *, generation: int = 1) -> RenderedView:
    validate_view(value, manifest)
    fields: dict[str, tuple[str, str]] = {}
    buttons: dict[str, tuple[str, dict]] = {}
    index = 0

    def node(b: dict) -> str:
        nonlocal index
        index += 1
        n = index
        kind = b["kind"]
        if kind == "heading":
            level = b.get("level", 2)
            return f'<h{level} class="as-heading">{esc(b["text"])}</h{level}>'
        if kind in ("text", "caption", "code", "badge"):
            tag = {"text": "p", "caption": "small", "code": "pre", "badge": "span"}[kind]
            return f'<{tag} class="as-{kind}">{esc(b["text"])}</{tag}>'
        if kind == "notice":
            return f'<div role="status" class="as-notice as-notice-{b.get("tone", "info")}">{esc(b["text"])}</div>'
        if kind == "divider":
            return '<hr class="as-divider">'
        if kind in ("card", "row", "column"):
            return f'<div class="as-{kind}">' + "".join(node(c) for c in b["children"]) + "</div>"
        if kind in ("input", "textarea", "checkbox", "select"):
            ident = f"as-field-{generation}-{n}"
            name = b["name"]
            fields[name] = (ident, kind)
            title = f'<label class="as-field-label" for="{ident}">{esc(b["label"])}</label>'
            if kind == "input":
                control = (f'<input id="{ident}" name="{esc(name)}" type="{"password" if b.get("password") else "text"}" '
                           f'value="{esc(b.get("value", ""))}" placeholder="{esc(b.get("placeholder", ""))}">')
            elif kind == "textarea":
                control = f'<textarea id="{ident}" name="{esc(name)}">{esc(b.get("value", ""))}</textarea>'
            elif kind == "checkbox":
                control = f'<input id="{ident}" name="{esc(name)}" type="checkbox" {"checked" if b.get("checked") else ""}>'
            else:
                options = "".join(f'<option value="{esc(o["value"])}" {"selected" if o["value"] == b.get("value", "") else ""}>{esc(o["label"])}</option>'
                                  for o in b["options"])
                control = f'<select id="{ident}" name="{esc(name)}">{options}</select>'
            return f'<div class="as-field">{title}{control}</div>'
        if kind == "button":
            ident = f"as-button-{generation}-{n}"
            buttons[ident] = (b["command"], b.get("params", {}))
            return f'<button id="{ident}" type="button" class="as-button">{esc(b["text"])}</button>'
        if kind == "table":
            cols = b["columns"]
            head = "".join(f'<th scope="col">{esc(c["title"])}</th>' for c in cols)
            rows = []
            for record in b["rows"]:
                cells = "".join(f'<td>{esc(record.get(c["key"]))}</td>' for c in cols)
                rows.append(f"<tr>{cells}</tr>")
            return '<div class="as-table-wrap"><table class="as-table"><thead><tr>' + head + '</tr></thead><tbody>' + "".join(rows) + '</tbody></table></div>'
        raise AssertionError("validate_view must catch every unsupported block")

    return RenderedView("".join(node(block) for block in value["blocks"]), fields, buttons)
