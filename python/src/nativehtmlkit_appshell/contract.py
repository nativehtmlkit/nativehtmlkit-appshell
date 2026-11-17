"""Frozen v1 extension contracts, implemented without third-party runtime dependencies.

These checks intentionally duplicate the authoritative JSON Schema and add semantic rules.
Untrusted plugin output is DATA.  No rendering code imports or executes plugin HTML.
"""
from __future__ import annotations

import json
import re
import sys
from typing import Any

API_VERSION = 1
EXTENSION_ID = re.compile(r"^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9-]*)+$")
SLUG = re.compile(r"^[a-z][a-z0-9_-]*$")
MANIFEST_LIMIT = 128 * 1024
VIEW_LIMIT = 1024 * 1024
FRAME_LIMIT = VIEW_LIMIT + 65536


class ContractError(ValueError):
    pass


def _fail(where: str, message: str) -> None:
    raise ContractError(f"{where}: {message}")


def _object(value: Any, where: str, required: set[str], allowed: set[str]) -> dict:
    if not isinstance(value, dict):
        _fail(where, "expected object")
    unexpected = set(value) - allowed
    absent = required - set(value)
    if absent or unexpected:
        _fail(where, f"missing {sorted(absent)}; unknown {sorted(unexpected)}")
    return value


def _str(value: Any, where: str, max_len: int, *, nonempty: bool = False) -> str:
    if not isinstance(value, str) or len(value) > max_len or (nonempty and not value.strip()):
        _fail(where, f"expected {'nonempty ' if nonempty else ''}string up to {max_len} characters")
    return value


def _list(value: Any, where: str, maximum: int, *, minimum: int = 0) -> list:
    if not isinstance(value, list) or not minimum <= len(value) <= maximum:
        _fail(where, f"expected array length {minimum}..{maximum}")
    return value


def _size(value: dict, limit: int, label: str) -> None:
    try:
        length = len(json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8"))
    except (ValueError, TypeError, UnicodeError) as exc:
        _fail(label, f"not a finite JSON value ({exc})")
    if length > limit:
        _fail(label, f"serialized content exceeds {limit} bytes")


def _slug(value: Any, where: str) -> str:
    _str(value, where, 64, nonempty=True)
    if not SLUG.fullmatch(value):
        _fail(where, "invalid identifier")
    return value


def _unique(items: list[dict], label: str) -> None:
    seen: set[str] = set()
    for item in items:
        ident = item["id"]
        if ident in seen:
            _fail(label, f"duplicate ID {ident!r}")
        seen.add(ident)


def validate_manifest(value: Any, expected_id: str | None = None, expected_version: str | None = None) -> dict:
    m = _object(value, "manifest", {"api_version", "id", "title", "version", "pages"},
                {"api_version", "id", "title", "version", "description", "platforms", "pages", "commands"})
    if type(m["api_version"]) is not int or m["api_version"] != API_VERSION:
        _fail("manifest.api_version", "unsupported extension contract version")
    _str(m["id"], "manifest.id", 140, nonempty=True)
    if not EXTENSION_ID.fullmatch(m["id"]):
        _fail("manifest.id", "expected reverse-domain lowercase ID")
    if expected_id is not None and m["id"] != expected_id:
        _fail("manifest.id", "ID differs from installed entry point/module metadata")
    _str(m["title"], "manifest.title", 120, nonempty=True)
    _str(m["version"], "manifest.version", 100, nonempty=True)
    if expected_version is not None and m["version"] != expected_version:
        _fail("manifest.version", "version differs from installed package metadata")
    _str(m.get("description", ""), "manifest.description", 2000)
    if "platforms" in m:
        platforms = _list(m["platforms"], "manifest.platforms", 2, minimum=1)
        if any(x not in ("linux", "windows") for x in platforms) or len(set(platforms)) != len(platforms):
            _fail("manifest.platforms", "invalid/duplicate platforms")
        actual = "windows" if sys.platform == "win32" else "linux"
        if actual not in platforms:
            _fail("manifest.platforms", f"extension does not support {actual}")
    pages = _list(m["pages"], "manifest.pages", 100, minimum=1)
    for i, page in enumerate(pages):
        label = f"manifest.pages[{i}]"
        _object(page, label, {"id", "title"}, {"id", "title", "description", "order"})
        _slug(page["id"], label + ".id")
        _str(page["title"], label + ".title", 120, nonempty=True)
        _str(page.get("description", ""), label + ".description", 500)
        order = page.get("order", 100)
        if type(order) is not int or order < 0 or order > 9999:
            _fail(label + ".order", "expected integer 0..9999")
    _unique(pages, "manifest.pages")
    commands = _list(m.get("commands", []), "manifest.commands", 100)
    for i, command in enumerate(commands):
        label = f"manifest.commands[{i}]"
        _object(command, label, {"id", "title", "risk"}, {"id", "title", "risk", "confirmation"})
        _slug(command["id"], label + ".id")
        _str(command["title"], label + ".title", 120, nonempty=True)
        if command["risk"] not in ("read", "write", "destructive"):
            _fail(label + ".risk", "invalid risk")
        if "confirmation" in command:
            _str(command["confirmation"], label + ".confirmation", 500, nonempty=True)
        if command["risk"] != "read" and not command.get("confirmation"):
            _fail(label, "write/destructive command missing confirmation")
    _unique(commands, "manifest.commands")
    _size(m, MANIFEST_LIMIT, "manifest")
    return m


TEXT_NODES = {"text": 10000, "caption": 10000, "code": 10000, "badge": 10000, "heading": 300, "notice": 5000}
FIELDS = {"input", "textarea", "checkbox", "select"}
CONTAINERS = {"row", "column", "card"}


def validate_view(view: Any, manifest: dict | None = None) -> dict:
    v = _object(view, "view", {"title", "blocks"}, {"title", "blocks"})
    _str(v["title"], "view.title", 120, nonempty=True)
    _list(v["blocks"], "view.blocks", 300)
    commands = {c["id"] for c in (manifest or {}).get("commands", [])}
    names: set[str] = set()
    node_count = 0

    def visit(nodes: list, depth: int) -> None:
        nonlocal node_count
        if depth > 10:
            _fail("view.blocks", "maximum container depth exceeded")
        for i, block in enumerate(nodes):
            label = f"view.block[{node_count}:{i}]"
            if not isinstance(block, dict) or not isinstance(block.get("kind"), str):
                _fail(label, "expected block object with kind")
            node_count += 1
            if node_count > 300:
                _fail(label, "too many nodes")
            kind = block["kind"]
            if kind in TEXT_NODES:
                allowed = {"kind", "text"} | ({"level"} if kind == "heading" else set()) | ({"tone"} if kind == "notice" else set())
                _object(block, label, {"kind", "text"}, allowed)
                _str(block["text"], label + ".text", TEXT_NODES[kind])
                if kind == "heading":
                    n = block.get("level", 2)
                    if type(n) is not int or not 1 <= n <= 4:
                        _fail(label, "heading level must be 1..4")
                if kind == "notice" and block.get("tone", "info") not in ("info", "success", "warning", "danger"):
                    _fail(label, "unsupported notice tone")
            elif kind == "divider":
                _object(block, label, {"kind"}, {"kind"})
            elif kind in CONTAINERS:
                _object(block, label, {"kind", "children"}, {"kind", "children"})
                visit(_list(block["children"], label + ".children", 300), depth + 1)
            elif kind in FIELDS:
                common = {"kind", "name", "label"}
                options = {"kind", "name", "label", "value", "placeholder", "password"} if kind == "input" else (
                    {"kind", "name", "label", "value"} if kind == "textarea" else (
                    {"kind", "name", "label", "checked"} if kind == "checkbox" else
                    {"kind", "name", "label", "value", "options"}))
                required = common | ({"options"} if kind == "select" else set())
                _object(block, label, required, options)
                name = _slug(block["name"], label + ".name")
                if name in names:
                    _fail(label, "duplicate form field name")
                names.add(name)
                if len(names) > 80:
                    _fail(label, "too many form fields")
                _str(block["label"], label + ".label", 200)
                if kind in ("input", "textarea", "select"):
                    _str(block.get("value", ""), label + ".value", 10000)
                if kind == "input":
                    _str(block.get("placeholder", ""), label + ".placeholder", 200)
                    if type(block.get("password", False)) is not bool:
                        _fail(label, "password must be bool")
                if kind == "checkbox" and type(block.get("checked", False)) is not bool:
                    _fail(label, "checked must be bool")
                if kind == "select":
                    options = _list(block["options"], label + ".options", 100)
                    seen: set[str] = set()
                    for option in options:
                        _object(option, label + ".option", {"value", "label"}, {"value", "label"})
                        k = _str(option["value"], label + ".option.value", 200)
                        _str(option["label"], label + ".option.label", 200)
                        if k in seen:
                            _fail(label, "duplicate option value")
                        seen.add(k)
                    if block.get("value", "") not in seen | {""}:
                        _fail(label, "select value not one of options")
            elif kind == "button":
                _object(block, label, {"kind", "text", "command"}, {"kind", "text", "command", "params"})
                _str(block["text"], label + ".text", 200)
                _slug(block["command"], label + ".command")
                if manifest is not None and block["command"] not in commands:
                    _fail(label, f"undeclared command {block['command']!r}")
                if not isinstance(block.get("params", {}), dict):
                    _fail(label, "params must be object")
                _size(block.get("params", {}), 16 * 1024, label + ".params")
            elif kind == "table":
                _object(block, label, {"kind", "columns", "rows"}, {"kind", "columns", "rows"})
                cols = _list(block["columns"], label + ".columns", 24)
                rows = _list(block["rows"], label + ".rows", 200)
                keys: set[str] = set()
                for c in cols:
                    _object(c, label + ".column", {"key", "title"}, {"key", "title"})
                    key = _slug(c["key"], label + ".column.key")
                    _str(c["title"], label + ".column.title", 120)
                    if key in keys:
                        _fail(label, "duplicate column key")
                    keys.add(key)
                for row in rows:
                    if not isinstance(row, dict):
                        _fail(label, "table row must be object")
                    for k, cell in row.items():
                        if not isinstance(k, str) or not (cell is None or isinstance(cell, (str, float, int, bool))):
                            _fail(label, "table cells must be scalar")
            else:
                _fail(label, f"unsupported block {kind!r}")
    visit(v["blocks"], 0)
    _size(v, VIEW_LIMIT, "view")
    return v


def validate_result(value: Any) -> dict:
    _object(value, "result", set(), {"message", "refresh"})
    if "message" in value:
        _str(value["message"], "result.message", 500)
    if type(value.get("refresh", False)) is not bool:
        _fail("result.refresh", "expected boolean")
    _size(value, 4096, "result")
    return value
