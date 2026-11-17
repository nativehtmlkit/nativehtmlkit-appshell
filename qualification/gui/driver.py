#!/usr/bin/env python3
"""AppShell real-input GUI driver (test tooling, stdlib only).

Runs INSIDE the interactive desktop session: KDE Plasma Wayland (ydotool/uinput through KWin) or a
Windows RDP/console desktop (SendInput). Starts the real AppShell desktop (probe_py.py or
probe_ps.ps1) with a showcase extension in a disposable home, drives it with REAL OS pointer and
keyboard input, reads state back through the probe's read-only file channel, and writes
results.json (PASS/FAIL per check), screenshots and logs to --out.

usage: driver.py --edition py|ps7|ps51 --out DIR --home DIR [--python EXE] [--pwsh EXE]

The LinuxDesktop/WindowsDesktop classes are copied from the NativeHTMLKit UI repository's
qualification/gui/driver.py (same project, MIT) so this repository has no test-time dependency
on another checkout.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WINDOWS = os.name == "nt"


# ------------------------------------------------------------------------------------- desktops
class LinuxDesktop:
    KEYS = {"Enter": 28, "Escape": 1, "Tab": 15, "Alt": 56, "F4": 62, "Left": 105, "Right": 106, "Down": 108,
            "Up": 103, "Home": 102, "End": 107, "Ctrl": 29, "A": 30, "Space": 57, "Shift": 42, "Backspace": 14}

    def __init__(self):
        self.lab = Path.home() / "lab/bin"
        subprocess.run([str(self.lab / "lab-input-init")], capture_output=True, timeout=20)

    def kwin(self, js: str, wait: float = 0.4) -> list[str]:
        tag = "NHKUI" + uuid.uuid4().hex[:8]
        path = Path(tempfile.gettempdir()) / f"kwin-{tag}.js"
        path.write_text(js.replace("OUT(", f"print('{tag} ' + "))
        since = time.strftime("%Y-%m-%d %H:%M:%S")
        number = subprocess.check_output(["qdbus6", "org.kde.KWin", "/Scripting",
                                          "org.kde.kwin.Scripting.loadScript", str(path), tag], text=True).strip()
        subprocess.run(["qdbus6", "org.kde.KWin", f"/Scripting/Script{number}", "org.kde.kwin.Script.run"],
                       capture_output=True, check=True)
        time.sleep(wait)
        subprocess.run(["qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", tag],
                       capture_output=True)
        path.unlink(missing_ok=True)
        out = subprocess.run(["journalctl", "--user", "-q", "--since", since, "-o", "cat", "--no-pager"],
                             capture_output=True, text=True).stdout
        return [line.split(tag + " ", 1)[1] for line in out.splitlines() if tag + " " in line]

    def windows(self) -> list[dict]:
        lines = self.kwin(r"""var ws = workspace.windowList(); var r = [];
for (var i = 0; i < ws.length; i++) { var w = ws[i]; if (!w.normalWindow && !w.dialog) continue;
 r.push({caption: w.caption, pid: w.pid, x: w.frameGeometry.x, y: w.frameGeometry.y, w: w.frameGeometry.width,
 h: w.frameGeometry.height, cx: w.clientGeometry.x, cy: w.clientGeometry.y, cw: w.clientGeometry.width,
 ch: w.clientGeometry.height, active: w.active}); }
OUT(JSON.stringify(r));""")
        return json.loads(lines[-1]) if lines else []

    def scale(self) -> float:
        lines = self.kwin("var o = workspace.screens; var r=[]; for (var i=0;i<o.length;i++) r.push(o[i].devicePixelRatio);"
                          " OUT(JSON.stringify(r));")
        try:
            return float(json.loads(lines[-1])[0])
        except (ValueError, IndexError):
            return 1.0

    def activate(self, title: str) -> None:
        self.kwin("var ws = workspace.windowList(); for (var i=0;i<ws.length;i++){ if (ws[i].caption.indexOf(%s)>=0)"
                  "{ workspace.activeWindow = ws[i]; OUT('ok'); break; } }" % json.dumps(title), wait=0.3)

    def place(self, title: str, x: int, y: int) -> None:
        self.kwin("var ws = workspace.windowList(); for (var i=0;i<ws.length;i++){ if (ws[i].caption.indexOf(%s)>=0)"
                  "{ var g = ws[i].frameGeometry; ws[i].frameGeometry = {x:%d, y:%d, width:g.width, height:g.height};"
                  " OUT('ok'); break; } }" % (json.dumps(title), x, y), wait=0.4)

    def click(self, x: float, y: float) -> None:
        subprocess.run([str(self.lab / "lab-click"), str(int(round(x))), str(int(round(y)))], check=True, timeout=20)
        time.sleep(0.35)

    def type(self, text: str, delay_ms: int = 40) -> None:
        subprocess.run(["ydotool", "type", "-d", str(delay_ms), "--", text], check=True, capture_output=True, timeout=60)
        time.sleep(0.4)

    def key(self, *names: str) -> None:
        codes = [self.KEYS[n] for n in names]
        subprocess.run(["ydotool", "key", *[f"{c}:1" for c in codes], *[f"{c}:0" for c in reversed(codes)]],
                       check=True, capture_output=True, timeout=20)
        time.sleep(0.25)

    def close(self, title: str) -> None:
        self.kwin("var ws = workspace.windowList(); for (var i=0;i<ws.length;i++){ if (ws[i].caption.indexOf(%s)>=0)"
                  "{ ws[i].closeWindow(); OUT('ok'); break; } }" % json.dumps(title), wait=0.3)

    # IME (fcitx5 must already be KWin's Wayland input method; the runner enables and restores it)
    IME = {"engine": "fcitx5 pinyin", "keys": "nihao", "commit_keys": ["Space"], "committed": "\u4f60\u597d"}

    def ime_available(self) -> bool:
        return subprocess.run(["fcitx5-remote"], capture_output=True).returncode == 0

    def ime_on(self) -> None:
        subprocess.run(["fcitx5-remote", "-o"], capture_output=True, timeout=10)
        time.sleep(0.4)

    def ime_off(self) -> None:
        subprocess.run(["fcitx5-remote", "-c"], capture_output=True, timeout=10)
        time.sleep(0.4)

    def type_composed(self, text: str) -> None:
        self.type(text, delay_ms=90)

    def screenshot(self, path: Path) -> bool:
        subprocess.run(["spectacle", "-b", "-n", "-f", "-o", str(path)], capture_output=True, timeout=30)
        return path.exists() and path.stat().st_size > 0

    def client_point(self, window: dict, x: float, y: float, scale: float) -> tuple[float, float]:
        return window["cx"] + x, window["cy"] + y  # KWin logical coordinates == CSS px

    def host_processes(self) -> list[str]:
        out = subprocess.run(["pgrep", "-af", "nativehtmlkit-host"], capture_output=True, text=True).stdout
        return [line for line in out.splitlines() if line.strip()]


class WindowsDesktop:
    VK = {"Enter": 0x0D, "Escape": 0x1B, "Tab": 0x09, "Alt": 0x12, "F4": 0x73, "Left": 0x25, "Right": 0x27,
          "Down": 0x28, "Up": 0x26, "Home": 0x24, "End": 0x23, "Ctrl": 0x11, "A": 0x41, "Space": 0x20,
          "Shift": 0x10, "Backspace": 0x08, "IME_ON": 0x16, "IME_OFF": 0x1A}
    EXTENDED = {0x25, 0x26, 0x27, 0x28, 0x24, 0x23}
    IME = {"engine": "Microsoft IME (Japanese)", "keys": "nihonn", "commit_keys": ["Space", "Enter"],
           "committed": "\u65e5\u672c"}

    def ime_available(self) -> bool:
        return True  # the runner adds ja-JP to this user's input languages (lab-ime.ps1)

    def _lang(self, klid: str) -> None:
        u, wt = self.user32, self.wt
        u.LoadKeyboardLayoutW.restype = wt.HKL
        u.LoadKeyboardLayoutW.argtypes = [wt.LPCWSTR, wt.UINT]
        hkl = u.LoadKeyboardLayoutW(klid, 0)
        u.GetForegroundWindow.restype = wt.HWND
        u.PostMessageW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, self.ctypes.c_void_p]
        u.PostMessageW(u.GetForegroundWindow(), 0x0050, 0, hkl)  # WM_INPUTLANGCHANGEREQUEST
        time.sleep(0.6)

    def ime_on(self) -> None:
        self._lang("00000411")
        self.key("IME_ON")
        time.sleep(0.5)

    def ime_off(self) -> None:
        self.key("IME_OFF")
        time.sleep(0.3)
        self._lang("00000409")

    def type_composed(self, text: str) -> None:
        """Real virtual keys for ASCII letters, so the IME composes them (KEYEVENTF_UNICODE bypasses it)."""
        for char in text:
            vk = ord(char.upper())
            self._send(self._key(vk=vk), self._key(vk=vk, flags=0x0002))
            time.sleep(0.09)
        time.sleep(0.5)

    def __init__(self):
        import ctypes
        from ctypes import wintypes
        self.ctypes, self.wt = ctypes, wintypes
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        try:
            self.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))  # per-monitor v2: physical pixels
        except AttributeError:
            pass
        u = self.user32
        u.GetWindowTextLengthW.argtypes = [wintypes.HWND]
        u.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
        u.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
        u.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
        u.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.POINT)]
        u.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        u.IsWindowVisible.argtypes = [wintypes.HWND]
        u.GetDpiForWindow.argtypes = [wintypes.HWND]
        u.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                   ctypes.c_int, wintypes.UINT]

        class MOUSEINPUT(ctypes.Structure):
            _fields_ = [("dx", ctypes.c_long), ("dy", ctypes.c_long), ("mouseData", wintypes.DWORD),
                        ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

        class KEYBDINPUT(ctypes.Structure):
            _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                        ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

        class UNION(ctypes.Union):
            _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]

        class INPUT(ctypes.Structure):
            _fields_ = [("type", wintypes.DWORD), ("u", UNION)]
        self.INPUT = INPUT
        u.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]

    def _send(self, *inputs) -> None:
        array = (self.INPUT * len(inputs))(*inputs)
        sent = self.user32.SendInput(len(inputs), array, self.ctypes.sizeof(self.INPUT))
        if sent != len(inputs):
            raise OSError(f"SendInput delivered {sent}/{len(inputs)} (error {self.ctypes.get_last_error()})")

    def _mouse(self, flags, x=0, y=0):
        item = self.INPUT(type=0)
        if flags & 0x8000:
            vx, vy = self.user32.GetSystemMetrics(76), self.user32.GetSystemMetrics(77)
            vw, vh = self.user32.GetSystemMetrics(78), self.user32.GetSystemMetrics(79)
            item.u.mi.dx = int(round((x - vx) * 65535 / max(vw - 1, 1)))
            item.u.mi.dy = int(round((y - vy) * 65535 / max(vh - 1, 1)))
            flags |= 0x4000
        item.u.mi.dwFlags = flags
        return item

    def click(self, x, y):
        self._send(self._mouse(0x0001 | 0x8000, x, y))
        time.sleep(0.05)
        self._send(self._mouse(0x0002), self._mouse(0x0004))
        time.sleep(0.35)

    def _key(self, vk=0, scan=0, flags=0):
        item = self.INPUT(type=1)
        item.u.ki.wVk, item.u.ki.wScan, item.u.ki.dwFlags = vk, scan, flags
        return item

    def type(self, text, delay_ms: int = 40):
        for char in text:
            code = ord(char)
            self._send(self._key(scan=code, flags=0x0004), self._key(scan=code, flags=0x0004 | 0x0002))
            time.sleep(delay_ms / 1000.0)
        time.sleep(0.4)

    def key(self, *names):
        codes = [self.VK[n] for n in names]
        ext = lambda c: 0x0001 if c in self.EXTENDED else 0  # noqa: E731
        self._send(*[self._key(vk=c, flags=ext(c)) for c in codes],
                   *[self._key(vk=c, flags=ext(c) | 0x0002) for c in reversed(codes)])
        time.sleep(0.25)

    def windows(self):
        ctypes, wt = self.ctypes, self.wt
        found = []

        @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
        def callback(hwnd, _):
            if not self.user32.IsWindowVisible(hwnd):
                return True
            length = self.user32.GetWindowTextLengthW(hwnd)
            title = ctypes.create_unicode_buffer(length + 1)
            self.user32.GetWindowTextW(hwnd, title, length + 1)
            rect, client, origin, pid = wt.RECT(), wt.RECT(), wt.POINT(0, 0), wt.DWORD()
            self.user32.GetWindowRect(hwnd, ctypes.byref(rect))
            self.user32.GetClientRect(hwnd, ctypes.byref(client))
            self.user32.ClientToScreen(hwnd, ctypes.byref(origin))
            self.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if title.value:
                found.append({"caption": title.value, "pid": pid.value, "hwnd": int(hwnd or 0),
                              "x": rect.left, "y": rect.top, "w": rect.right - rect.left, "h": rect.bottom - rect.top,
                              "cx": origin.x, "cy": origin.y, "cw": client.right, "ch": client.bottom,
                              "dpi": self.user32.GetDpiForWindow(hwnd)})
            return True
        self.user32.EnumWindows(callback, 0)
        return found

    def scale(self) -> float:
        return 1.0  # per window: see client_point

    def activate(self, title):
        window = next((w for w in self.windows() if title in w["caption"]), None)
        if window:  # a real click on the caption (SetForegroundWindow is refused for background processes)
            self.click(window["x"] + window["w"] // 2, window["y"] + max(8, (window["cy"] - window["y"]) // 2))

    def place(self, title, x, y):
        window = next((w for w in self.windows() if title in w["caption"]), None)
        if window:
            self.user32.SetWindowPos(window["hwnd"], None, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010)
            time.sleep(0.4)

    def close(self, title):
        self.activate(title)
        time.sleep(0.3)
        self.key("Alt", "F4")

    def screenshot(self, path: Path) -> bool:
        script = ("Add-Type -Namespace NhkUi -Name Dpi -MemberDefinition '[DllImport(\"user32.dll\")] public static extern bool "
                  "SetProcessDPIAware();'; [void][NhkUi.Dpi]::SetProcessDPIAware(); "
                  "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; "
                  "$b=[System.Windows.Forms.SystemInformation]::VirtualScreen; "
                  "$i=New-Object System.Drawing.Bitmap $b.Width,$b.Height; $g=[System.Drawing.Graphics]::FromImage($i); "
                  "$g.CopyFromScreen($b.Left,$b.Top,0,0,$i.Size); $i.Save('%s'); $g.Dispose(); $i.Dispose()") % str(path)
        subprocess.run(["powershell", "-NoProfile", "-Command", script], capture_output=True, timeout=60)
        return path.exists() and path.stat().st_size > 0

    def client_point(self, window, x, y, scale):
        factor = (window.get("dpi") or 96) / 96.0
        return window["cx"] + x * factor, window["cy"] + y * factor

    def host_processes(self) -> list[str]:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq nativehtmlkit-host.exe", "/FO", "CSV", "/NH"],
                             capture_output=True, text=True).stdout
        return [line for line in out.splitlines() if "nativehtmlkit-host" in line]


# ------------------------------------------------------------------------------------- harness
TITLE = "NativeHTMLKit AppShell"
DIALOG_IDS = {"as-confirm-ok", "as-confirm-cancel", "as-yes", "as-no"}


class Probe:
    """Read-only state channel of probe_py.py / probe_ps.ps1."""
    def __init__(self, channel: Path, proc: subprocess.Popen):
        self.channel, self.proc, self.seq = channel, proc, 0

    def ask(self, cmd: str, timeout: float = 20, **kw):
        req = self.channel / f"req-{self.seq}.json"
        tmp = self.channel / f"req-{self.seq}.tmp"
        tmp.write_text(json.dumps({"cmd": cmd, **kw}), encoding="utf-8")
        tmp.replace(req)
        resp = self.channel / f"resp-{self.seq}.json"
        end = time.monotonic() + timeout
        while not resp.exists():
            if self.proc.poll() is not None:
                raise RuntimeError(f"AppShell exited ({self.proc.returncode}) while probing {cmd}")
            if time.monotonic() > end:
                raise TimeoutError(f"probe did not answer {cmd}")
            time.sleep(0.03)
        self.seq += 1
        box = json.loads(resp.read_text("utf-8-sig"))
        if "error" in box:
            raise RuntimeError(f"probe {cmd}: {box['error']}")
        return box.get("result")


class Scenario:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.out).resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.home = Path(args.home).resolve()
        self.results: list[dict] = []
        self.desktop = WindowsDesktop() if WINDOWS else LinuxDesktop()
        self.data = self.home / "extension-data" / "org.example.showcase"
        self.shots = 0

    # -- bookkeeping
    def check(self, name: str, ok, detail="") -> bool:
        self.results.append({"name": name, "status": "PASS" if ok else "FAIL", "detail": str(detail)[:800]})
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  [{str(detail)[:300]}]"), flush=True)
        return bool(ok)

    def shot(self, label: str) -> None:
        self.shots += 1
        path = self.out / f"{self.shots:02d}-{label}.png"
        self.desktop.screenshot(path)

    def wait(self, predicate, timeout: float = 20, what: str = "condition"):
        end = time.monotonic() + timeout
        last = None
        while time.monotonic() < end:
            last = predicate()
            if last:
                return last
            time.sleep(0.1)
        raise TimeoutError(f"timed out waiting for {what}")

    def state(self) -> dict:
        return self.probe.ask("state")

    # -- geometry and input
    def window(self) -> dict:
        ours = [w for w in self.desktop.windows() if w["caption"] == TITLE]
        if not ours:
            raise RuntimeError("AppShell window not found")
        return ours[-1]

    def point(self, element: str) -> tuple[float, float]:
        rect = self.probe.ask("rect", id=element, reveal=element not in DIALOG_IDS)
        if element in DIALOG_IDS:
            # Core B-0030: get_rect of modal dialog content subtracts the document scroll offset.
            rect["y"] += rect.get("scroll_y") or 0
        time.sleep(0.15)
        return self.desktop.client_point(self.window(), rect["x"] + rect["width"] / 2,
                                         rect["y"] + rect["height"] / 2, 1.0)

    def click(self, element: str) -> None:
        x, y = self.point(element)
        with open(self.out / "clicks.log", "a", encoding="utf-8") as log:
            log.write(f"{element} -> ({x:.0f}, {y:.0f}) window={self.window()}\n")
        self.desktop.click(x, y)

    def resize(self, width: int, height: int) -> None:
        if WINDOWS:
            w = self.window()
            self.desktop.user32.SetWindowPos(w["hwnd"], None, 0, 0, width, height, 0x0002 | 0x0004 | 0x0010)
            time.sleep(0.6)
        else:
            self.desktop.kwin("var ws = workspace.windowList(); for (var i=0;i<ws.length;i++){ if (ws[i].caption == %s)"
                              "{ var g = ws[i].frameGeometry; ws[i].frameGeometry = {x:g.x, y:g.y, width:%d, height:%d};"
                              " OUT('ok'); break; } }" % (json.dumps(TITLE), width, height), wait=0.6)

    # -- launch
    def launch(self) -> None:
        foreign = [w for w in self.desktop.windows() if "NativeHTMLKit" in w["caption"]]
        if foreign:
            raise RuntimeError(f"foreign NativeHTMLKit windows on this desktop: {foreign}")
        channel = Path(tempfile.mkdtemp(prefix="appshell-probe-"))
        env = dict(os.environ, APPSHELL_HOME=str(self.home))
        env.pop("NATIVEHTMLKIT_TEST_MODE", None)
        if self.args.edition == "py":
            cmd = [self.args.python or sys.executable, str(HERE / "probe_py.py"), str(channel)]
        else:
            exe = self.args.pwsh or ("powershell.exe" if self.args.edition == "ps51" else "pwsh")
            cmd = [exe, "-NoLogo", "-NoProfile", "-File", str(HERE / "probe_ps.ps1"), str(channel), str(self.home)]
        log = open(self.out / "appshell.log", "wb")
        self.proc = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, cwd=str(self.out))
        self.probe = Probe(channel, self.proc)
        self.started = time.monotonic()
        self.wait(lambda: (channel / "ready").exists(), 60, "probe ready")
        self.wait(lambda: any(w["caption"] == TITLE for w in self.desktop.windows()), 60, "AppShell window")
        self.window_shown_s = round(time.monotonic() - self.started, 2)
        self.desktop.place(TITLE, 0, 0)
        self.desktop.activate(TITLE)

    def run(self) -> int:
        try:
            self.launch()
            self.scenario()
        except Exception as exc:
            import traceback
            self.check("driver exception", False, "".join(traceback.format_exception(exc))[-1500:])
            self.shot("exception")
            if getattr(self, "proc", None) and self.proc.poll() is None:
                self.proc.kill()
        failed = [r for r in self.results if r["status"] != "PASS"]
        (self.out / "results.json").write_text(json.dumps(
            {"edition": self.args.edition, "platform": sys.platform, "checks": self.results,
             "passed": len(self.results) - len(failed), "failed": len(failed)}, indent=1), encoding="utf-8")
        print(f"RESULT edition={self.args.edition} passed={len(self.results) - len(failed)} failed={len(failed)}")
        return 1 if failed else 0

    # -- the real-input scenario
    def scenario(self) -> None:
        s = self.wait(lambda: (lambda x: x if x["booted"] else None)(self.state()), 120, "boot")
        self.check("window shown and extensions booted", s["status"].startswith("1 extensions active"),
                   f"window after {self.window_shown_s}s; status {s['status']!r}")
        self.shot("home")
        nav = {tuple(v)[1]: k for k, v in s["nav"].items()}
        self.click(nav["controls"])
        s = self.wait(lambda: (lambda x: x if x["page_ready"] and x["selected"] and x["selected"][1] == "controls" else None)(self.state()),
                      30, "controls page")
        self.check("pointer click on sidebar page opens it", s["title"] == "Controls", s["title"])
        self.shot("controls")
        f, b = s["fields"], s["buttons"]
        self.click(f["title"])
        self.desktop.key("Ctrl", "A")
        self.desktop.type("GUI typed 42")
        self.check("typing replaces the input value", self.probe.ask("value", id=f["title"]) == "GUI typed 42",
                   self.probe.ask("value", id=f["title"]))
        self.desktop.key("Tab")
        focused = self.state()["focused"]
        self.check("Tab moves focus to the next field (password)", focused == f["secret"], focused)
        self.desktop.type("s3cret")
        self.check("password field receives typed text", self.probe.ask("value", id=f["secret"]) == "s3cret")
        self.click(f["agree"])
        self.check("pointer click toggles the checkbox", self.probe.ask("checked", id=f["agree"]) is False)
        self.click(b["echo"])
        s = self.wait(lambda: (lambda x: x if x["status"].startswith("echo") else None)(self.state()), 30, "echo")
        self.check("read button sends the typed values",
                   "GUI typed 42" in s["status"] and "agree=False" in s["status"] and "s3cret" in s["status"], s["status"])
        self.click(b["save"])
        s = self.wait(lambda: (lambda x: x if x["dialog_open"] else None)(self.state()), 10, "confirm dialog")
        self.check("write button opens the confirmation dialog with Confirm focused",
                   s["focused"] in ("as-confirm-ok", "as-yes"), s["focused"])
        self.shot("confirm-dialog")
        self.desktop.key("Escape")
        s = self.wait(lambda: (lambda x: x if not x["dialog_open"] and x["status"] == "Cancelled" else None)(self.state()),
                      10, "escape")
        self.check("Escape cancels; nothing written; focus back on Save",
                   not (self.data / "saved.txt").exists() and not s["pending"] and s["focused"] == b["save"], s)
        self.click(b["save"])
        self.wait(lambda: self.state()["dialog_open"], 10, "dialog again")
        self.desktop.key("Enter")
        self.wait(lambda: (self.data / "saved.txt").exists(), 30, "save written")
        s = self.wait(lambda: (lambda x: x if x["page_ready"] and not x["busy"] else None)(self.state()), 30, "refresh")
        self.check("Enter on Confirm runs the write once and refreshes",
                   (self.data / "saved.txt").read_text("utf-8") == "GUI typed 42"
                   and "Saved: GUI typed 42" in self.probe.ask("text", id=s["outlet"]))
        b = s["buttons"]
        self.click(b["wipe"])
        s = self.wait(lambda: (lambda x: x if x["dialog_open"] else None)(self.state()), 10, "wipe dialog")
        self.check("destructive dialog focuses Cancel", s["focused"] in ("as-confirm-cancel", "as-no"), s["focused"])
        self.desktop.key("Enter")
        self.wait(lambda: not self.state()["dialog_open"], 10, "cancelled")
        self.check("Enter on the default Cancel keeps the data", (self.data / "saved.txt").exists())
        self.click(b["wipe"])
        self.wait(lambda: self.state()["dialog_open"], 10, "wipe dialog again")
        self.click("as-confirm-ok" if self.args.edition == "py" else "as-yes")
        self.wait(lambda: not (self.data / "saved.txt").exists(), 30, "wipe")
        self.check("pointer Confirm runs the destructive command", True)
        home = self.probe.ask("sidebar_button", label="Home")
        self.click(home)
        self.desktop.key("Tab")
        self.desktop.key("Enter")
        s = self.wait(lambda: (lambda x: x if x["title"] == "Extensions" else None)(self.state()), 10, "keyboard nav")
        self.check("keyboard: Tab from Home then Enter opens Extensions", True)
        self.shot("extensions")
        self.click(self.probe.ask("sidebar_button", label="Settings"))
        self.check("pointer opens Settings", self.wait(lambda: self.state()["title"] == "Settings", 10, "settings"))
        s = self.state()
        nav = {tuple(v)[1]: k for k, v in s["nav"].items()}
        for i in range(10):
            self.click(nav["second" if i % 2 == 0 else "controls"])
        s = self.wait(lambda: (lambda x: x if x["page_ready"] and x["selected"] and x["selected"][1] == "controls" else None)(self.state()),
                      60, "rapid navigation")
        self.check("10 rapid pointer navigations end on the last page clicked", s["title"] == "Controls", s["title"])
        self.click(s["buttons"]["crash_write"])
        self.wait(lambda: self.state()["dialog_open"], 10, "crash dialog")
        self.desktop.key("Enter")
        s = self.wait(lambda: (lambda x: x if "Outcome unknown" in x["status"] else None)(self.state()), 30, "unknown")
        self.check("worker crash during a write reports an unknown outcome",
                   "do not retry" in self.probe.ask("text", id=s["outlet"]), s["status"])
        alert = (self.probe.ask("query", selector="[role=alert]")["ids"] or [None])[0]
        rect = self.probe.ask("rect", id=alert) if alert else None
        self.check("the unknown-outcome notice is scrolled into the visible window",
                   rect is not None and 0 <= rect["y"] < self.window()["ch"], rect)
        self.shot("unknown-outcome")
        (self.data / "crash-write.txt").unlink()
        time.sleep(2)
        self.check("the crashed write is not retried", not (self.data / "crash-write.txt").exists())
        tree = self.probe.ask("a11y")
        (self.out / "accessibility-tree.json").write_text(json.dumps(tree, indent=1), encoding="utf-8")
        nodes = {(n.get("role"), n.get("name")) for n in tree["tree"]["nodes"]}
        roles = {n.get("role") for n in tree["tree"]["nodes"]}
        names = {name for _, name in nodes}
        expected = {("Button", "Save"), ("CheckBox", "Agree"), ("PasswordInput", "Secret"),
                    ("ComboBox", "Level"), ("MultilineTextInput", "Notes")}
        self.check("accessibility: controls exposed with native roles and their label names",
                   expected <= nodes, sorted(expected - nodes))
        self.check("accessibility: status live region and failure alert exposed", {"Status", "Alert"} <= roles,
                   sorted(r for r in roles if r))
        self.check("accessibility: sidebar buttons named", {"Home", "Extensions", "Settings"} <= names)
        self.resize(690, 600)
        time.sleep(0.8)
        sidebar = self.probe.ask("rect", id=self.probe.ask("query", selector=".as-sidebar")["ids"][0]) \
            if self.probe.ask("query", selector=".as-sidebar")["ids"] else None
        content = self.probe.ask("rect", id=s["outlet"])
        self.shot("narrow-window")
        self.check("narrow window: compact sidebar, content still visible",
                   content["width"] > 200 and (sidebar is None or sidebar["width"] <= 160), (sidebar, content))
        self.resize(1110, 780)
        last = self.state()
        self.desktop.close(TITLE)
        code = self.proc.wait(timeout=60)
        self.check("closing the window exits AppShell with status 0", code == 0, code)
        time.sleep(1)
        leftovers = [p for p in last.get("workers", []) if _alive(p)]
        self.check("no extension worker left running", not leftovers, leftovers)
        good = json.loads((self.home / "last-good.json").read_text("utf-8")) if (self.home / "last-good.json").exists() else {}
        self.check("clean close records last-known-good and removes the session marker",
                   "org.example.showcase" in good.get("extensions", {}) and not (self.home / "running.json").exists())


def _alive(pid: int) -> bool:
    if WINDOWS:
        out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True).stdout
        return str(pid) in out
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--edition", choices=["py", "ps7", "ps51"], required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--home", required=True, help="disposable AppShell home with the showcase staged")
    parser.add_argument("--python")
    parser.add_argument("--pwsh")
    return Scenario(parser.parse_args()).run()


if __name__ == "__main__":
    raise SystemExit(main())
