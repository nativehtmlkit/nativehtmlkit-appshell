# Packaging, installation and filesystem specification

## Goal

A developer can drop a native package into an `extensions/` folder or use an Add Extension dialog/terminal command. Adding does **not** activate the plugin immediately. Restart applies the change. The UI is intentionally not a package-manager front end with dependency graphs, background upgrades or cloud accounts.

## Platform data roots (proposal)

- Linux Python: `${XDG_DATA_HOME:-~/.local/share}/nativehtmlkit/appshell/python/`
- Linux PowerShell: `${XDG_DATA_HOME:-~/.local/share}/nativehtmlkit/appshell/powershell/`
- Windows Python: `%LOCALAPPDATA%\NativeHTMLKit\AppShell\Python\`
- Windows PowerShell: `%LOCALAPPDATA%\NativeHTMLKit\AppShell\PowerShell\`
- `APPSHELL_HOME` absolute-path override **for testing/dev only**; separate test homes for two editions.

Contents **within each separate language root**:

```
AppShellRoot/
  extensions/                   # USER-WRITABLE drop-ins; one child folder per extension
    org.example.hello/           # local source/PowerShell module copied by user
  incoming/                     # pending archive/source preparation from UI
  releases/                     # managed, immutable activated snapshots
    org.example.hello/
      0.1.0-<short-content-hash>/
        source/                  # exact source snapshot / copied PS module
        .venv/                   # Python only; never in PowerShell edition
  data/                         # persistent per-extension data, not rollback target
    org.example.hello/
  logs/
  registry.json                 # enabled/active/pending/source/status metadata
  last-good.json                # previously activated release map
  startup.json                  # marker: candidate boot in progress / normal exit
  .lock                         # per-edition mutation/single-instance lock
```

Both editions create the **same logical folders** but **never share the same root**. Worker process sees an active immutable `releases/...` directory. Copying into a drop-in while the shell runs never changes the running code; it is considered for the next restart.

## Python edition — standard packaging

Requirements: Python 3.10+ and `uv` available to the Python edition for package preparation. In a release, AppShell itself depends on `nativehtmlkit`, `nativehtmlkit_ui` and standard library packaging functionality, but extension workers **do not require NativeHTMLKit**. Distributions may have their own dependencies.

A conforming plugin is a normal wheel/source project with an entry point named after its extension ID:

```toml
[project]
name = "appshell-hello"
version = "0.1.0"
requires-python = ">=3.10"

[project.entry-points."nativehtmlkit.appshell.extensions"]
"org.example.hello" = "appshell_hello.plugin:Extension"
```

Supports staged sources: pinned PyPI `name==version`, local `.whl`, and local folder containing `pyproject.toml`. A pinned Git commit source can follow in a later UX milestone. These three source modes belong in v0.1; `uv` does the actual environment preparation **after restart**. No arbitrary ZIP or custom plugin bundle required. For a dropped wheel, the shell copies it to `releases/<id>/<version>-<hash>/source/`; then builds a private venv and executes an explicit `uv pip install --python <venv-python> <wheel/path-or-project>`. Only then does it inspect `importlib.metadata` in **that venv** to find exactly one matching AppShell entry point. All imports happen in a child process. Do not use `uv tool install` as a plugin import mechanism.

**No dependency on a globally published `appshell-sdk` distribution in v0.1.** The host supplies its tiny standard-library worker bootstrap at an explicit filesystem path. This avoids recreating Octopus's unresolved `octopus-sdk` PyPI name collision. Plugin author gets a documented duck-typed API, schema and fixtures; optional typed stubs can come later.

## PowerShell edition — standard modules

A conforming extension is a valid `.psd1`/`.psm1` module. `PrivateData.AppShell.Id` identifies it. Export `Invoke-AppShellExtension`. Version comes from native `ModuleVersion`, and the extension's returned manifest must match.

- User may drop the entire module directory under `extensions/org.example.hello/`; scan and stage it at next startup.
- Gallery install: if PSResourceGet exists, use `Save-PSResource -Name ... -Version ... -Path <temporary-staging>` to fetch, then inspect/copy the resulting module folder. **Do not** `Install-Module` globally or mutate the user's global `PSModulePath` permanently. Fall back to manual copy / conventional PowerShellGet workflow where PSResourceGet is absent; don't impose PowerShell 7 as a prerequisite for Windows PowerShell 5.1.
- Worker imports **an explicit absolute `.psd1` path** from its immutable release, not a module name that could resolve another globally installed version. Set a worker-local private `PSModulePath` prefix only if declared dependencies need it. Prefer native `RequiredModules` declarations and document missing external prerequisites; do not invent a generic dependency resolver.
- For static discovery, use literal manifest data reading, not `Invoke-Expression`. Untrusted `.psd1` metadata and package installation must be treated as untrusted and checked for path traversal and unexpected contents.
- PowerShell edition runs under its own chosen runtime: `powershell.exe` for Windows PowerShell 5.1, `pwsh` for PowerShell 7. Do not silently upgrade/switch engines for an extension.

Official docs: `Save-PSResource -Path`, `Import-PowerShellDataFile` and `about_Module_Manifests` support these paths (see SOURCES).

## Add extension workflow

1. User selects `Add extension` → native package source (`Local folder / wheel / module`, or package registry once implemented), or manually copies a folder.
2. For a local source, AppShell **only copies** source into `incoming` (plus basic shape/hash checks). For a pinned PyPI/Gallery source, AppShell **only records the exact native package identifier and approved source** for later resolution; it may fetch descriptive metadata at the user's request. No native module import, `uv pip install` or dependency build happens in the current running shell. A copied folder is detected on the next startup because AppShell is not watching the filesystem.
3. Keep the installed/active version untouched; record candidate (`pending`), display `Restart required`.
4. On restart, apply pending packages and scan drop-ins, then run native package download/build/dependency preparation **only for changed extensions**, start the new worker, validate its manifest and register its pages. The shell must remain responsive and show per-extension installation status during this boot phase.
5. On candidate failure, keep or restore previous active release and record an error; show diagnostics. No user account, remote service or restart loop.

Updates/removal/enable/disable follow the same restart rule. Uninstall removes **managed executable releases only** after the application closes, unless user selects `Delete data`; dropping a module into the manual source folder remains the user's own file and must not be silently deleted.

## Installer rules

- Use argument arrays, never shell-concatenated commands or `Invoke-Expression`.
- Restrict copies/extraction to owned directories; reject `../`, absolute paths, symlinks escaping root, unusual resource names and duplicate/case-insensitive IDs.
- Install/build may run third-party code: explicit trust acknowledgement is required for UI-driven downloads. Manually copied code implies user control but is **not** validated safe.
- Prefer exact package version, immutable commit and recorded SHA-256; refuse arbitrary HTTP package sources in first release.
- Package data, logs and user configuration do not live inside releases; do not copy secrets into recovery snapshots.
- Failed staging leaves active state unchanged. Orphaned temporary versions are reported by `doctor` and can be cleaned explicitly.
- Online registry source is opt-in. A static JSON catalog is an index of links, **never an execution trust authority**. No auto-updates.
