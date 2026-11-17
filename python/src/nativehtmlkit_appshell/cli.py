"""Headless management CLI. No NativeHTMLKit host starts except for 'run'."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys

from . import __version__
from .scaffold import generate_python
from .storage import Store, StateError, json_load, json_save


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="appshell", description="NativeHTMLKit AppShell (Python)")
    parser.add_argument("--home", type=Path, default=None, help="Local AppShell home directory")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="Run the native AppShell desktop")
    run.add_argument("--safe-mode", action="store_true")
    sub.add_parser("list", help="Show installed extensions")
    sub.add_parser("doctor", help="Validate registry, pending changes and executable paths")
    sub.add_parser("restore", help="Restore last clean extension configuration")
    stage = sub.add_parser("stage", help="Queue package installation for next restart")
    stage.add_argument("action", choices=["add"])
    stage.add_argument("source", help="Local project/wheel, pinned PyPI spec, or pinned GitHub SHA")
    for name in ("disable", "enable", "remove"):
        p = sub.add_parser(name, help=f"Queue extension {name} for next restart")
        p.add_argument("id")
    gen = sub.add_parser("generate", help="Generate a complete extension project")
    gen.add_argument("language", choices=["python"])
    gen.add_argument("--id", required=True)
    gen.add_argument("--output", required=True, type=Path)
    gen.add_argument("--title", default=None)
    args = parser.parse_args(argv)
    store = Store(args.home)
    try:
        if args.command == "generate":
            print(generate_python(args.id, args.output, title=args.title))
            return 0
        store.prepare()
        if args.command == "run":
            from nativehtmlkit import Application
            from .desktop import Desktop
            from .runtime import AppShellRuntime
            with Application.start(name="NativeHTMLKit AppShell", app_id="org.nativehtmlkit.AppShell.Python") as app:
                desktop = Desktop(AppShellRuntime(store, safe_mode=args.safe_mode))
                try:
                    desktop.launch(app)
                    app.run()
                finally:
                    desktop.close()
            return 0
        if args.command == "list":
            for ident, record in sorted(store.registry().get("extensions", {}).items()):
                print(f"{ident}\t{record.get('version')}\t{'enabled' if record.get('enabled', True) else 'disabled'}")
            print(f"Pending operations: {len(store.pending()['operations'])}")
            return 0
        if args.command == "doctor":
            problems = []
            try:
                registry = store.registry()
                for ident, record in registry.get("extensions", {}).items():
                    release = store.resolve_owned(record["release"], store.releases)
                    if not release.exists():
                        problems.append(f"Missing release for {ident}: {release}")
                print(f"Active extension records: {len(registry.get('extensions', {}))}")
                print(f"Queued changes: {len(store.pending()['operations'])}")
                print(f"Failed candidates: {len(store.failed()['items'])}")
                print(f"Unclean session marker: {store.session_path.is_file()}")
            except StateError as exc:
                problems.append(str(exc))
            for problem in problems:
                print("ERROR: " + problem, file=sys.stderr)
            return 1 if problems else 0
        if args.command == "restore":
            if not store.last_good_path.is_file():
                raise StateError("No last-known-good snapshot available")
            if store.session_path.exists():
                raise StateError("Close AppShell before restoring its registry")
            snapshot = json_load(store.last_good_path, {"version": 1, "extensions": {}})
            backup = store.backup_registry()
            store.save_registry(snapshot)
            print(f"Restored last-known-good configuration; prior registry backup: {backup}; extension data unchanged")
            return 0
        if args.command == "stage":
            print("Queued:", store.stage(args.source), "(restart required)")
            return 0
        if args.command in ("disable", "enable", "remove"):
            print("Queued:", store.queue(args.command, id=args.id), "(restart required)")
            return 0
    except (StateError, ValueError, OSError) as exc:
        print(f"appshell: {exc}", file=sys.stderr)
        return 1
    return 2
