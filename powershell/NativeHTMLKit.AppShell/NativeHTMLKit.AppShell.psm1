Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:AppShellModuleRoot = $PSScriptRoot
foreach ($file in @('Storage.ps1','Contract.ps1','Worker.ps1','Install.ps1','Scaffold.ps1','Shell.ps1')) {
    . (Join-Path $PSScriptRoot ('Private/' + $file))
}
Export-ModuleMember -Function @('Start-AppShell','New-AppShellExtension','Add-AppShellExtension','Get-AppShellExtension',
    'Enable-AppShellExtension','Disable-AppShellExtension','Remove-AppShellExtension',
    'Restore-AppShell','Test-AppShell','Invoke-AppShellBoot','Invoke-AppShellWorker')
