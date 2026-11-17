# AppShell Python

Pure Python implementation of NativeHTMLKit AppShell. No PowerShell installation is needed.

```bash
uv venv .venv
uv pip install --python .venv/bin/python -e .
.venv/bin/appshell generate python --id org.example.hello --output ./hello-extension
.venv/bin/appshell stage add ./hello-extension
.venv/bin/appshell run
```

On Windows use `.venv\\Scripts\\appshell.exe` instead. Copy an extension project to
`$APPSHELL_HOME/extensions/<folder>/` to install on next startup; all environments are private.
See repository-root `README.md` and `docs/` for contracts, risks, and verification gates.
