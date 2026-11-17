# Source review and outside references

**Reviewed on:** 2026-11-17. This is a design assessment, not a new automated testing report. External references may change after this date. Source names are snapshot labels from the user's attached archives.

## Attached NativeHTMLKit archives (directly inspected)

1. `nativehtmlkit-core(3).zip`, SHA/repository snapshot prefix `2c406f9`: `README.md`, `docs/ARCHITECTURE.md`, `protocol/README.md`. Core 1.0.3, wire protocol v1, one authenticated client.
2. `nativehtmlkit-python(2).zip`, `be06a10`: `README.md`, `docs/ARCHITECTURE.md`, `docs/reference/document.md`, code `src/nativehtmlkit/application.py`; Python SDK 0.1.2, startup re-exec, document replace, event and form APIs.
3. `nativehtmlkit-powershell(2).zip`, `447a348`: `README.md`, `docs/ARCHITECTURE.md`, `docs/reference/documents.md`, `docs/reference/events.md`, `docs/reference/forms.md`; PowerShell SDK 0.1.2, native module APIs and owner-runspace dispatch.
4. `nativehtmlkit_ui(1).zip`, `461a41a`: `README.md`, `docs/ARCHITECTURE.md`, `docs/LIMITATIONS.md`, Python/PowerShell references; UI 0.1.1, immutable mounted component tree, current limits.
5. `nativehtmlkit-cli(3).zip`, `69f8bbb`: `README.md`, `docs/ARCHITECTURE.md`; CLI 0.1.2 separate native utility, deliberately not needed for AppShell extension host.
6. `nativehtmlkit(3).zip`, `77062bf`: `README.md`, public capability matrix/limitations and site source; confirms family naming/platform context.

## Prior implementation revisited

An earlier private prototype ("Octopus"): `README.md`, `docs/ARCHITECTURE.md`, `docs/SPEC.md`, `docs/SDK.md`, `docs/DECISIONS.md`, `docs/SECURITY.md`, `docs/LOCAL-QUALIFICATION-RESULT.md`, `src/octopus/worker_client.py`, `src/octopus/state.py`, `src/octopus/desktop.py`, `packages/octopus-sdk/src/octopus_sdk/{contracts,worker,hooks}.py`.

Reusability decision: architectural pattern and portions of Python-only code **may** be adapted under its MIT license; PowerShell is written independently. Old UI4ME-specific rendering code, Linux-only process locking/polling, Python↔PowerShell ambitions, plugin marketplace framework, and conflict-prone `octopus-sdk` distribution name are not carried over.

## Official external research (consulted during review)

- PyPA: creating/discovering plugins: https://packaging.python.org/en/latest/guides/creating-and-discovering-plugins/
- PyPA: entry points specification: https://packaging.python.org/en/latest/specifications/entry-points/
- uv: managing Python environments and explicit `--python`: https://docs.astral.sh/uv/pip/environments/
- Microsoft: PowerShell module manifests and `PrivateData`: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_module_manifests
- Microsoft: `Import-PowerShellDataFile` static data parsing: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/import-powershelldatafile
- Microsoft: `Save-PSResource -Path`: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.psresourceget/save-psresource
- Microsoft: module discovery/installation: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_modules
- Microsoft: PowerShell module paths on versions/platforms: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_psmodulepath
- VS Code contribution-point model (inspiration, **not** source/API copied): https://code.visualstudio.com/api/references/contribution-points
- VS Code extension host separation (inspiration): https://code.visualstudio.com/api/advanced-topics/remote-extensions

## Gaps not externally proven

- No PS 5.1/pwsh 7 worker transport prototype was executed in this review environment. That is a blocking milestone.
- No package availability/reservation claim for `nativehtmlkit-appshell` or `NativeHTMLKit.AppShell` is made; check ownership and publication at release time.
- No NativeHTMLKit GUI regression or platform test was executed here; the sources report their own qualification, which is not interchangeable with AppShell qualification.
- Native UI `replace_html` is a documented SDK capability, but coexistence with mounted UI bindings, focus and event routing must be tested in each edition.
