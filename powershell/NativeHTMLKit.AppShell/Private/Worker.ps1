# Each PowerShell extension request is isolated in a fresh PowerShell process.
# No host runspace is shared with an extension. This intentionally favors reliability
# over process reuse in the first release.
function Invoke-AppShellWorker {
    param([Parameter(Mandatory)][string]$ModulePath,
          [Parameter(Mandatory)][string]$ExtensionId,
          [Parameter(Mandatory)][string]$DataDirectory,
          [Parameter(Mandatory)][string]$Operation,
          [hashtable]$Payload=@{},
          [string]$WorkerFile,
          [int]$TimeoutMilliseconds=30000)
    if (-not $WorkerFile) { $WorkerFile = Join-Path $script:AppShellModuleRoot 'AppShell.Worker.ps1' }
    if (-not (Test-Path -LiteralPath $WorkerFile)) { throw "Missing worker script: $WorkerFile" }
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell.exe' } }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $exe
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + $WorkerFile.Replace('"','') + '"'
    $start.CreateNoWindow = $true
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['APPSHELL_WORKER_MODULE'] = $ModulePath
    $start.EnvironmentVariables['APPSHELL_WORKER_ID'] = $ExtensionId
    $start.EnvironmentVariables['APPSHELL_WORKER_DATA'] = $DataDirectory
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Worker process did not start' }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $msg = @{ op=$Operation; payload=$Payload; context=@{ data_dir=$DataDirectory; extension_id=$ExtensionId; app_version='0.1.0' } }
        $request = $msg | ConvertTo-Json -Depth 50 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($request) -gt 65536) { throw 'Worker request too large' }
        $process.StandardInput.WriteLine($request)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            throw "TIMEOUT: PowerShell worker exceeded $TimeoutMilliseconds ms; outcome may be unknown"
        }
        $out = $stdoutTask.Result
        $err = $stderrTask.Result
        if ($out.Length -gt 1100000) { throw 'Worker output exceeds frame limit' }
        $lines = @($out -split "`n" | Where-Object { $_.Trim() })
        if ($lines.Count -ne 1) { throw 'Invalid worker output: expected exactly one JSON response line' }
        try { $response = $lines[0] | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'Malformed worker response (possible stdout contamination)' }
        if ($response.ok -ne $true) {
            $reason = if ($response.error) { [string]$response.error } else { 'Unknown extension worker error' }
            throw "EXTENSION_ERROR: $reason"
        }
        if ($process.ExitCode -ne 0) { throw "Worker exited with $($process.ExitCode): $($err.Substring(0,[Math]::Min($err.Length, 300)))" }
        return (ConvertTo-AppShellTable $response.result)
    } finally {
        if ($started -and -not $process.HasExited) { try { $process.Kill() } catch {} }
        $process.Dispose()
    }
}
