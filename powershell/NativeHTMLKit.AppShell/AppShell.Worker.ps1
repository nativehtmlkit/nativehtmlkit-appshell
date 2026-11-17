# Standalone worker. Loads only a native PowerShell module; never Python or NativeHTMLKit.
#
# Private channel (not part of the extension contract):
#   request  - one JSON line on stdin, ASCII only (non-ASCII is \u-escaped by the parent), so the
#              console code page of Windows PowerShell 5.1 cannot corrupt it;
#   response - one UTF-8 JSON document written to the file named by APPSHELL_WORKER_RESPONSE
#              (temporary name, then renamed), so nothing the extension prints can corrupt it;
#   stdout/stderr - incidental output only (Write-Host, warnings, native commands, [Console]),
#              drained with a size bound by the parent and appended to the extension log.
$ErrorActionPreference = 'Stop'
$global:ProgressPreference = 'SilentlyContinue'
$responsePath = $env:APPSHELL_WORKER_RESPONSE

function Write-AppShellWorkerResponse {
    param([System.Collections.IDictionary]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 64 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 1100000) {
        $json = ConvertTo-Json -InputObject @{ ok = $false; error = 'Worker result too large' } -Compress
    }
    $temporary = $responsePath + '.tmp'
    [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $responsePath -Force
}

function Format-AppShellWorkerRecord {
    param($Item)
    if ($Item -is [System.Management.Automation.ErrorRecord]) { return 'ERROR: ' + $Item.ToString() }
    if ($Item -is [System.Management.Automation.WarningRecord]) { return 'WARNING: ' + $Item.Message }
    if ($Item -is [System.Management.Automation.VerboseRecord]) { return 'VERBOSE: ' + $Item.Message }
    if ($Item -is [System.Management.Automation.DebugRecord]) { return 'DEBUG: ' + $Item.Message }
    if ($Item -is [System.Management.Automation.InformationRecord]) { return 'INFO: ' + [string]$Item.MessageData }
    return $null
}

if (-not $responsePath) { [Console]::Error.WriteLine('Missing APPSHELL_WORKER_RESPONSE'); exit 2 }
try {
    $source = $env:APPSHELL_WORKER_MODULE
    $expectedId = $env:APPSHELL_WORKER_ID
    $dataDir = $env:APPSHELL_WORKER_DATA
    if (-not $source -or -not $expectedId -or -not $dataDir) { throw 'Missing worker launch metadata' }
    $line = [Console]::In.ReadLine()
    if (-not $line -or $line.Length -gt 1100000) { throw 'Invalid worker request size' }
    $request = ConvertFrom-Json -InputObject $line -ErrorAction Stop
    # [Console]::WriteLine from the extension goes to the log, not to a protocol stream.
    [Console]::SetOut([Console]::Error)
    $null = New-Item -ItemType Directory -Path $dataDir -Force
    $modules = if ($env:APPSHELL_WORKER_MODULES) { $env:APPSHELL_WORKER_MODULES } else { Split-Path -Parent $source }
    $env:PSModulePath = $modules + [IO.Path]::PathSeparator + $env:PSModulePath
    $module = Import-Module -Name $source -Force -PassThru -ErrorAction Stop
    $handler = Get-Command -Name 'Invoke-AppShellExtension' -Module $module.Name -ErrorAction SilentlyContinue
    if (-not $handler) { throw 'Module must export Invoke-AppShellExtension' }
    $results = New-Object System.Collections.ArrayList
    # Extension code runs with PowerShell's default error semantics: Write-Error is logged,
    # throw (or -ErrorAction Stop) fails the request.
    $ErrorActionPreference = 'Continue'
    $output = @(& $handler -Operation $request.op -Payload $request.payload -Context $request.context *>&1)
    $ErrorActionPreference = 'Stop'
    # Every stream is captured here; only dictionaries/PSCustomObjects count as the result.
    foreach ($item in $output) {
        $note = Format-AppShellWorkerRecord $item
        if ($null -ne $note) { [Console]::Error.WriteLine($note); continue }
        if ($item -is [System.Collections.IDictionary] -or $item -is [System.Management.Automation.PSCustomObject]) {
            [void]$results.Add($item)
        } elseif ($null -ne $item) {
            [Console]::Error.WriteLine('OUTPUT: ' + [string]$item)
        }
    }
    if ($results.Count -eq 0 -and $request.op -in @('action', 'shutdown')) { [void]$results.Add(@{}) }
    if ($results.Count -ne 1) {
        throw "Extension handler must return exactly one hashtable or PSCustomObject result (returned $($results.Count))"
    }
    Write-AppShellWorkerResponse @{ ok = $true; result = $results[0] }
    exit 0
} catch {
    $errorText = [string]$_.Exception.Message
    $errorText = $errorText.Substring(0, [Math]::Min(400, $errorText.Length))
    try { Write-AppShellWorkerResponse @{ ok = $false; error = $errorText } } catch { [Console]::Error.WriteLine($errorText) }
    exit 1
}
