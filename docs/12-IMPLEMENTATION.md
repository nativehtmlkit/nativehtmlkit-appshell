# AppShell 0.1.0 implementation map

**Status: source candidate, not GA.** Supersedes a few design-only details in
`02-ARCHITECTURE.md` that were resolved during implementation. This document identifies what
is actually present in the repository. Do not mistake a completed implementation for native
qualification. No binaries were published.

## Source inventory and boundaries

### Python edition

| File | Responsibility |
|---|---|
| `python/src/nativehtmlkit_appshell/cli.py` | headless CLI, native window entry point and extension scaffold |
| `.../desktop.py` | fixed NativeHTMLKit UI and delegated SDK document event handlers |
| `.../render.py` | validated semantic views to escaped DOM markup, generated control IDs |
| `.../contract.py` | strict v1 validation and executable bounds |
| `.../storage.py` | XDG/local app home, registry, queue, snapshots, fingerprinting, file locks |
| `.../installer.py` | independent uv environments, metadata discovery and promote-on-success |
| `.../runtime.py` | per-start activation, recovery, errors, worker supervision |
| `.../worker_client.py` | cross-platform Python subprocess I/O, timeouts and outcome-unknown classification |
| `.../worker_main.py` | standalone stdlib entrypoint for installed extension venvs |
| `.../scaffold.py` | creates an independent PEP 621 Python package, example page/action and test |

Python intentionally starts one **long-lived isolated worker process per active extension**.
All extension code runs in that worker, not in the UI host process. The worker wrapper is pure
stdlib and runs in the extension's environment, so there is no AppShell SDK dependency. UI
work stays on the NativeHTMLKit owner thread through `UI.post()`.

### PowerShell edition

| File | Responsibility |
|---|---|
| `powershell/NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1` | PowerShell module distribution |
| `.../Private/Storage.ps1` | per-edition home, atomic registry files, source fingerprint, state locks and queue |
| `.../Private/Contract.ps1` | v1 semantic validation, safety caps and supported UI blocks |
| `.../Private/Install.ps1` | local/PSGallery sources, release promotion, boot activation, rollback |
| `.../Private/Worker.ps1` | .NET child PowerShell process framing/timeouts |
| `.../AppShell.Worker.ps1` | executable worker host, imports exactly one PowerShell module |
| `.../Private/Shell.ps1` | NativeHTMLKit.UI shell and public document event wiring |
| `.../AppShell.Host.ps1` | SDK-supported supervised backend script/entry point |
| `.../Private/Scaffold.ps1` | generates a real PowerShell `.psd1/.psm1` package and Pester test |

**One deliberate design deviation:** PowerShell uses a fresh same-language **process per
manifest/page/action request**, instead of one long-lived process per extension. This avoids
runspace poisoning, module reload and stdout protocol cross-talk in v0.1, and permits Windows
PowerShell 5.1 and PowerShell 7 to use the same public contract. Higher latency is expected.
If native performance measurements prove this unacceptable, a persistent same-language worker
may replace it without changing the public extension API. PowerShell handlers do not import
Python, uv or the native UI toolkit. External PowerShell module dependencies must be resolved
by the normal module installation environment; v0.1 does not implement a dependency solver.

## Package installers

Python supports local project folder, `.whl`, exact package `name==version` and GitHub SHA
source through uv. It promotes candidates after their worker reports a valid manifest. Direct
drop-ins under `extensions/` are scanned and copied to immutable releases; malformed sources
are quarantined by fingerprint. Source builds may execute code and require explicit trust.

PowerShell supports a directory with exactly one AppShell `.psd1`, exact PSGallery module name
and version, and direct module folder drops. Staged files live under `incoming/`. The worker
imports only the staged/promoted module. PSResourceGet or PowerShellGet runs **only at startup**
for queued gallery sources. Edition-specific module resolution and dependency behavior require
native qualification.

## Recovery guarantees and limits

- Persistent JSON registry: atomic replace and small filesystem lock. No database/service.
- Old executable releases remain on disk after updates; a failed candidate leaves its prior
  registry pointer intact. The registry is not a software sandbox.
- `last-good.json` is replaced only after a clean and healthy running session. On an unclean
  start the previous snapshot is restored. A changed direct-drop candidate is quarantined by
  its exact content fingerprint when the failed release can be identified.
- This recovery does not undo extension-private data, already executed commands or remote
  actions. A timeout after a write may have completed remotely and is never retried by AppShell.
- Registry corruption must leave the empty/recovery shell accessible. The implementation
  exposes safe-mode entry points and explicit restore; native recovery UX still needs tests.

## Fixed v1 scope

Manifest, pages, buttons, fields, read-only tables, action risk confirmations and navigation.
There is no service broker, no background jobs in AppShell, no plugin-supplied CSS/JS, no
network server and no shared runtime across Python/PowerShell.

## Packaging / docs

The generators create complete installable native-language projects with entrypoint/module
metadata, sample read/write actions, local data-directory usage and initial tests. Root
`examples/` contains checked-in sample projects, while `templates/README.md` explains how to
generate one. The shared contracts live in `contracts/` and `fixtures/`. The original review,
decisions and research are retained in docs 01–11.
