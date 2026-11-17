@{
    RootModule = 'AppShell.Showcase.psm1'
    ModuleVersion = '0.1.0'
    GUID = '4b0cf4a5-0d6f-4b52-9a8a-2b7fd2a1f0c1'
    Author = 'NativeHTMLKit contributors'
    Description = 'AppShell test extension: every v1 block kind, hostile text and failure commands'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-AppShellExtension')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ AppShell = @{ Id = 'org.example.showcase'; ApiVersion = 1 } }
}
