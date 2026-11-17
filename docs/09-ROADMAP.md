# Roadmap and minimal release scope

The release sequence is organized by **vertical slices**. Each milestone must leave a working native app, rather than creating a large shared abstraction first.

## Milestone 0 — proof of feasibility (P0 blocking)

1. Create the two independent empty AppShell applications, using the shipped SDK/UI versions, no upstream source changes.
2. Fixed sidebar + dynamic content outlet through public SDK in Python and in PowerShell.
3. Confirm that AppShell backend startup runs once after SDK handshake, not in launcher re-exec preamble.
4. Prototype PS JSON framing in pwsh 7 Linux, pwsh 7 Windows and powershell.exe 5.1 Windows; no stdout contamination.
5. Validate all schemas/fixtures with a tiny independent checker in each language.

Exit: open two native windows separately, replace/refresh page, dispatch one click, confirm native form values, and no Python ever launched from PS (or PowerShell from Python).

## Milestone 1 — functioning plugin host

1. Add Python entry-point worker + private venv via uv; add PS module worker + explicit manifest import, including pinned native package-name sources applied at restart.
2. Add registry, source drop-in scan, manual local add, deterministic nav, per-extension logs.
3. Add standard semantic blocks, forms, read/write/destructive commands and confirmation.
4. Add one hello/sample package in each language (no domain logic) with unit and native UI tests.
5. Add pending restart indicator, proper exit/shutdown and `doctor`/diagnostics.

Exit: both editions load and render one native extension from its own language; form action dispatches correctly; hostile malformed fixture affects only one extension.

## Milestone 2 — recovery and release qualification

1. Immutable versioned staging, previous-release retention, last-good file, per-extension fallback, safe mode.
2. Native file/folder Add, enable/disable/uninstall, explicit Delete Data and log view.
3. Tests for startup exceptions, malformed worker framing, timed-out writes, interrupted installs and UI close during operation.
4. Native KDE Wayland + Windows Server 2022 input/focus/scale tests; PS 5.1 validation.
5. Publish from clean build with no python dependency on PS artifacts and no powershell dependency on Python artifacts.

Exit: 2+ plugins in each edition, bad update and process crash recover, manual drop works, unqualified UI/platform caveats documented.

## Milestone 3 — actual useful extensions

- **Python edition** first examples: Docker Manager and Proxmox Manager as independent packages (not AppShell built-ins). Consider OPNsense host assignment manager after the schema holds up.
- **PowerShell edition** first example: Windows Service/Process Manager. Later AD or CyberArk module wrappers can independently expose read-only pages and safe actions.
- Only after two real extensions demonstrate a concrete need, consider a versioned **same-language** service-call broker (not an event bus). Use the old Octopus capability broker as a reference for deadlines, identity and call cycles; do not import it blindly.

## Explicitly postponed

Cloud marketplace, arbitrary frontend adapters, background schedulers, live plugin reload, remote AppShell server, hard sandboxing, multi-user roles, advanced file sync, cross-language workers and cross-app sessions.

## Definition of v0.1 done

- Two independent published/installable packages or modules in their native ecosystems.
- Works offline from a fresh local install with zero extensions.
- User can install/drop, restart, use, disable/rollback and remove a native plugin.
- Both editions conform to shared v1 JSON fixtures, in their own language.
- Native UI and fault-injection gates pass on all claimed platforms.
- No changes to NativeHTMLKit Core/SDK/UI required unless an evidenced upstream blocker is fixed as a separate PR.
- No severe known issues hidden under the label "stable"; publish limitations and support matrix.
