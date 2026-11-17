#!/usr/bin/env python3
"""Create a clean deterministic-ish source ZIP without development caches.

Usage: python scripts/package.py [output.zip]. This is packaging, not verification.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
from zipfile import ZipFile, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT.parent / 'NativeHTMLKit_AppShell_Implementation_v0.1.zip'
SKIP_DIRS = {'__pycache__','.pytest_cache','.venv','build','.git','.mypy_cache','.ruff_cache'}
SKIP_SUFFIXES = {'.pyc','.pyo','.log','.tmp','.bak'}


def included_files():
    for p in sorted(ROOT.rglob('*')):
        if not p.is_file():
            continue
        rel=p.relative_to(ROOT)
        if any(part in SKIP_DIRS or part.endswith('.egg-info') for part in rel.parts):
            continue
        if p.suffix in SKIP_SUFFIXES or p.name in {'.DS_Store'}:
            continue
        yield p


def main():
    out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else DEFAULT_OUTPUT.resolve()
    out.parent.mkdir(parents=True,exist_ok=True)
    entries=[]
    with ZipFile(out,'w',compression=ZIP_DEFLATED,compresslevel=9) as zipf:
        for p in included_files():
            if p.resolve()==out: continue
            path=p.relative_to(ROOT).as_posix()
            blob=p.read_bytes()
            zipf.writestr('nativehtmlkit-appshell/'+path,blob)
            entries.append({'path':path,'bytes':len(blob),'sha256':hashlib.sha256(blob).hexdigest()})
        manifest={'product':'NativeHTMLKit AppShell','version':'0.1.0','status':'source candidate, native qualification pending','file_count':len(entries),'files':entries}
        zipf.writestr('nativehtmlkit-appshell/RELEASE-FILE-MANIFEST.json',json.dumps(manifest,indent=2)+'\n')
    with ZipFile(out) as zipf:
        bad=zipf.testzip()
        if bad: raise RuntimeError(f'ZIP corruption: {bad}')
        names=zipf.namelist()
        assert len(names)==len(set(names)), 'duplicate entries'
    print(f'{out} ({out.stat().st_size:,} bytes, {len(entries)} files plus release manifest)')


if __name__=='__main__': main()
