# Critical architecture review

## Evidence baseline

Reviewed the six attached NativeHTMLKit archives, each at the snapshot they contain, plus an older private prototype ("Octopus") design and implementation and official ecosystem documentation. Findings below distinguish *verified repository facts* from *design proposals*. We have not run the six projects' native test suites in this specification-only review.

### Verified in attached sources

- Core README: shipped Core **1.0.3**, wire protocol v1, Linux KDE Wayland and Windows; only one authenticated backend per native app (`core/docs/ARCHITECTURE.md`).
- Python SDK **0.1.2**: `Application.start()` may re-execute its launcher; `Application.open_html`; `Document.replace_html`, `batch`, `on`, `form_data`, safe text operations. Use `nativehtmlkit run module:func` for startup with no accidental import side effects.
- PowerShell SDK **0.1.2**: `Start-NativeHTMLKitScript`, `Wait-NativeHTMLKit`, `Set-NativeHTMLKitDocumentHtml`, `Register-NativeHTMLKitDocumentEvent`, `Get-NativeHTMLKitFormData`, `Invoke-NativeHTMLKitBatch`. UI callbacks occur on owner runspace while SDK pumps events; long operations must be off that runspace.
- NativeHTMLKit UI **0.1.1**: Python `nativehtmlkit_ui` and PowerShell `NativeHTMLKit.UI`, build-once/mount-once immutable component tree; owns reactive bindings, not dynamic router or extension framework. `docs/LIMITATIONS.md` records incomplete screen-reader qualification, a Python computed concurrency defect, input column sizing defect, and incomplete refreshed IME/scaling qualification.
- CLI **0.1.2** is an independent native forms/select/viewer utility, not the extension host; keep out of the dependency chain.
- Old Octopus GitHub source contains Python-only `octopus_sdk` manifest/view hooks, uv per-plugin environments, subprocess worker IPC, install rollback, registry, a capability broker and recovery; its **2026-11-14** qualification report recorded 84 passing tests but rejected publication due to package name conflict (`octopus-sdk` belongs to an unrelated PyPI project). It depends on old UI4ME APIs, `fcntl`/`select`, and is not a drop-in current NativeHTMLKit app.

### Critical issues and decisions

| ID | Priority | Issue / consequence | Minimal decision |
|---|---|---|---|
| R01 | P0 | One native backend per Core app; two languages cannot own the same window | TWO independent apps, one Python and one PowerShell, each owns its own SDK/UI session |
| R02 | P0 | UI library cannot mount arbitrary new component trees after startup | Static UI navigation + dynamic SDK-managed content region, tested on both languages |
| R03 | P0 | Python extension dependency conflicts inside one app process | Private uv venv **and** same-language child worker for each extension |
| R04 | P0 | PowerShell stdout can contain implicit pipeline/Write-Host output | Protocol on dedicated output stream, divert log streams; hard native 5.1/7 framing tests before full implementation |
| R05 | P0 | Naive "last known good" promise cannot undo DB schema/data migrations or external actions | Roll back package bits and active registry only; never advertise data/external rollback |
| R06 | P1 | Python and PS packaging/discovery metadata differ | Share JSON behavior schema, not executable or installation engine |
| R07 | P1 | Module `.psd1` can have executable-like import side effects | Read safe literal PSD1 metadata; import only inside worker; no automatic trust claims |
| R08 | P1 | Manual file drop may change code while app is running | Snapshot drop-ins to immutable managed version at next start; run only snapshots |
| R09 | P1 | Failure of one extension should not break shell | Worker-supervised errors, failed extension card, per-extension disable or rollback |
| R10 | P1 | Startup might block on offline Docker/remote servers | Manifest must be local and fast; do not contact remote systems until page/action request |
| R11 | P1 | Existing Octopus uses Linux-only file lock and pipe polling | Port the **idea** only; use portable Python subprocess IO and .NET processes for PS |
| R12 | P1 | User-added packages can run arbitrary code at install/build time | Explicit trust confirmation; pinned package source; private directories not a sandbox |
| R13 | P1 | Per-plugin worker needs bounded shutdown and deadlines | Only five operations and strict frame limits; no silent writes retried after timeout |
| R14 | P1 | AppShell editions can collide on application ID and shared state | Separate app IDs, user state roots and independent release CI |
| R15 | P2 | UI density/layout limits and known defects | Keep compact fixed sidebar and shell-owned CSS; work around known input-column bug; do not demand upstream refactor |
| R16 | P2 | Source upgrades can remove old versions with no recovery | Keep previous activated release and immutable state snapshot until next successful commit |
| R17 | P2 | Marketplace adds security/operations burden | Offline-first package source field, optional static HTTPS/local JSON catalog in later milestone |
| R18 | P2 | Rich plugin-generated forms risk event/control state loss on every refresh | Host-generated unique IDs; submit whole form; only replace page on navigation, explicit refresh or action completion |
| R19 | P2 | Inter-plugin service broker caused deadlocks in old Octopus until bounded-lock fix | Do not port the broker to v0.1. Add only with a real two-plugin use case, timeouts and cycle tests |
| R20 | P2 | Heavy startup cost for many PowerShell subprocesses | Accept 2-10 first-party extensions at v0.1; measure; only introduce lazy loading if benchmarks prove need |

## Lean alternatives compared

| Approach | Pros | Cons | Verdict |
|---|---|---|---|
| Directly import every Python/PS extension into UI | Fewest lines initially | Dependency conflicts; exceptions/modules pollute shell; no isolation; update/rollback brittle | Reject |
| One shared cross-language host | Reuses installation/runtime | Violates independent PowerShell/Python requirement, adds prerequisite and transport complexity | Reject |
| One process per extension, same-language workers | Fault containment and independent packages; old Octopus Python precedent; stable UI owner | More startup overhead, worker transport to implement twice | **Choose** |
| Generic enterprise plugin platform | Unlimited capabilities | Heavy lifecycle/security/marketplace abstraction before any real app | Reject |

## Functional scope / intentional omissions

**In v0.1:** empty shell launch, deterministic sidebar, extension listing, add from local folder/wheel/module, optional direct package name, native package staging, restart activation, JSON pages, forms/buttons/tables, explicit confirmation for writes, logs, disable/uninstall, rollback to last working executable, safe mode, docs and testkit.

**Not in v0.1:** Python↔PowerShell cooperation, event bus, service broker, hot reload, remote agent server, arbitrary HTML/CSS from extensions, custom UI adapters, cross-plugin sharing of secrets, plugin stores/accounts, auto updates, scheduled jobs, theme extension APIs, external window embedding, multiuser or multi-tenant permissions.

**Future only if demanded:** narrow versioned service calls, trusted in-process UI adapters, optional refresh polling, catalog search, native update UI.

## Decision checkpoints before engineering

1. Approve default process isolation, the only meaningful complexity kept deliberately for correctness.
2. Prove **PowerShell worker stdout framing** on WinPS 5.1, pwsh 7 Windows and pwsh 7 KDE Linux.
3. Prove **dynamic page updates** via public SDK after UI library mount on Python and PowerShell.
4. Ship a usable one-Python and one-PowerShell sample in *separate editions* before copying the old Octopus installer.
5. Demand parity by **contract fixtures**, not by forcing function names or threading models to match.
