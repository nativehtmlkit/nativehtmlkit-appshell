# Architecture (normative)

## Strict dependency boundaries

```
NativeHTMLKit Core (Rust; existing; unchanged)
     ├── NativeHTMLKit Python SDK ── NativeHTMLKit UI Python ── AppShell Python
     │                                                    └── Python extension workers
     └── NativeHTMLKit PowerShell SDK ── NativeHTMLKit.UI ── AppShell PowerShell
                                                        └── PowerShell extension workers
```

There are **two different native windows, app IDs, runtimes, registries, installed package sets and backend processes** if both editions are installed. They are independent and can run side by side. Proposed native application identities are `org.nativehtmlkit.AppShell.Python` and `org.nativehtmlkit.AppShell.PowerShell` (subject to actual Core app-id validation). PowerShell AppShell MUST NOT invoke `python`, `uv`, or Python import mechanisms in its runtime or build; Python AppShell MUST NOT invoke `pwsh`, `powershell.exe` or PowerShell modules. Both connect to the same pre-existing Core technology **through their own public SDK**, never through raw Core protocol APIs.

The phrase "shared contract" means common JSON message shapes, validation fixtures, UX behavior and test criteria. There is **no** shared runtime/service/process dependency.

## Each edition has exactly five responsibilities

1. **Shell:** render fixed sidebar/topbar, extension list, errors and selected page in one native window.
2. **Registry:** track sources, enabled flags, active and pending versions, status and last-good active release.
3. **Installer/preparer:** stage native packages into app-owned immutable versions; restore previous on failure.
4. **Worker supervisor:** launch *same-language* processes, receive manifest/page/action responses, handle timeouts/termination.
5. **View adapter:** validate structured view data and turn it into safe native SDK HTML DOM operations; route form/button events to a worker.

Do not create abstract providers, Dependency Injection containers, built-in storage services, telemetry backends, runtime HTTP endpoints or a global event bus.

## Logical processes (for **each** language independently)

```
User launches appshell
  │
  ▼
NativeHTMLKit Core native host  ← authenticated link →  AppShell backend (same language)
                                                     │
                           SDK + UI-owned window     ├── registry + startup recovery
                                                     ├── fixed navigation + dynamic view renderer
                                                     └── worker supervisor
                                                         ├── extension A subprocess (same language)
                                                         └── extension B subprocess (same language)
```

- Python: native SDK app backend, Python venv workers; no PowerShell process.
- PowerShell: native SDK app backend, PowerShell 5.1 or 7 worker selected to match running edition; no Python process.
- Each extension worker uses private standard-input/output JSONL framing for **host-internal** requests and response. Stderr is diagnostic. Worker is the only place third-party code loads.
- Python worker implementation can reuse ideas from old Octopus; PowerShell worker is a native PowerShell implementation with .NET process/streams, not a Python port hidden inside a script.

## Public extension model vs internal worker protocol

**Public extension authors** implement 4 methods/operations described in `03-CONTRACTS.md` using dictionaries/hashtables and native package metadata. They MUST NOT need to know IPC, Core, SDK, GUI threads or CSS. **Internal workers** translate requests and results to JSON and are free to differ internally between languages; frame tests still enforce the behavior contract.

## Startup sequencing

- Launch native SDK in the officially supported supervised way. Do not do state mutation, import extensions or launch workers before connecting to the host backend (SDK launch can re-execute the script).
- Acquire per-edition single-instance state lock. Render shell and recovery route as soon as the app is ready.
- Discover and stage changed sources; validate recorded active/pending versions; start workers sequentially with bounded timeouts, initially at most 10 extensions tested.
- Build navigation only from successfully validated `manifest` responses. Failed ones are visible in Extensions with logs/retry-on-restart.
- Do not connect to Docker/SSH/Proxmox/network during `manifest` or the shell's own startup.

## UI ownership / dynamic page outlet

Current NativeHTMLKit UI builds its component tree once. Build a stable shell with a dedicated `<main>` outlet before `mount` / `Start-NHKUi`. On navigation or an action result, validate a view JSON and use:

- Python: the mounted SDK `Document.replace_html(outlet_id, trusted_rendered_html)`; `Document.on`, `form_data`, `batch`, `set_text` for updates.
- PowerShell: `Set-NativeHTMLKitDocumentHtml -Position replace`, `Register-NativeHTMLKitDocumentEvent`, `Get-NativeHTMLKitFormData`, `Invoke-NativeHTMLKitBatch`.

Native UI is owned by AppShell only. Plugin **text is escaped** and plugin-specified arbitrary HTML, CSS, JS, file paths or SDK handles are rejected. The shell generates unique element IDs to route native `click`/`submit` without installing per-row UI library callbacks after mounting. Bindings of the static sidebar remain under the UI library.

Only the **selected page** is rendered; refresh on page switch, explicit Refresh or completion of a command. Do not implement background polling or virtual DOM in v0.1. When replacing the content outlet, restore selection/focus only where tested. Avoid replacing the page while users type.

## Worker lifecycle

One active worker per enabled extension. Worker loads module/distribution from a pinned immutable release directory; `manifest`, `page`, `action`, `ping`, `shutdown` only. Responses are bounded. Workers are launched without elevated privileges and under the current OS user. A worker crash is an extension failure, not a UI crash. On logout/quit AppShell requests shutdown with a bounded grace period and then terminates workers. A detached domain operation is the extension's own responsibility, never hidden in the shell.

## Data ownership

AppShell owns only its registry/installation state and log locations; every extension owns a separate `data/<id>` directory, exposed through its runtime context. AppShell does **not** know Docker hosts, user credentials, SSH config, database schemas, or secrets. Extension data persists on disable/uninstall unless the user explicitly selects **Delete extension data**. Do not include extensions' data directories in app version rollback.

## Repository layout

```
nativehtmlkit-appshell/
  contracts/                 # JSON schema and fixtures (language-neutral)
  docs/                      # normative architecture/spec/ADRs
  python/                    # independent Python package and tests
  powershell/                # independent PowerShell module and Pester tests
  examples/python/           # Python-only installable demo
  examples/powershell/       # PowerShell-only module demo
```

Never import or package source from `python/` into the PowerShell edition, nor vice versa. Python and PowerShell test tasks can run in different CI jobs without installing the other runtime.
