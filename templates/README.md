# Generated extension templates

Templates are created by the built-in native-language generators, not copied from
an AppShell-specific binary format. Each output is an ordinary installable package.

## Python template

```bash
appshell generate python --id org.example.mytool --output ./MyTool --title "My Tool"
```

Creates `pyproject.toml`, an importable extension implementation and pytest test.
See `examples/python/Greeter/` for a fully populated copy of the generated template.

## PowerShell template

```powershell
Import-Module ./powershell/NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1
New-AppShellExtension -Id org.example.mytool -OutputPath ./MyTool -Title 'My Tool'
```

Creates a valid `.psd1` and `.psm1` plus a Pester test and README.
See `examples/powershell/Greeter/` for the maintained working example.

No generated extension imports NativeHTMLKit or the other language: it implements
four plain dictionary/hashtable operations as defined in `docs/03-CONTRACTS.md`.
