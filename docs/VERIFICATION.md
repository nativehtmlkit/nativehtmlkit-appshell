# AppShell 0.1.0 — verification evidence

**Status (2026-11-17): 0.1.0, qualified on Linux KDE Plasma Wayland and Windows Server 2022 for both
editions; released as GitHub tag `v0.1.0`, PyPI `nativehtmlkit-appshell` and PowerShell Gallery
`NativeHTMLKit.AppShell`.** Everything below was executed; nothing is
claimed from source inspection. Raw logs, screenshots and accessibility-tree dumps are kept with the
project's private qualification records, not in this repository.

## Tested stack

| Component | Version |
|---|---|
| NativeHTMLKit Core host | 1.0.3 (protocol v1), as bundled in the SDK packages below |
| Python SDK / UI | `nativehtmlkit` 0.1.2, `nativehtmlkit-ui` 0.1.1 from PyPI |
| PowerShell SDK / UI | `NativeHTMLKit` 0.1.2, `NativeHTMLKit.UI` 0.1.1 from the PowerShell Gallery |
| Linux workstation | Debian 13, Python 3.13.5, uv 0.13.7, PowerShell 7.7.0, Pester 5.9.0 |
| Linux desktop VM | Ubuntu 26.04, KDE Plasma 6.6 native Wayland, Python 3.14.4, uv 0.13.8, PowerShell 7.7.0, Pester 5.9.0 |
| Windows VM | Windows Server 2022 (20348), Python 3.13.18 (uv-managed), uv 0.13.8, Windows PowerShell 5.1.20348.5773, PowerShell 7.7.0, Pester 5.7.1, PowerShellGet 1.0.0.1 (+ PSResourceGet 1.1.1 where stated) |

Source: the full matrix below ran on the release-candidate code. After the release packaging change
(Gallery `RequiredModules` for the SDK and UI, project URLs, registry READMEs, publish-only workflows)
the PowerShell suites (all machines, both editions on Windows), the Python suite (workstation), the
installed `uv tool install` wheel and all five real-input GUI runs were repeated: all passed.

## Results

| Suite | What it covers | Workstation | Linux VM | Windows VM |
|---|---|---|---|---|
| `python -m pytest python/tests` | contracts, render escaping, storage, real uv installs and workers (lifecycle, failure paths), real host in headless test mode (desktop scenario, 53 checks) | 46/46 | 46/46 | 46/46 |
| Pester, PowerShell 7.7 | module, contract fixtures, worker channel, lifecycle, local PSResource repository, real host headless (desktop scenario, 52 checks), Greeter example | 40/40 | 40/40 | 40/40 |
| Pester, Windows PowerShell 5.1 | same | n/a | n/a | 40/40 with PSResourceGet; 38 + 2 skipped (no PSResourceGet) on the stock install |
| Real-input GUI, Python | `qualification/gui/driver.py`, 26 checks | — | 26/26 (ydotool via KWin) | 26/26 (SendInput, RDP desktop) |
| Real-input GUI, PowerShell 7.7 | 26 checks | — | 26/26 | 26/26 |
| Real-input GUI, Windows PowerShell 5.1 | 26 checks | — | n/a | 26/26 |
| Built wheel in a fresh venv | headless desktop scenario + lifecycle from the installed wheel | 25/25 | — | — |
| Built module zip, extracted elsewhere | PowerShell suite against the extracted module | 38/38 | — | — |
| Real PowerShell Gallery download | pinned non-AppShell module (`NativeHTMLKit.Demo==0.1.0`): downloaded, rejected as "no AppShell manifest", existing extension stays active, no candidate left | — | — | PASS on 5.1 (`Save-Module`) and 7.7 (`Save-PSResource`) |

Commands: `cd python && python -m pytest -q tests`; `Invoke-Pester ./powershell/tests,
./examples/powershell/Greeter/tests` (Pester 5); GUI: `qualification/gui/run-linux.sh OUT PYTHON
[PSMODULES]` inside the KDE session, or `driver.py --edition py|ps7|ps51 --out OUT --home HOME`
inside an interactive Windows desktop; `python scripts/qualify.py`; `python scripts/build.py`.

### Real-input GUI checks (each edition, each desktop)

Window shown and boot; pointer navigation; typing; Tab order into the password field; checkbox
toggle; read command sends the typed values; write command opens the confirmation with Confirm
focused; Escape cancels and returns focus to the button; Enter confirms and the write runs once;
destructive command focuses Cancel and Enter keeps the data; pointer Confirm runs it; keyboard
sidebar navigation (Tab, Enter); Settings by pointer; 10 rapid navigations end on the last page;
worker crash during a write reports an unknown outcome, the notice is scrolled into view, the write
is not retried; accessibility tree: `Button "Save"`, `CheckBox "Agree"`, `PasswordInput "Secret"`,
`ComboBox "Level"`, `MultilineTextInput "Notes"`, named sidebar buttons, `Status` and `Alert`
regions; narrow window keeps content visible; closing the window exits with status 0, leaves no
worker process, records last-known-good and removes the session marker.

The probe only reads state (element rectangles, focus, values) and scrolls a target into view
before a pointer click; every click and key press is real OS input.

### Measurements

- Real desktops, process start to window visible: Python 0.3 s (Windows) / 0.9 s (KDE); Windows
  PowerShell 5.1 1.2 s; PowerShell 7.7 2.2 s (Windows) / 3.0 s (KDE), dominated by pwsh start-up.
  Extensions are activated in the background after the shell is shown (headless host: one extension
  active 0.33 s after start in Python, 0.9–1.2 s in PowerShell).
- PowerShell edition, one fresh process per request: 100 action + page-refresh cycles took
  70–79 s with the released manifest (about 0.35–0.4 s per request; each background runspace also
  loads the SDK and UI modules declared as `RequiredModules`). Python edition (persistent worker): 8.4 s.

## Defects found and fixed during qualification

Python edition: drop-ins built in place (wrote `build/`, `*.egg-info` into the user's folder and
re-installed on every boot); drop-in detection broken on Windows (`\` separator) so quarantine and
remove did nothing; removed drop-ins suppressed forever; duplicate pinned stage built and leaked a
release; extension `os.write(1)`/child processes could corrupt the worker protocol; unbounded worker
log; `stop()` during boot left workers running; `restore` refused forever after a crash and two
instances could share a home (now a session lock); last-known-good committed after a lost host;
desktop handlers raced between the SDK event thread and the UI owner; Escape left a pending command.

PowerShell edition: `$home` collided with `$HOME` (tests and the Add button); `File.Replace` with
`$null` broke every registry update; StrictMode 2 failed on optional fields; every desktop callback
used `.GetNewClosure()` and could not call module functions (clicks silently did nothing); heading
`level` rejected on PowerShell 7 (Int64); Write-Host/warnings counted as results and PSCustomObject
results rejected; protocol shared stdout with the extension; console code pages corrupted non-ASCII
on 5.1; unbounded output in memory; timeout killed only the top process; relative paths resolved
against the process directory; generated modules unreadable as UTF-8 on 5.1 and broken by a `'` in
the title; corrupt state aborted boot without recovery mode; `-Home`/`-SafeMode` lost when
`Start-AppShell` was typed at a prompt; more than 8 background requests exceeded the SDK task limit.

Both: unknown-outcome notice invisible on a scrolled page; window taller than a 768/800 px desktop;
checkbox styled as a text field. The build/test GitHub Actions workflow was removed (project policy:
Actions only publish already-built assets).

## Not verified / remaining limitations

- **Screen readers** (Orca, Narrator) were not run against AppShell. Only the accessibility tree that
  Core publishes to the native bridge was checked. Core B-0001 (Orca and collapsed selects) applies.
- IME, display scaling and multi-monitor were not exercised for AppShell (covered for the UI library).
- Python `git+https://github.com/…@<sha>` sources: validation tested, no real install (no published
  AppShell extension repository). `name==version` is tested through uv with a local index.
- PowerShell Gallery success path: verified against a local PSResource repository; the real Gallery
  was exercised only with a module that is not an AppShell extension (none is published).
- Windows PowerShell 5.1 without PSResourceGet uses PowerShellGet 1.0 `Save-Module`; it worked on
  the test VM because the NuGet provider was already present. Without it, `Save-Module` prompts and
  fails non-interactively: install PSResourceGet or the NuGet provider first.
- The Python sdist is not byte-reproducible; the wheel and the module zip are (`scripts/build.py`).
- Known Core issue found here: B-0030, `get_rect` of modal dialog content ignores the document
  scroll offset. AppShell does not use `get_rect`; only the GUI test driver works around it.
- Venvs and worker processes are not a sandbox: extensions run with the user's permissions.
