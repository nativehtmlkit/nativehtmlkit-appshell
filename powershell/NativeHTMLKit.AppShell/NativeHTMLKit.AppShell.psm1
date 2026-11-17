# Version 1 (uninitialised variables). Version 2+ throws on optional hashtable keys read with dot syntax,
# which the v1 contract uses for every optional field.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$script:AppShellModuleRoot = $PSScriptRoot
$script:AppShellVersion = '0.1.0'
foreach ($file in @('Storage.ps1','Contract.ps1','Worker.ps1','Install.ps1','Scaffold.ps1','Shell.ps1')) {
    . (Join-Path $PSScriptRoot ('Private/' + $file))
}
Export-ModuleMember -Function @('Start-AppShell','New-AppShellExtension','Add-AppShellExtension','Get-AppShellExtension',
    'Enable-AppShellExtension','Disable-AppShellExtension','Remove-AppShellExtension',
    'Restore-AppShell','Test-AppShell','Invoke-AppShellBoot','Invoke-AppShellWorker')
