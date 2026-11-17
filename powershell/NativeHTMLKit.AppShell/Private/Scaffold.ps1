function New-AppShellExtension {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id,
          [Parameter(Mandatory)][string]$OutputPath,
          [string]$Title)
    Test-AppShellId $Id
    $root = Resolve-AppShellUserPath $OutputPath
    if (Test-Path -LiteralPath $root) { throw "Destination already exists: $root" }
    $short = ($Id -split '\.')[-1]
    $titleValue = if ($Title) { $Title.Trim() } else { (Get-Culture).TextInfo.ToTitleCase($short.Replace('-',' ')) }
    if (-not $titleValue -or $titleValue.Length -gt 120 -or $titleValue -match '[\x00-\x1F]') { throw 'Invalid extension title' }
    # Join-String is PS7-only: use compatible string operation instead.
    $parts = @($short.Split('-'))
    $moduleName = 'AppShell.' + (($parts | ForEach-Object { (Get-Culture).TextInfo.ToTitleCase($_) }) -join '')
    $guid = [guid]::NewGuid().ToString()
    # Single-quoted PowerShell literals: double embedded quotes once, before templating.
    $safeTitle = $titleValue.Replace("'", "''")
    $null = New-Item -ItemType Directory -Path $root
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'tests')
    $manifest = @"
@{
    RootModule = '$moduleName.psm1'
    ModuleVersion = '0.1.0'
    GUID = '$guid'
    Author = 'AppShell extension author'
    Description = '$safeTitle for NativeHTMLKit AppShell'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-AppShellExtension')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{ Tags = @('AppShell','Extension') }
        AppShell = @{ Id = '$Id'; ApiVersion = 1 }
    }
}
"@
    $code = @'
# Plain PowerShell module. No Python or NativeHTMLKit import is necessary.
$ErrorActionPreference = 'Stop'
function Invoke-AppShellExtension {
    param([Parameter(Mandatory)][string]$Operation,
          $Payload,
          $Context)
    $file = Join-Path $Context.data_dir 'message.txt'
    switch ($Operation) {
        'manifest' { return @{
            api_version = 1; id = '__ID__'; title = '__TITLE__'; version = '0.1.0'
            pages = @(@{ id = 'overview'; title = 'Overview'; order = 10 })
            commands = @(
                @{ id = 'refresh'; title = 'Refresh'; risk = 'read' },
                @{ id = 'save'; title = 'Save text'; risk = 'write';
                   confirmation = 'Save this value to the extension data folder?' }
            )
        } }
        'page' {
            if ($Payload.page_id -ne 'overview') { throw 'Unknown page' }
            $message = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw } else { 'Hello from PowerShell.' }
            return @{
                title = '__TITLE__'
                blocks = @(
                    @{ kind = 'heading'; text = '__TITLE__'; level = 2 },
                    @{ kind = 'text'; text = 'Native PowerShell module extension.' },
                    @{ kind = 'input'; name = 'message'; label = 'Message'; value = [string]$message },
                    @{ kind = 'row'; children = @(
                        @{ kind = 'button'; text = 'Refresh'; command = 'refresh' },
                        @{ kind = 'button'; text = 'Save'; command = 'save' }
                    ) }
                )
            }
        }
        'action' {
            switch ($Payload.command_id) {
                'refresh' { return @{ message = 'Refreshed'; refresh = $true } }
                'save' {
                    $null = New-Item -ItemType Directory -Path $Context.data_dir -Force
                    $value = [string]$Payload.values.message
                    if ($value.Length -gt 10000) { throw 'Value too long' }
                    [IO.File]::WriteAllText($file,$value,(New-Object Text.UTF8Encoding($false)))
                    return @{ message = 'Saved'; refresh = $true }
                }
                default { throw 'Unknown command' }
            }
        }
        'shutdown' { return @{ closed = $true } }
        default { throw 'Unknown operation' }
    }
}
Export-ModuleMember -Function Invoke-AppShellExtension
'@
    $code = $code.Replace('__ID__', $Id).Replace('__TITLE__', $safeTitle)
    # UTF-8 WITH BOM: Windows PowerShell 5.1 reads BOM-less scripts as ANSI (non-ASCII titles).
    $scriptEncoding = New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText((Join-Path $root ($moduleName + '.psd1')), $manifest, $scriptEncoding)
    [IO.File]::WriteAllText((Join-Path $root ($moduleName + '.psm1')), $code, $scriptEncoding)
    $tests = @"
# Requires Pester 5. Run Invoke-Pester from this directory.
Describe '$Id extension' {
    BeforeAll { Import-Module (Join-Path `$PSScriptRoot '../$moduleName.psd1') -Force }
    It 'has a valid v1 manifest' {
        `$context = @{ data_dir = `$TestDrive; extension_id = '$Id'; app_version = '0.1.0' }
        `$result = Invoke-AppShellExtension -Operation manifest -Payload @{} -Context `$context
        `$result.api_version | Should -Be 1
        `$result.id | Should -Be '$Id'
    }
}
"@
    [IO.File]::WriteAllText((Join-Path $root 'tests/Extension.Tests.ps1'),$tests,$scriptEncoding)
    [IO.File]::WriteAllText((Join-Path $root 'README.md'),("# " + $titleValue + "`n`n" +
        'This is a native PowerShell module extension. Copy its directory under the AppShell ' +
        '`extensions/` folder, restart, and it appears in navigation.' + "`n`n" +
        'No Python or NativeHTMLKit imports are necessary. Keep the module manifest and extension manifest versions in sync.' + "`n"),
        (New-Object Text.UTF8Encoding($false)))
    return $root
}
