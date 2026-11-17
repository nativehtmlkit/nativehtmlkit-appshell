# Verification evidence and release gates

**Current status (2026-11-17):** every gate in the table below was run on KDE Plasma Wayland and
Windows Server 2022 for Python, PowerShell 7 and Windows PowerShell 5.1; results, versions and the
remaining limitations are in `VERIFICATION.md`. The sections "Verified here" and "Not verified here"
below describe the original authoring environment and are kept as history.

## Verified here (authoring environment)

- Python test suite (`python -m pytest -q`): includes JSON contract validation, render
  escaping, scaffolds, state/rollback and an independent uv environment with a real worker.
  Re-run after receiving the package, since versions and machine behavior can differ.
- Python generated example compiles. Core/SDK/UI archives and old Octopus were reviewed for
  public API and source compatibility, but NativeHTMLKit is **not installed** here.
- Offline JSON fixtures and package file inventories are part of `scripts/qualify.py`.

## Not verified here (must be run by local agent)

- PowerShell 7 and Windows PowerShell 5.1 parser / Pester / worker protocol execution.
- Python/PowerShell actual native windows on KDE Wayland / Windows Server 2022.
- Real package download from PSGallery/PyPI/Git SHA, module dependencies and credentials.
- Native focus, keyboard navigation, confirmation dialogs, form collection, DOM event
  delegation, rollback after crash and process cleanup on both OSs.
- UI component behavior against exact NativeHTMLKit Core / Python / PowerShell SDK and UI
  builds installed on target desktops.

## Required gates before publishing

| Gate | Python Linux / Windows | PS7 Linux / Windows | PS5.1 Windows |
|---|---|---|---|
| Import/install from native package | Required | Required | Required |
| Extension scaffold and test | Required | Required | Required |
| Empty shell and first boot | Required | Required | Required |
| Manual extension drop + restart | Required | Required | Required |
| Page, form inputs, save/read/refresh | Required | Required | Required |
| Table/notice/containers and hostile escaped text | Required | Required | Required |
| Write/destructive confirmation and cancel | Required | Required | Required |
| Failed worker, unknown outcome and recovery | Required | Required | Required |
| Stale page events and rapid navigation | Required | Required | Required |
| Corrupt registry and explicit restore | Required | Required | Required |
| Shutdown without orphan workers | Required | Required | Required |

### PowerShell worker protocol adversarial tests

Run handler emitting `Write-Host`, `Write-Warning`, `Write-Progress`, `Write-Verbose`, ordinary
objects, Unicode, and invalid output. A malformed stream must fail only the extension. The
worker must produce exactly one JSON response per call. If progress or native writes corrupt
stdout, do not conceal the failure: fix/redesign the private pipe mechanism, not the public
manifest/page/action contract. Test timeout and forced process termination independently.

### Release definition

Pass all gates, fix critical regressions, record hashes of wheel/module and tested builds,
produce evidence indexed in `docs/verification/`, then tag/publish only on explicit approval.
Do not use live Docker/Proxmox/OPNsense resources for UI smoke tests; mock or disposable targets.

## Agent handoff

Run the exact prompt in `agent/LOCAL-AGENT-PROMPT.md`. Preserve complete honest evidence. If a
native SDK or UI primitive is broken, reproduce it outside AppShell before proposing an
upstream change. AppShell must use *public SDK APIs* and no undocumented Core wire access.

## Recovery state backups

Restore commands and automatic crash recovery preserve the previous `registry.json` bytes
in `backups/` before replacing the active registry. That backup may contain malformed state;
keep it for diagnostics. Do not delete or mutate user extension data when restoring an
executable configuration. Test a corrupt JSON registry and manual restore separately.
