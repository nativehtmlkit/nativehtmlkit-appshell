param([switch]$SafeMode,[Alias('Home')][string]$AppShellHome)
$ErrorActionPreference='Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1') -Force
Start-AppShell -SafeMode:$SafeMode -Home $AppShellHome
