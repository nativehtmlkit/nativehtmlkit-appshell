# Python Greeter — AppShell Python extension

Install it by copying this directory under AppShell's `extensions/` folder, or run
`appshell stage add .` from the project directory and restart AppShell.

The extension uses plain dictionaries and a Python entry point. It never imports
AppShell, NativeHTMLKit, or PowerShell. `manifest` must be read-only and fast; `page`
returns validated semantic blocks; `action` is invoked after shell confirmation.
Update `pyproject.toml` and `manifest()` versions together. See root `contracts/`.
