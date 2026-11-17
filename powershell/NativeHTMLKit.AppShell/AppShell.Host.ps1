param([switch]$SafeMode,[Alias('Home')][string]$AppShellHome)
$ErrorActionPreference='Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'NativeHTMLKit.AppShell.psd1') -Force
Import-Module NativeHTMLKit.UI -ErrorAction Stop
$app = Start-NativeHTMLKitScript -Name 'NativeHTMLKit AppShell' -AppId 'org.nativehtmlkit.AppShell.PowerShell' -ScriptPath $PSCommandPath
try {
    Start-AppShell -SafeMode:$SafeMode -Home $AppShellHome -Application $app
} finally {
    Close-NativeHTMLKit -Application $app
}
