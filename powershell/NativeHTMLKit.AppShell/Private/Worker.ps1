# Each PowerShell extension request is isolated in a fresh PowerShell process.
# No host runspace is shared with an extension. This intentionally favors reliability
# over process reuse in the first release. See AppShell.Worker.ps1 for the private channel.
$script:AppShellWorkerOutputLimit = 1MB   # incidental stdout+stderr kept per request
$script:AppShellLogRotateBytes = 2MB

function ConvertTo-AppShellAsciiJson {
    # \u-escape every non-ASCII UTF-16 unit: valid JSON, independent of console code pages.
    param([string]$Json)
    $builder = New-Object Text.StringBuilder ($Json.Length + 16)
    foreach ($ch in $Json.ToCharArray()) {
        if ([int]$ch -lt 128) { [void]$builder.Append($ch) }
        else { [void]$builder.Append('\u').Append(([int]$ch).ToString('x4')) }
    }
    return $builder.ToString()
}

function ConvertTo-AppShellProcessArgument {
    # Windows CommandLineToArgvW quoting for .NET Framework (no ProcessStartInfo.ArgumentList).
    param([string]$Value)
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $result = '"'
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { $result += ('\' * (2 * $slashes + 1)) + '"' }
        else { $result += ('\' * $slashes) + $ch }
        $slashes = 0
    }
    return $result + ('\' * (2 * $slashes)) + '"'
}

function Get-AppShellPowerShellPath {
    $exe = $null
    try { $exe = (Get-Process -Id $PID).Path } catch { }
    if (-not $exe) {
        $name = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell.exe' }
        $exe = Join-Path $PSHOME $name
        if ($PSVersionTable.PSVersion.Major -ge 6 -and $env:OS -eq 'Windows_NT') { $exe += '.exe' }
    }
    return $exe
}

function Write-AppShellWorkerLog {
    param([string]$LogPath, [string]$Header, [string]$Text)
    if (-not $LogPath -or -not $Text) { return }
    try {
        $parent = Split-Path -Parent $LogPath
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt $script:AppShellLogRotateBytes) {
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.1') -Force
        }
        [IO.File]::AppendAllText($LogPath, $Header + [Environment]::NewLine + $Text + [Environment]::NewLine,
            (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Stop-AppShellProcessTree {
    param([Diagnostics.Process]$Process)
    try { if ($Process.HasExited) { return } } catch { return }
    $killed = $false
    try { $Process.Kill($true); $killed = $true } catch { }   # .NET Core 3+: whole tree
    if (-not $killed -and $env:OS -eq 'Windows_NT') {
        try { $null = & "$env:SystemRoot\System32\taskkill.exe" /PID $Process.Id /T /F 2>&1; $killed = $true } catch { }
    }
    if (-not $killed) { try { $Process.Kill() } catch { } }
    try { $null = $Process.WaitForExit(5000) } catch { }
}

function Invoke-AppShellWorker {
    param([Parameter(Mandatory)][string]$ModulePath,
          [Parameter(Mandatory)][string]$ExtensionId,
          [Parameter(Mandatory)][string]$DataDirectory,
          [Parameter(Mandatory)][string]$Operation,
          [hashtable]$Payload=@{},
          [string]$WorkerFile,
          [int]$TimeoutMilliseconds=30000,
          [string]$ModuleSearchPath,
          [string]$LogPath)
    if (-not $WorkerFile) { $WorkerFile = Join-Path $script:AppShellModuleRoot 'AppShell.Worker.ps1' }
    if (-not (Test-Path -LiteralPath $WorkerFile)) { throw "Missing worker script: $WorkerFile" }
    $msg = @{ op=$Operation; payload=$Payload; context=@{ data_dir=$DataDirectory; extension_id=$ExtensionId; app_version=$script:AppShellVersion } }
    $request = ConvertTo-AppShellAsciiJson (ConvertTo-Json -InputObject $msg -Depth 50 -Compress)
    if ($request.Length -gt 65536) { throw 'Worker request too large' }
    $exchange = Join-Path ([IO.Path]::GetTempPath()) ('appshell-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $exchange
    $responsePath = Join-Path $exchange 'response.json'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Get-AppShellPowerShellPath
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $WorkerFile)
    if ($null -ne $start.GetType().GetProperty('ArgumentList')) {
        foreach ($a in $arguments) { $start.ArgumentList.Add($a) }   # PowerShell 7: no quoting rules
    } else {
        $start.Arguments = (@($arguments | ForEach-Object { ConvertTo-AppShellProcessArgument $_ }) -join ' ')
    }
    $start.CreateNoWindow = $true
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $start.WorkingDirectory = $exchange
    $start.EnvironmentVariables['APPSHELL_WORKER_MODULE'] = $ModulePath
    $start.EnvironmentVariables['APPSHELL_WORKER_MODULES'] = $(if ($ModuleSearchPath) { $ModuleSearchPath } else { Split-Path -Parent $ModulePath })
    $start.EnvironmentVariables['APPSHELL_WORKER_ID'] = $ExtensionId
    $start.EnvironmentVariables['APPSHELL_WORKER_DATA'] = $DataDirectory
    $start.EnvironmentVariables['APPSHELL_WORKER_RESPONSE'] = $responsePath
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $started = $false
    $incidental = New-Object Text.StringBuilder
    $dropped = [long]0
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Worker process did not start' }
        $process.StandardInput.WriteLine($request)
        $process.StandardInput.Close()
        # Drain both pipes with a bound so a chatty extension neither blocks nor exhausts memory.
        $readers = @($process.StandardOutput, $process.StandardError)
        $buffers = @((New-Object char[] 8192), (New-Object char[] 8192))
        $pending = @($readers[0].ReadAsync($buffers[0], 0, 8192), $readers[1].ReadAsync($buffers[1], 0, 8192))
        $open = 2
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $timedOut = $false
        while ($open -gt 0) {
            $remaining = $TimeoutMilliseconds - $clock.ElapsedMilliseconds
            if ($remaining -le 0) { $timedOut = $true; break }
            $active = @($pending | Where-Object { $null -ne $_ })
            $index = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]$active, [int][Math]::Min($remaining, 250))
            if ($index -lt 0) { continue }
            for ($i = 0; $i -lt 2; $i++) {
                $task = $pending[$i]
                if ($null -eq $task -or -not $task.IsCompleted) { continue }
                $count = 0
                try { $count = $task.Result } catch { }
                if ($count -le 0) { $pending[$i] = $null; $open--; continue }
                $room = $script:AppShellWorkerOutputLimit - $incidental.Length
                if ($room -gt 0) { [void]$incidental.Append($buffers[$i], 0, [Math]::Min($count, $room)) }
                if ($count -gt $room) { $dropped += ($count - [Math]::Max($room, 0)) }
                $pending[$i] = $readers[$i].ReadAsync($buffers[$i], 0, 8192)
            }
        }
        if (-not $timedOut) {
            $left = [int][Math]::Max(1, $TimeoutMilliseconds - $clock.ElapsedMilliseconds)
            if (-not $process.WaitForExit($left)) { $timedOut = $true }
        }
        if ($timedOut) {
            Stop-AppShellProcessTree $process
            throw "TIMEOUT: PowerShell worker exceeded $TimeoutMilliseconds ms; outcome may be unknown"
        }
        $process.WaitForExit()
        if (-not (Test-Path -LiteralPath $responsePath -PathType Leaf)) {
            throw "Worker exited with $($process.ExitCode) without a response; outcome may be unknown"
        }
        if ((Get-Item -LiteralPath $responsePath).Length -gt 1100000) { throw 'Worker output exceeds frame limit' }
        try {
            $response = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($responsePath, (New-Object Text.UTF8Encoding($false, $true)))) -ErrorAction Stop
        } catch { throw 'Malformed worker response' }
        if ($response.ok -ne $true) {
            $reason = if ($response.error) { [string]$response.error } else { 'Unknown extension worker error' }
            throw "EXTENSION_ERROR: $reason"
        }
        if ($process.ExitCode -ne 0) { throw "Worker exited with $($process.ExitCode) after replying; outcome may be unknown" }
        return (ConvertTo-AppShellTable $response.result)
    } finally {
        if ($started) { Stop-AppShellProcessTree $process }
        if ($dropped -gt 0) { [void]$incidental.Append("`n[appshell: $dropped characters of worker output discarded]") }
        if ($incidental.Length -gt 0) {
            Write-AppShellWorkerLog $LogPath ('--- ' + [DateTime]::UtcNow.ToString('o') + " $Operation") $incidental.ToString()
        }
        $process.Dispose()
        Remove-Item -LiteralPath $exchange -Recurse -Force -ErrorAction SilentlyContinue
    }
}
