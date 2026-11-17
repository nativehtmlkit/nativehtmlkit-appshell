# PowerShell extensions

`Greeter` is a normal PowerShell module in its own folder, with an `.psd1` module
manifest and a single exported `Invoke-AppShellExtension` function.

To install it without package managers:

```powershell
Import-Module ../../powershell/NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1 -Force
Add-AppShellExtension -SourcePath ./Greeter
Start-AppShell
```

Alternatively, copy `Greeter` to the AppShell `extensions/` folder and launch the shell.
Use `New-AppShellExtension -Id org.example.my-tool -OutputPath ./MyTool` to generate
a new, independent module rather than copying the example by hand.
