#!/bin/bash
# Real-input GUI qualification on the KDE Plasma Wayland desktop (run on the VM as the session user).
# usage: run-linux.sh OUT_DIR PYTHON [PSMODULES]
set -u
here=$(cd "$(dirname "$0")" && pwd)
out=$1; py=$2; psmods=${3:-}
mkdir -p "$out"
. ~/lab/bin/gui-env
export QT_QPA_PLATFORM=wayland; unset DISPLAY
[ -n "$psmods" ] && export PSModulePath="$psmods:${PSModulePath:-}"
exec 9>/tmp/nhk-gui-desktop.lock
flock -w 1800 9 || { echo "desktop lock busy" >&2; exit 3; }
status=0
"$py" "$here/prepare_home.py" py "$out/home-py" >/dev/null
"$py" "$here/driver.py" --edition py --out "$out/py" --home "$out/home-py" --python "$py" || status=1
"$py" "$here/prepare_home.py" ps "$out/home-ps7" >/dev/null
pwsh -NoProfile -Command "Import-Module '$here/../../powershell/NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1'; Add-AppShellExtension -SourcePath '$here/../../powershell/tests/Showcase' -Home '$out/home-ps7'" >/dev/null
"$py" "$here/driver.py" --edition ps7 --out "$out/ps7" --home "$out/home-ps7" --pwsh pwsh || status=1
exit $status
