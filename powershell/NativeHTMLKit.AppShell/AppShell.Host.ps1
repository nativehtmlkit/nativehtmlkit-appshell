param([switch]$SafeMode,[Alias('Home')][string]$AppShellHome)
$ErrorActionPreference='Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'NativeHTMLKit.AppShell.psd1') -Force
Import-Module NativeHTMLKit.UI -ErrorAction Stop
# The SDK re-runs this script as the host's backend. Pass our own options explicitly: when
# Start-AppShell is typed at a prompt, the process command line does not contain them.
$backendArguments = @()
if ($SafeMode) { $backendArguments += '-SafeMode' }
if ($AppShellHome) {
    $backendArguments += '-AppShellHome'
    $backendArguments += $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($AppShellHome)
}
$app = Start-NativeHTMLKitScript -Name 'NativeHTMLKit AppShell' -AppId 'org.nativehtmlkit.AppShell.PowerShell' -ScriptPath $PSCommandPath -ArgumentList $backendArguments
try {
    Start-AppShell -SafeMode:$SafeMode -Home $AppShellHome -Application $app
} finally {
    Close-NativeHTMLKit -Application $app
}
