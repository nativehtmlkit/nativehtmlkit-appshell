"""Source of the 'showcase' test extension: every v1 block kind, hostile text and failure commands.

Written into a generated project by the desktop tests; never imported by AppShell itself.
"""
SHOWCASE = r'''
import os, time
from pathlib import Path

HOSTILE = "<script>alert(1)</script> & \" ' <b>bold</b>"


class Extension:
    def manifest(self, context):
        return {"api_version": 1, "id": "org.example.showcase", "title": "Showcase", "version": "0.1.0",
                "pages": [{"id": "controls", "title": "Controls", "order": 1},
                          {"id": "second", "title": "Second page", "order": 2}],
                "commands": [
                    {"id": "echo", "title": "Echo", "risk": "read"},
                    {"id": "save", "title": "Save values", "risk": "write",
                     "confirmation": "Save the form values?"},
                    {"id": "wipe", "title": "Wipe data", "risk": "destructive",
                     "confirmation": "Delete the saved values?"},
                    {"id": "crash_write", "title": "Crash while writing", "risk": "write",
                     "confirmation": "Start a write that crashes?"},
                    {"id": "count", "title": "Count", "risk": "read"},
                ]}

    def page(self, page_id, context):
        data = Path(context["data_dir"])
        saved = (data / "saved.txt").read_text("utf-8") if (data / "saved.txt").exists() else ""
        count = (data / "count.txt").read_text("utf-8") if (data / "count.txt").exists() else "0"
        if page_id == "second":
            return {"title": "Second page", "blocks": [{"kind": "text", "text": "second page body"}]}
        return {"title": "Controls", "blocks": [
            {"kind": "heading", "text": "Level one " + HOSTILE, "level": 1},
            {"kind": "heading", "text": "Level four", "level": 4},
            {"kind": "text", "text": "Saved: " + saved},
            {"kind": "caption", "text": "Count: " + count},
            {"kind": "code", "text": "line 1\n  line 2 " + HOSTILE},
            {"kind": "badge", "text": "beta"},
            {"kind": "notice", "text": "info notice"},
            {"kind": "notice", "text": "danger notice", "tone": "danger"},
            {"kind": "divider"},
            {"kind": "card", "children": [
                {"kind": "row", "children": [
                    {"kind": "column", "children": [
                        {"kind": "input", "name": "title", "label": "Title " + HOSTILE,
                         "value": "café 中", "placeholder": "Type " + HOSTILE},
                        {"kind": "input", "name": "secret", "label": "Secret", "password": True},
                    ]},
                    {"kind": "column", "children": [
                        {"kind": "textarea", "name": "notes", "label": "Notes", "value": "a\nb"},
                        {"kind": "checkbox", "name": "agree", "label": "Agree", "checked": True},
                        {"kind": "select", "name": "level", "label": "Level", "value": "two",
                         "options": [{"value": "one", "label": "One"}, {"value": "two", "label": "Two"},
                                     {"value": "x\"<", "label": "Odd " + HOSTILE}]},
                    ]},
                ]},
            ]},
            {"kind": "table", "columns": [{"key": "name", "title": "Name"}, {"key": "n", "title": "N"}],
             "rows": [{"name": HOSTILE, "n": 1}, {"name": None, "n": 2.5}, {"name": True}]},
            {"kind": "row", "children": [
                {"kind": "button", "text": "Echo", "command": "echo", "params": {"p": "param é"}},
                {"kind": "button", "text": "Save", "command": "save"},
                {"kind": "button", "text": "Wipe", "command": "wipe"},
                {"kind": "button", "text": "Crash write", "command": "crash_write"},
                {"kind": "button", "text": "Count", "command": "count"},
            ]},
        ]}

    def action(self, command_id, values, params, context):
        data = Path(context["data_dir"])
        data.mkdir(parents=True, exist_ok=True)
        if command_id == "echo":
            ordered = ",".join(f"{k}={values[k]!r}" for k in sorted(values))
            return {"message": f"echo {ordered} params={params!r}"}
        if command_id == "save":
            (data / "saved.txt").write_text(values.get("title", ""), encoding="utf-8")
            return {"message": "Saved", "refresh": True}
        if command_id == "wipe":
            (data / "saved.txt").unlink(missing_ok=True)
            return {"message": "Wiped", "refresh": True}
        if command_id == "crash_write":
            (data / "crash-write.txt").write_text("partial", encoding="utf-8")
            os._exit(9)
        if command_id == "count":
            path = data / "count.txt"
            n = int(path.read_text("utf-8")) + 1 if path.exists() else 1
            path.write_text(str(n), encoding="utf-8")
            return {"message": f"count {n}", "refresh": True}
        raise ValueError("unknown command")
'''
