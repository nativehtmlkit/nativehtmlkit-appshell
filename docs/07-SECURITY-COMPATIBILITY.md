# Security, compatibility and boundaries

## Threat model

This is an **expert-user desktop extension host**, not an untrusted-code sandbox. Plugin packages build or import arbitrary user-chosen code. The standard view renderer prevents UI markup injection but does not stop a malicious plugin from reading its user-accessible files, using the network, invoking Docker, or altering remote systems under the current user's privileges. A private Python venv, PowerShell child process and JSON broker are **dependency/fault boundaries**, not permission boundaries.

### Rules required in v0.1

1. Install only from sources consciously trusted by operator; UI must show trust warning. Manual folder drop implies user-chosen code, not platform-verified safety.
2. Strictly validate `manifest` and `view`; always escape text. Never eval view-provided HTML/JS/CSS, `Invoke-Expression` PowerShell or dynamic shell command strings.
3. Use absolute module/release paths and immutable staged snapshots. Validate file layout and ensure path does not escape root through symlinks/reparse points. Reject duplicate/case-variant IDs.
4. Host owns stdout protocol channel. Debug prints and PowerShell pipeline/host output must be redirected to bounded stderr logs; if framing is corrupted, fail that worker instead of guessing a response.
5. Bound worker startup/response time, max frames, number of page blocks and concurrency. Keep the UI thread/runspace unblocked by extension I/O. On timeout of a sent write, report `Outcome unknown` and NEVER silently retry.
6. Never log sensitive form input/passwords. Mask `password` values in diagnostics, avoid raw unredacted action payloads, limit log file size and set per-user ACLs/permissions.
7. Extension config/data is private to each identity in storage layout but accessible to other same-user code outside the broker. Secrets belong in OS secret store or extension-specific secure implementation, not `last-good.json` or general registry.
8. A `write`/`destructive` confirmation is a guard against accidental user actions only; code can misbehave during `manifest`, `page`, or import. No claim of strong sandboxing.
9. No remote HTTP servers, local TCP listeners or telemetry. Package installation is opt-in network I/O; ordinary shell startup must be offline-capable.
10. Keep a complete operational trail for failed install, failed worker, fallback, restore, manual data deletion and changed enabled state.

## Platform matrix

| Capability | Python Linux KDE | Python Windows | PS 7 Linux KDE | PS 7 Windows | PS 5.1 Windows |
|---|---|---|---|---|---|
| Native shell via public SDK/UI | Target | Target | Target | Target | Target |
| Python extension venv + uv | Yes | Yes | Not applicable | Not applicable | Not applicable |
| PowerShell module `.psd1` | Not applicable | Not applicable | Yes | Yes | Yes |
| PSResourceGet optional gallery install | Not applicable | Not applicable | When installed | When installed | When installed |
| Direct folder drop | Yes | Yes | Yes | Yes | Yes |
| Worker fault isolation | Test required | Test required | Test required | Test required | Test required |
| Cross-language extensions | No | No | No | No | No |
| PowerShell-only implementation free of Python | N/A | N/A | REQUIRED | REQUIRED | REQUIRED |

The matrix states **targets**, not current AppShell test results. NativeHTMLKit SDK support has been documented on each target, but AppShell does not yet exist. macOS is excluded until Core and both SDK/UI stacks qualify it.

## Dependency policy

- AppShell Python depends only on its public NativeHTMLKit Python SDK, public UI package, uv as an installer/tool, and standard Python dependencies necessary for its own runtime. It cannot depend on the PowerShell SDK or CLI.
- AppShell PowerShell depends only on public NativeHTMLKit and NativeHTMLKit.UI PowerShell modules and PowerShell/.NET built-ins. PSResourceGet is **optional for online installation**, not necessary for manual folder use. It cannot depend on Python or uv.
- Extension authors are not required to install an AppShell SDK. Their handlers operate on dictionaries/hashtables and local standard packaging metadata. They can use any domain dependencies they need within their own native environment.
- AppShell extensions may itself call Docker/SSH/REST/WinRM/Proxmox from their respective languages, but AppShell does not implement these domains.

## Platform-specific quirks to test

- Windows PowerShell 5.1 and pwsh 7 use different default module search paths; explicit module paths and worker-local module path fix this. No accidental import from globally installed same-name module.
- PS worker stdout includes .NET/PowerShell output streams beyond normal object return; test all of them. Progress and verbose streams must not break JSON framing.
- PowerShell 5.1 JSON conversion has different behavior and serializer bounds; normalize object properties, BOM/UTF-8 encoding and arrays/null/boolean values in tests.
- Windows module and extension paths may be case-insensitive; Linux paths case-sensitive, but AppShell ID normalization is case-insensitive in both for consistency.
- Windows file replacement/rename may fail while workers hold handles; stage versions and activate on restart instead of overwriting loaded module files.
- Python SDK can re-execute launcher; no worker imports or registry mutation before backend handshake.
- Core uses a single authenticated connection per app; no plugin may try to connect as a second frontend using its own native SDK session.

## Limits and error semantics

- Manifest 128 KiB, view 1 MiB, wire message 1 MiB+64 KiB, 300 UI nodes, 200x24 table, depth 10, 80 form fields.
- Default worker boot deadline 12 seconds, page 15 seconds, action 120 seconds, shutdown grace 2 seconds. These are initial spec defaults to tune through native testing. Long administrative workflows require an extension-owned async/background workflow; do not block the shell for 30 minutes.
- An extension may opt into no automatic retries. Shell itself never retries side-effectful actions after ambiguous transport outcomes.
- On UI closure, stop accepting new actions, ask workers to shut down, bound waits and terminate. User may see outstanding-write unknown notice before final window close if feasible.
