# AppShell PowerShell

Native PowerShell 7.2+ edition for Linux or Windows and Windows PowerShell 5.1 edition for Windows.
No Python installation is needed. Requires `NativeHTMLKit` and `NativeHTMLKit.UI` modules.

```powershell
Import-Module ./NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1 -Force
New-AppShellExtension -Id org.example.hello -OutputPath ./HelloExtension
Add-AppShellExtension -SourcePath ./HelloExtension
Start-AppShell
```

See root documentation for how staging, restart activation, and safe mode work.
