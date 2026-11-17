# Acceptance, contract conformance and negative tests

**No test results are claimed by this design package.** The tests below are requirements for the first release, using dedicated disposable test roots and domains.

## Mandatory headless contract tests — run independently per language

1. Empty app with zero plugins boots, shows Home/Extensions/Settings, exits cleanly without orphan processes.
2. Normal native package installs; entry point/module is discovered by metadata; valid manifest and one page render. No dependency on other language.
3. Install from local source and by manual copy. Updates take effect **only on next startup**.
4. Duplicate extension ID in two packages, duplicate page/command ids, mismatched native package/manifest identity, wrong `api_version` fail that plugin only.
5. All valid JSON fixtures pass in both editions; each invalid fixture fails with the expected error category.
6. All supported semantic block kinds render with escaped text and allowed controls; unknown/oversize/deep/nested payloads rejected.
7. Button requests send exactly current page form values, declared command ID and params. Unregistered button and stale page event don't execute anything.
8. Confirmation for `write` and `destructive`, including Cancel path, and no silent retry after timeout/worker loss.
9. Two plugins load, one throws during manifest/page/action, and the other remains available.
10. Worker exits or sends malformed frame; AppShell stays open; log path and failure details shown.
11. Failed candidate startup restores last working binary version; never deletes the extension data dir. Interrupted stage leaves active version unchanged.
12. Corrupt registry triggers safe-mode recovery with backup; never silently resets.
13. Disable/uninstall/add-update states remain pending until restart. Uninstall preserves plugin-owned data by default.
14. A manual drop-in edited while app is running cannot mutate the active immutable worker copy.
15. Closing window while a worker is busy returns within bounded shutdown budget; no orphan process.
16. Bad or malicious path inputs (`../`, symlink escape, Windows reparse points, case collision) cannot write outside managed directories.
17. A source install that runs build hooks is explicitly acknowledged as trusted; no remote network I/O during normal empty shell startup.
18. Native OS-specific error messages are classified and logged without leaking password field values.

## Native GUI qualification (actual desktops, no screenshots as substitute for interaction)

| Gate | Linux KDE Plasma Wayland | Windows Server 2022 | Note |
|---|---|---|---|
| Python AppShell sidebar and dynamic content | Required | Required | Native pointer/keyboard |
| PowerShell 7 AppShell sidebar and dynamic content | Required | Required | Owner-runspace event pump |
| Windows PowerShell 5.1 AppShell | N/A | Required | No Python, pwsh or uv dependency |
| Forms, tab order, Enter/Space/confirm | Required | Required | Real input |
| Refresh 100x, navigate 100x, close/reopen | Required | Required | No stale event/DOM state |
| Crash worker, kill worker during write | Required | Required | Shell still functional, outcome unknown |
| Broken plugin rollback on restart | Required | Required | Visual and disk evidence |
| Theme/density, accessibility | Required | Required | Honest outstanding bugs |

## Dedicated PowerShell transport prototype (P0)

Before implementation proceeds beyond skeleton:

- Run one worker under Windows PowerShell 5.1, PowerShell 7 Windows and PowerShell 7 Linux.
- Script handler emits combinations of returned objects, `Write-Host`, `Write-Output`, `Write-Progress`, `Write-Warning`, `Write-Verbose`, `Write-Error`, native command stdout/stderr, embedded newlines and non-ASCII text.
- Only wrapper-generated JSONL frames appear on protocol stdout; all incidental output appears in bounded log/stderr or is suppressed by documented rules.
- Errors are caught as structured frames; process crash/timeout/kill does not hang owner UI runspace.
- Arrays remain arrays, null stays null, booleans stay boolean, and UTF-8 is consistent with Python fixtures. Compare serialized logical objects against same contract.

If this cannot be achieved with stdio alone, switch to **same-machine named-pipe or a dedicated inherited pipe** for PowerShell; do not add an HTTP server and do not route via Python.

## Qualification discipline

- Native test machines: Linux development KDE Wayland session, Windows dev VM on Proxmox; disposable user-profile roots, no live Docker/Proxmox resources touched in release tests.
- Run Python and PowerShell tests **separately** in CI; Python runner never required for PS test environment, and PowerShell runner never required for Python runtime.
- Record exact SDK/UI/Core versions and hashes, packaged artifacts, UI screenshots or logs, and test outcomes. Do not declare GA based on headless tests alone.
- Test in OS administrator/nonadministrator contexts, but never require elevation for normal AppShell startup.
- Include user-visible troubleshooting commands (`appshell doctor` / `Test-AppShell` or equivalent), export sanitized support bundle, and a safe-mode boot option.
