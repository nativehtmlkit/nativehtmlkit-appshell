# nativehtmlkit-appshell — development-agent instructions

**Ownership:** the NativeHTMLKit AppShell application (a small native desktop shell for extensions), in two independent editions packaged as `nativehtmlkit-appshell` (PyPI) and `NativeHTMLKit.AppShell` (PowerShell Gallery).

This is an independent Git repository in the NativeHTMLKit ecosystem. Central issue tracking, approval and cross-repository coordination are in the private workspace `nativehtmlkit-project` under `work/bugs/` and `work/features/` (normally at `../../work/`). When cloning this repository alone, locate that workspace with `NHK_PROJECT_ROOT`; do not create a duplicate issue register here.

## Mandatory behavior

1. Read the root Project `AGENTS.md`, `governance/SCOPE.md`, `governance/ARCHITECTURE.md`, `governance/WORKFLOW.md` and the generated `STATUS.md` when the workspace is available. Read this repository's README, `docs/02-ARCHITECTURE.md`, `docs/03-CONTRACTS.md` and `docs/12-IMPLEMENTATION.md` as relevant.
2. Only implement an approved `B-####` or `F-####` item. Record unrelated defects and continue.
3. This is an application: it depends only on the public language SDKs (`nativehtmlkit`, `NativeHTMLKit`) and NativeHTMLKit UI (`nativehtmlkit-ui`, `NativeHTMLKit.UI`). No Core protocol, CLI or private SDK imports.
4. The two editions implement the same JSON v1 manifest, page and action contracts (`contracts/*.schema.json`, `fixtures/`) natively. Neither edition loads extensions from, or requires, the other language. Change a contract in both editions and their tests together.
5. Preserve the simple scope: no cross-language broker, web server, Node.js/npm, marketplace backend, hot reload, plugin event bus or new UI DSL. Write actions are never retried automatically.
6. Never publish, tag, bump versions or push without explicit authorization. GitHub Actions only publish release assets that were built and qualified locally (`scripts/build.py`); they never build or test.
7. Do not claim tests passed without running them. Record qualification results in `docs/VERIFICATION.md` without private lab hostnames, paths or logs.
8. Public documentation describes released behaviour only, with no private lab hostnames, paths, logs or raw Project issue data.

## Layout and commands

| Path | Content |
|---|---|
| `contracts/`, `fixtures/` | shared JSON v1 schemas and valid/invalid examples |
| `python/` | Python edition (host, CLI, worker, install, UI) and pytest suite |
| `powershell/` | PowerShell edition (module, worker, UI) and Pester suite |
| `examples/`, `templates/` | installable Greeter extensions and generator guidance |
| `scripts/` | `qualify.py` (offline checks), `build.py` (release artifacts in `dist/`) |
| `qualification/gui/` | real-input desktop driver and probes (test tooling) |

```bash
uv run scripts/qualify.py                                               # inventory, JSON, Python AST, PowerShell parser (if pwsh)
cd python && uv run --no-project --with pytest --with-editable . pytest -q tests   # native tests start the host in headless mode
uv run scripts/build.py                                                 # wheel, sdist, module zip, SHA256SUMS in dist/
```

```powershell
Invoke-Pester ./powershell/tests, ./examples/powershell/Greeter/tests   # Pester 5; PS 7 and 5.1
```

Real-input desktop runs: `qualification/gui/` (KDE Wayland: `run-linux.sh`; Windows: `driver.py` inside an interactive desktop session). Verify the Python edition on Linux and Windows, and the PowerShell edition with PowerShell 7 on Linux and Windows and with Windows PowerShell 5.1.
