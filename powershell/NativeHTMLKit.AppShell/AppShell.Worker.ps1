# Standalone worker. Loads only a native PowerShell module; never Python or NativeHTMLKit.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$protocol = [Console]::Out
# Redirect normal Write-Output/Write-Host output as far as PowerShell allows.
try {
    $source = $env:APPSHELL_WORKER_MODULE
    $expectedId = $env:APPSHELL_WORKER_ID
    $dataDir = $env:APPSHELL_WORKER_DATA
    if (-not $source -or -not $expectedId -or -not $dataDir) { throw 'Missing worker launch metadata' }
    $line = [Console]::In.ReadLine()
    if (-not $line -or $line.Length -gt 1100000) { throw 'Invalid worker request size' }
    $request = $line | ConvertFrom-Json -ErrorAction Stop
    $null = New-Item -ItemType Directory -Path $dataDir -Force
    $env:PSModulePath = (Split-Path -Parent $source) + [IO.Path]::PathSeparator + $env:PSModulePath
    $module = Import-Module -Name $source -Force -PassThru -ErrorAction Stop
    $handler = Get-Command -Name 'Invoke-AppShellExtension' -Module $module.Name -ErrorAction Stop
    if (-not $handler) { throw 'Module must export Invoke-AppShellExtension' }
    # All normal output from the extension is captured, not serialized automatically.
    $result = @( & $handler -Operation $request.op -Payload $request.payload -Context $request.context 6>&1 5>&1 4>&1 3>&1 )
    if ($result.Count -ne 1 -or $result[0] -isnot [System.Collections.IDictionary]) {
        throw 'Extension handler must return exactly one hashtable result'
    }
    $payload = @{ok=$true;result=$result[0]} | ConvertTo-Json -Depth 50 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($payload) -gt 1100000) { throw 'Worker result too large' }
    $protocol.WriteLine($payload)
    exit 0
} catch {
    $errorText = [string]$_.Exception.Message
    $errorText = $errorText.Substring(0,[Math]::Min(400,$errorText.Length))
    $protocol.WriteLine((@{ok=$false;error=$errorText} | ConvertTo-Json -Compress))
    exit 1
}
