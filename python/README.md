# NativeHTMLKit AppShell (Python edition)

A small native desktop shell built with [NativeHTMLKit](https://github.com/nativehtmlkit/nativehtmlkit).
Extensions are ordinary Python packages; each one runs in its own uv environment and worker process.
No PowerShell, browser, web server or Node.js is involved.

Requires Python 3.10+ and [`uv`](https://docs.astral.sh/uv/) on `PATH` (AppShell creates one private
environment per extension). Linux (KDE Plasma Wayland) and Windows are qualified.

```bash
uv tool install nativehtmlkit-appshell
appshell generate python --id org.example.hello --output ./hello-extension
appshell stage add ./hello-extension     # applied on the next start
appshell run
```

Other commands: `appshell list`, `appshell doctor`, `appshell enable|disable|remove ID`,
`appshell run --safe-mode`, `appshell restore` (last-known-good configuration, with AppShell closed).
Pinned sources: `appshell stage add package==1.2.3` or `git+https://github.com/owner/repo@<40-hex-sha>`.
You can also copy an extension project or `.whl` into `$APPSHELL_HOME/extensions/` (shown on the
Extensions page) and restart.

Extensions run with your user permissions; install only code you trust. Write commands ask for
confirmation, and a write whose worker crashed or timed out is reported as an unknown outcome and never
retried. Contract, recovery rules and verification evidence:
https://github.com/nativehtmlkit/nativehtmlkit-appshell
