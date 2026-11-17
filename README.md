# NativeHTMLKit AppShell

> **0.1.0 source candidate — implemented, qualification pending.** This repository contains
> independent Python and PowerShell desktop shells, native extension loaders, package
> staging/rollback, SDK-backed UI, generators, examples, tests, and a local-agent handoff.
> The Python unit/integration checks were run in the authoring environment. The PowerShell
> Pester suite and native desktop gates **have not** been run here; do not publish as GA yet.

AppShell is a deliberately small, native desktop application **built with** NativeHTMLKit.
It is not part of the Rust Core, SDK protocol, UI component library, or CLI.

**Two independent editions:**

| | Python AppShell | PowerShell AppShell |
|---|---|---|
| Host language | Python 3.10+ | PowerShell 7.2+ or Windows PowerShell 5.1 |
| UI dependencies | `nativehtmlkit`, `nativehtmlkit-ui` | `NativeHTMLKit`, `NativeHTMLKit.UI` |
| Extension type | Python wheel/PEP 621 project | `.psd1` + `.psm1` PowerShell module |
| Package source | `uv` (pinned PyPI/GitHub/local) | PSResourceGet, PowerShellGet, or local directory |
| Isolation | One installed uv venv + supervised Python subprocess per extension | One same-edition PowerShell subprocess **per request** |
| Other language required | **No** | **No** |
| State | Own registry/releases/data in Python home | Own registry/releases/data in PowerShell home |

The two editions implement the **same JSON v1 manifest, page and action contracts**, with
separate native implementations. Neither shell loads extensions from the other language. No
cross-language broker, Node.js, browser, HTTP server, central marketplace or runtime hot reload.

## Quick start: Python

Prerequisites: installed NativeHTMLKit Core/native host and compatible Python/UI packages.
From `python/`:

```bash
uv venv .venv
uv pip install --python .venv/bin/python -e .
.venv/bin/appshell doctor
.venv/bin/appshell generate python --id org.example.hello --output ./MyHello
.venv/bin/appshell stage add ./MyHello
.venv/bin/appshell run
```

On Windows use `.venv\\Scripts\\appshell.exe` (and that environment's Python interpreter).
`appshell run` starts the native window; the first boot applies staged changes. An extension
may instead be copied as a folder with `pyproject.toml`, or as a `.whl` file, directly into
`$APPSHELL_HOME/extensions/`. Restart AppShell after changing installed packages.

- List: `appshell list`
- Queue enable/disable/remove: `appshell enable org.example.hello`, etc.
- Recovery: `appshell run --safe-mode` or `appshell restore` with the shell closed.
- Install from pinned PyPI: `appshell stage add my-package==1.2.3`
- Install from pinned Git commit: `appshell stage add git+https://github.com/owner/repo@<40-hex-sha>`

**Why `uv`?** It creates one private Python environment per extension. A source distribution
may execute build hooks and dependencies have full user permissions: only install trusted code.

## Quick start: PowerShell

Prerequisites: the NativeHTMLKit PowerShell SDK and `NativeHTMLKit.UI` module on the same machine.
No Python or uv required. On Linux run with PowerShell 7; on Windows use PowerShell 7 or 5.1.

```powershell
Import-Module ./powershell/NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1 -Force
New-AppShellExtension -Id org.example.hello -OutputPath ./MyHello -Title 'My Hello'
Add-AppShellExtension -SourcePath ./MyHello
Start-AppShell
```

Alternatively copy `MyHello` under the PowerShell AppShell `extensions/` folder and restart.
Gallery installs can be queued with a pinned version:

```powershell
Add-AppShellExtension -Name Example.Module -RequiredVersion 1.2.3
```

The module must have AppShell manifest metadata and export `Invoke-AppShellExtension`.
View installed modules with `Get-AppShellExtension`; queue changes with
`Enable-AppShellExtension`, `Disable-AppShellExtension`, `Remove-AppShellExtension`.
Use `Restore-AppShell` while the window is closed or `Start-AppShell -SafeMode` for recovery.

## Extension authoring

- `templates/README.md` — both generator commands
- `examples/python/Greeter/` — complete Python package, sample page/actions and pytest
- `examples/powershell/Greeter/` — complete PowerShell module, sample page/actions and Pester
- `docs/03-CONTRACTS.md` and `contracts/*.schema.json` — versioned API

An extension returns plain dictionaries/hashtables for four conceptual operations:
`manifest`, `page`, `action`, `shutdown`. AppShell owns the UI and converts validated page
nodes to NativeHTMLKit's SDK document interface. Extension developers do not need to learn the
windowing engine or write an AppShell-specific runtime dependency.

## Installation and recovery behavior

1. User stages a package, adds a folder, or copies it to `extensions/`.
2. Existing workers and navigation remain unchanged until restart.
3. On restart AppShell prepares an immutable release, validates its metadata and manifest,
   then activates it. Failed candidates do not replace the previous release.
4. The shell stays available even if an extension fails. Errors appear in Extensions; Python
   worker stderr is available in per-extension logs. PowerShell boot errors are displayed.
5. A clean successful session records a **last-known-good executable configuration**. On the
   next start after an unclean exit or explicit restore, AppShell restores that configuration
   and quarantines a changed direct-drop candidate when possible.

A virtual environment or process does **not** sandbox the plugin from the user's files,
credentials, or network. Last-known-good does **not** roll back extension-owned data or remote
side effects. A write action whose worker disappears or times out has an *unknown outcome*:
AppShell does not automatically retry it.

## Repository map

```text
contracts/                     frozen shared JSON v1 schemas
fixtures/                      valid/invalid contract examples
python/                        Python host, CLI, worker, install, UI, pytest
powershell/                    PowerShell module, worker, UI, Pester
examples/python/Greeter/       installable Python example
examples/powershell/Greeter/   installable PowerShell example
templates/                     generators and template guidance
docs/                          normative design, risks, verification, ADRs
agent/                         autonomous completion / qualification prompt
scripts/                       offline validation and packaging helpers
```

## Development / release qualification

Run Python contract and real local-uv worker tests:

```bash
cd python && python -m pytest -q
```

Run PowerShell tests with Pester 5 (PS7 Linux, PS7 Windows and Windows PowerShell 5.1):

```powershell
Invoke-Pester ./powershell/tests
Invoke-Pester ./examples/powershell/Greeter/tests
```

For native GUI gates, use the existing KDE Wayland desktop and Windows test VM with disposable
AppShell homes. The exact matrix, unresolved risks and instructions are in
`docs/13-VERIFICATION.md`, `docs/12-IMPLEMENTATION.md`, and `agent/LOCAL-AGENT-PROMPT.md`.

## Scope limits

AppShell v0.1 deliberately has **no** plugin-to-plugin broker, inventory, credential provider,
full extension marketplace, arbitrary plugin HTML/JS, background polling or hot reload. Its
fixed semantic view contract is enough for useful administration/monitoring extensions. Build
new contribution points only after a real extension demonstrates the need.

MIT licensed. See `LICENSE`.
