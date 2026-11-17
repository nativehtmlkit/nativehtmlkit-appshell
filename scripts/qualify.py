#!/usr/bin/env python3
"""Offline, stdlib-only repository smoke and file-inventory validator.

Does not require NativeHTMLKit, uv or PowerShell. Does not claim native QA.
"""
from __future__ import annotations

import ast
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    'README.md', 'LICENSE', 'AGENTS.md', 'CLAUDE.md',
    'contracts/manifest.schema.json', 'contracts/view.schema.json',
    'python/pyproject.toml', 'python/src/nativehtmlkit_appshell/cli.py',
    'python/src/nativehtmlkit_appshell/worker_main.py',
    'python/src/nativehtmlkit_appshell/resources/appshell.css',
    'powershell/NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1',
    'powershell/NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psm1',
    'powershell/NativeHTMLKit.AppShell/AppShell.Worker.ps1',
    'powershell/NativeHTMLKit.AppShell/AppShell.Host.ps1',
    'examples/python/Greeter/pyproject.toml',
    'examples/powershell/Greeter/AppShell.Greeter.psd1',
    'templates/README.md',
    'docs/12-IMPLEMENTATION.md', 'docs/VERIFICATION.md',
    'python/tests/test_lifecycle.py', 'python/tests/test_desktop_headless.py',
    'powershell/tests/Lifecycle.Tests.ps1', 'powershell/tests/Desktop.Tests.ps1',
    'qualification/gui/driver.py', 'scripts/build.py',
]


def main() -> int:
    missing = [name for name in REQUIRED if not (ROOT / name).is_file()]
    if missing:
        for name in missing:
            print('MISSING:', name, file=sys.stderr)
        return 1
    for file in sorted(ROOT.rglob('*.py')):
        if any(part in {'.venv','__pycache__','dist'} for part in file.parts):
            continue
        ast.parse(file.read_text(encoding='utf-8'), filename=str(file))
    for file in sorted(ROOT.rglob('*.json')):
        json.loads(file.read_text(encoding='utf-8'))
    for name in ['manifest.schema.json','view.schema.json']:
        schema=json.loads((ROOT/'contracts'/name).read_text(encoding='utf-8'))
        assert schema.get('type')=='object' and '$schema' in schema, name
    ps_files=sorted(p for d in ('powershell','examples','qualification') for p in (ROOT/d).rglob('*.ps*1')
                    if p.suffix in ('.ps1','.psm1','.psd1'))
    for file in ps_files:
        code=file.read_text(encoding='utf-8')
        if 'param([string]$Home' in code or 'param([switch]$SafeMode,[string]$Home' in code:
            raise AssertionError(f'PowerShell $HOME automatic-variable collision: {file}')
    parsed = 'PowerShell parser not checked (pwsh not found)'
    if shutil.which('pwsh'):
        script = ('$bad=0; foreach ($f in $input) { $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$null,[ref]$e); '
                  'foreach ($x in $e) { $bad++; [Console]::Error.WriteLine($f + ": " + $x.ToString()) } }; exit $bad')
        result = subprocess.run(['pwsh', '-NoProfile', '-NonInteractive', '-Command', script],
                                input='\n'.join(str(f) for f in ps_files), text=True)
        if result.returncode:
            print('FAIL: PowerShell parse errors', file=sys.stderr)
            return 1
        parsed = f'{len(ps_files)} PowerShell files parsed'
    print(f'PASS: {len(REQUIRED)} required files, Python AST, JSON, {parsed}')
    print('Not checked here: test suites, native host, real GUI (see docs/VERIFICATION.md)')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
