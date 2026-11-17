@{
    RootModule = 'AppShell.Greeter.psm1'
    ModuleVersion = '0.1.0'
    GUID = '9bf5a496-97ea-46ac-b4a2-99bdc77020ca'
    Author = 'NativeHTMLKit contributors'
    Description = 'An example NativeHTMLKit AppShell PowerShell extension'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-AppShellExtension')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{ Tags = @('AppShell','Extension') }
        AppShell = @{ Id = 'org.nativehtmlkit.examples.greeter'; ApiVersion = 1 }
    }
}
