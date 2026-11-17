#!/usr/bin/env python3
"""Build the release-candidate artifacts into dist/ (packaging only, not verification).

    python scripts/build.py

- Python: sdist + wheel of python/ (uv build, isolated build environment)
- PowerShell: NativeHTMLKit.AppShell-<version>.zip with the module folder at the archive root
- SHA256SUMS over everything produced

Archive timestamps come from SOURCE_DATE_EPOCH (default: the HEAD commit time) so a rebuild of
the same commit gives the same module zip. Nothing is published.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"


def version() -> str:
    py = re.search(r'^version = "([^"]+)"', (ROOT / "python/pyproject.toml").read_text("utf-8"), re.M).group(1)
    psd1 = (ROOT / "powershell/NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1").read_text("utf-8-sig")
    ps = re.search(r"ModuleVersion\s*=\s*'([^']+)'", psd1).group(1)
    init = re.search(r'__version__ = "([^"]+)"',
                     (ROOT / "python/src/nativehtmlkit_appshell/__init__.py").read_text("utf-8")).group(1)
    psm1 = re.search(r"AppShellVersion = '([^']+)'",
                     (ROOT / "powershell/NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psm1").read_text("utf-8")).group(1)
    if len({py, ps, init, psm1}) != 1:
        raise SystemExit(f"version strings disagree: pyproject {py}, psd1 {ps}, __init__ {init}, psm1 {psm1}")
    return py


def epoch() -> int:
    if os.environ.get("SOURCE_DATE_EPOCH"):
        return int(os.environ["SOURCE_DATE_EPOCH"])
    out = subprocess.run(["git", "log", "-1", "--format=%ct"], cwd=ROOT, capture_output=True, text=True)
    return int(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else int(time.time())


def module_zip(ver: str, stamp: int) -> Path:
    source = ROOT / "powershell" / "NativeHTMLKit.AppShell"
    target = DIST / f"NativeHTMLKit.AppShell-{ver}.zip"
    date = time.gmtime(max(stamp, 315532800))[:6]
    with ZipFile(target, "w", ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(p for p in source.rglob("*") if p.is_file() and "__pycache__" not in p.parts):
            info = ZipInfo("NativeHTMLKit.AppShell/" + path.relative_to(source).as_posix(), date)
            info.external_attr = 0o644 << 16
            info.compress_type = ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())
        for extra in ("LICENSE",):
            info = ZipInfo("NativeHTMLKit.AppShell/" + extra, date)
            info.external_attr = 0o644 << 16
            info.compress_type = ZIP_DEFLATED
            archive.writestr(info, (ROOT / extra).read_bytes())
    return target


def main() -> int:
    ver = version()
    stamp = epoch()
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir()
    env = dict(os.environ, SOURCE_DATE_EPOCH=str(stamp))
    subprocess.run(["uv", "build", "--out-dir", str(DIST), str(ROOT / "python")], check=True, env=env)
    module_zip(ver, stamp)
    lines = []
    (DIST / ".gitignore").unlink(missing_ok=True)  # written by uv build; not an artifact
    for path in sorted(DIST.iterdir()):
        lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}")
    (DIST / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
