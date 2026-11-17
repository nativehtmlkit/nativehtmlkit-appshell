# Build and qualification results — 2026-11-17

> **Superseded by `VERIFICATION.md`** (native qualification of both editions on Linux and Windows,
> same day). The table below is the original authoring-environment report, kept as history; its
> "NOT RUN" rows have since been run and several of the risks it lists were real defects.

This report states what was actually executed in the authoring environment. It is **not** a
native release qualification or a claim that PowerShell runs successfully on the target OS.

| Check | Result | Evidence / limitation |
|---|---|---|
| Repository source/inventory check | PASS | `python scripts/qualify.py`: 20 mandatory paths, Python AST, JSON parsing, 10 PowerShell scripts present |
| Python host unit and integration suite | PASS | `cd python && python -m pytest -q`: 21 passing tests |
| Generated Python extension test | PASS | `PYTHONPATH=examples/python/Greeter/src python -m pytest examples/python/Greeter/tests -q`: 1 passing test |
| uv source distribution + wheel | PASS | `uv build --offline --no-build-isolation` produced 0.1.0 sdist and `py3-none-any` wheel |
| Wheel content | PASS | Contains all host source modules, standalone worker and `resources/appshell.css` |
| Fresh wheel install, headless CLI and generator | PASS | Fresh venv, `uv pip install --no-deps`; `appshell --help`, `doctor`, `generate` executed |
| Real local uv package install + worker + actions | PASS | Python integration test builds plugin wheel, installs into private venv, invokes manifest/page/refresh/save, restarts |
| PowerShell module syntax/Pester execution | **NOT RUN** | PowerShell not installed in this authoring environment |
| Native Python AppShell UI | **NOT RUN** | Matching NativeHTMLKit Core/SDK/UI unavailable in authoring runtime |
| Native PowerShell AppShell UI | **NOT RUN** | Matching NativeHTMLKit Core/SDK/UI and PowerShell unavailable |
| Linux KDE Wayland, Windows VM smoke | **NOT RUN** | Hand off to local agent |

The available source archives were inspected to align with their public NativeHTMLKit SDK/UI
APIs. Any native or PowerShell runtime incompatibility found by the local agent must be fixed,
verified, and recorded before publication. Do not mark native tests passed on the strength of
code inspection, static JSON checks or wheel compilation.

## Known risks for local qualification

- PowerShell 5.1 and 7 modules/runtime need real parse, Pester, process I/O and UTF-8 tests.
- Fresh per-request PowerShell child process latency needs measurement with realistic modules.
- Saved gallery module transitive dependencies are subject to native PSResourceGet/PSModulePath
  behavior; verify pinned versions and module resolution on target Windows and Linux.
- NativeHTMLKit app host re-exec, event bubbling, dialogs and task callback semantics require
  the installed SDK/UI versions and real keyboard/pointer sessions.
- Both editions run third-party code with the current OS user permissions; venvs and modules
  are not security boundaries. Never test against live administrative accounts or resources.

Release requirements are in `docs/13-VERIFICATION.md` and the single agent handoff prompt in
`agent/LOCAL-AGENT-PROMPT.md`.
