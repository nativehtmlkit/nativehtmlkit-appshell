@{
    RootModule = 'NativeHTMLKit.AppShell.psm1'
    ModuleVersion = '0.1.0'
    GUID = '05beab97-898f-4ec8-a674-3e164c79472e'
    Author = 'NativeHTMLKit contributors'
    CompanyName = 'NativeHTMLKit'
    Copyright = '(c) NativeHTMLKit contributors'
    Description = 'Native PowerShell AppShell: module extensions, restart activation and recovery. No Python dependency.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Start-AppShell','New-AppShellExtension','Add-AppShellExtension','Get-AppShellExtension',
                          'Enable-AppShellExtension','Disable-AppShellExtension','Remove-AppShellExtension',
                          'Restore-AppShell','Test-AppShell','Invoke-AppShellBoot','Invoke-AppShellWorker')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ Tags=@('NativeHTMLKit','Desktop','PowerShell','Extension');
        LicenseUri='https://opensource.org/licenses/MIT' } }
}
