# PS 5.1 and PS 7 compatible storage. No dependency on Python.
function Resolve-AppShellUserPath {
    # Relative to the PowerShell location ($PWD), not the process directory that
    # [IO.Path]::GetFullPath uses (Set-Location does not change the latter).
    param([string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}
function Get-AppShellHome {
    param([Alias('Home')][string]$AppShellHome)
    if ($AppShellHome) { return (Resolve-AppShellUserPath ([Environment]::ExpandEnvironmentVariables($AppShellHome))) }
    if ($env:APPSHELL_HOME) { return (Resolve-AppShellUserPath $env:APPSHELL_HOME) }
    if ($env:LOCALAPPDATA -and $env:OS -eq 'Windows_NT') {
        return (Join-Path $env:LOCALAPPDATA 'NativeHTMLKit/AppShell/PowerShell')
    }
    if ($env:XDG_DATA_HOME) { return (Join-Path $env:XDG_DATA_HOME 'nativehtmlkit/appshell/powershell') }
    return (Join-Path $HOME '.local/share/nativehtmlkit/appshell/powershell')
}
function Initialize-AppShellHome {
    param([Alias('Home')][string]$AppShellHome)
    foreach ($part in @('','extensions','incoming','releases','extension-data','logs')) {
        $path = if ($part) { Join-Path $AppShellHome $part } else { $AppShellHome }
        if (-not (Test-Path -LiteralPath $path)) { $null = New-Item -ItemType Directory -Path $path -Force }
    }
}
function ConvertTo-AppShellTable {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[[string]$key] = Get-AppShellBaseObject (ConvertTo-AppShellTable $Value[$key]) }
        return ,$result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($p in $Value.PSObject.Properties) { $result[$p.Name] = Get-AppShellBaseObject (ConvertTo-AppShellTable $p.Value) }
        return ,$result
    }
    if ($Value -is [Array] -or $Value -is [System.Collections.IList]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$items.Add((Get-AppShellBaseObject (ConvertTo-AppShellTable $item))) }
        return ,($items.ToArray())
    }
    return $Value
}
function Get-AppShellBaseObject {
    # Arrays returned through the pipeline arrive PSObject-wrapped; Windows PowerShell 5.1's
    # ConvertTo-Json then writes them as {"value":[...],"Count":n}. Store the bare object.
    param($Value)
    if ($null -eq $Value) { return $null }
    return ,($Value.PSObject.BaseObject)
}
function Read-AppShellJson {
    param([string]$Path, [hashtable]$Default)
    if (-not (Test-Path -LiteralPath $Path)) { return (ConvertTo-AppShellTable $Default) }
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -gt 2MB) { throw "State too large: $Path" }
    try {
        $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $value = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($value -isnot [PSCustomObject]) { throw 'Expected object' }
        return (ConvertTo-AppShellTable $value)
    } catch { throw "Invalid AppShell state $Path`: $($_.Exception.Message)" }
}
function Write-AppShellJson {
    param([string]$Path, [hashtable]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path $parent)) { $null = New-Item -ItemType Directory $parent -Force }
    $tmp = Join-Path $parent ('.appshell-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 64
        [IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) {
            # Replace is atomic on a single filesystem and is supported on .NET Framework 4.7+.
            [IO.File]::Replace($tmp, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($tmp, $Path)
        }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}
function Invoke-AppShellLocked {
    param([Alias('Home')][string]$AppShellHome, [scriptblock]$ScriptBlock)
    $path = Join-Path $AppShellHome '.state.lock'
    $lock = $null
    for ($try = 0; $try -lt 50; $try++) {
        try {
            $lock = (New-Object -TypeName System.IO.FileStream -ArgumentList @($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
            break
        } catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
    }
    if ($null -eq $lock) { throw 'AppShell state busy; retry shortly' }
    try { & $ScriptBlock } finally { $lock.Dispose() }
}
function Enter-AppShellSession {
    # Held by the desktop for its whole lifetime; the OS releases it if the process dies.
    param([string]$AppShellHome)
    $path = Join-Path $AppShellHome '.session.lock'
    try {
        return (New-Object -TypeName System.IO.FileStream -ArgumentList @($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
    } catch [IO.IOException] {
        throw "AppShell is already running with this home: $AppShellHome"
    }
}
function Test-AppShellSessionActive {
    param([string]$AppShellHome)
    $path = Join-Path $AppShellHome '.session.lock'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try { (Enter-AppShellSession $AppShellHome).Dispose(); return $false } catch { return $true }
}
function Add-AppShellQueue {
    param([Alias('Home')][string]$AppShellHome,[hashtable]$Operation)
    Initialize-AppShellHome $AppShellHome
    Invoke-AppShellLocked $AppShellHome {
        $path = Join-Path $AppShellHome 'pending.json'
        $state = Read-AppShellJson $path @{ version=1; operations=@() }
        $state.operations = [object[]](@($state.operations) + @($Operation))
        Write-AppShellJson $path $state
    }
}
function Test-AppShellId {
    param([string]$Id)
    if ($Id.Length -gt 140 -or $Id -cnotmatch '^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9-]*)+$') {
        throw "Invalid reverse-domain extension ID: $Id"
    }
}
function Test-AppShellFileTree {
    param([string]$Path)
    $rootItem=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Source root is a reparse point/symlink' }
    $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)
    if ($items.Count -gt 2500) { throw 'Module source contains over 2500 files' }
    $total = [long]0
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point/symlink rejected: $($item.FullName)" }
        if (-not $item.PSIsContainer) { $total += [long]$item.Length }
        if ($total -gt 128MB) { throw 'Module source exceeds 128MiB' }
    }
}
function Backup-AppShellRegistry {
    param([string]$AppShellHome)
    $source=Join-Path $AppShellHome 'registry.json'
    if (-not (Test-Path -LiteralPath $source)) { return }
    $dir=Join-Path $AppShellHome 'backups'
    $null=New-Item -ItemType Directory -Path $dir -Force
    $name='registry-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N')+'.json'
    Copy-Item -LiteralPath $source -Destination (Join-Path $dir $name) -ErrorAction Stop
}
function Get-AppShellFailures {
    param([string]$AppShellHome)
    return (Read-AppShellJson (Join-Path $AppShellHome 'failed-candidates.json') @{ items=@{} })
}
function Set-AppShellFailure {
    param([string]$AppShellHome,[string]$Key,[string]$Message)
    $state=Get-AppShellFailures $AppShellHome
    $state.items[$Key]=$Message.Substring(0,[Math]::Min(500,$Message.Length))
    Write-AppShellJson (Join-Path $AppShellHome 'failed-candidates.json') $state
}
function Clear-AppShellFailure {
    param([string]$AppShellHome,[string]$Key)
    $state=Get-AppShellFailures $AppShellHome
    $state.items.Remove($Key)
    Write-AppShellJson (Join-Path $AppShellHome 'failed-candidates.json') $state
}
function Get-AppShellFingerprint {
    param([string]$Path)
    Test-AppShellFileTree $Path
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $items = @(Get-ChildItem -LiteralPath $Path -File -Recurse | Sort-Object FullName)
        $bytes = New-Object IO.MemoryStream
        foreach ($item in $items) {
            $relative = $item.FullName.Substring($Path.TrimEnd([char[]]@('/', '\')).Length).Replace('\','/')
            $info = [Text.Encoding]::UTF8.GetBytes($relative)
            $bytes.Write($info,0,$info.Length)
            $file = [IO.File]::OpenRead($item.FullName)
            try { $file.CopyTo($bytes) } finally { $file.Dispose() }
        }
        $bytes.Position = 0
        return (([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant())
    } finally { $sha.Dispose() }
}
function Add-AppShellExtension {
    [CmdletBinding(DefaultParameterSetName='Local')]
    param([Parameter(ParameterSetName='Local', Mandatory)][string]$SourcePath,
          [Parameter(ParameterSetName='Gallery', Mandatory)][string]$Name,
          [Parameter(ParameterSetName='Gallery', Mandatory)][string]$RequiredVersion,
          [Alias('Home')][string]$AppShellHome)
    $root = Get-AppShellHome $AppShellHome
    Initialize-AppShellHome $root
    if ($PSCmdlet.ParameterSetName -eq 'Local') {
        $path = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'PowerShell local extension must be a module directory' }
        $before = Get-AppShellFingerprint $path   # also rejects reparse points and oversized trees
        $target = Join-Path (Join-Path $root 'incoming') ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $target
        $copy = Join-Path $target 'module'
        try {
            Copy-Item -LiteralPath $path -Destination $copy -Recurse -ErrorAction Stop
            if ((Get-AppShellFingerprint $copy) -ne $before) { throw 'Module source changed while it was copied; try again' }
        } catch { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue; throw }
        $source = @{ kind='local'; path=$copy; fingerprint=$before }
    } else {
        if ($Name -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,127}$' -or
            $RequiredVersion -notmatch '^\d+(\.\d+){1,3}$') { throw 'Require exact gallery module name and version (for example 1.2.3)' }
        $source = @{ kind='gallery'; name=$Name; version=$RequiredVersion }
    }
    Add-AppShellQueue $root @{ action='add'; source=$source; operation_id=[guid]::NewGuid().ToString('N') }
    return 'Queued extension; restart AppShell to install and activate.'
}
function Get-AppShellExtension {
    param([Alias('Home')][string]$AppShellHome)
    $root = Get-AppShellHome $AppShellHome
    Initialize-AppShellHome $root
    $registry = Read-AppShellJson (Join-Path $root 'registry.json') @{version=1;extensions=@{}}
    foreach ($key in @($registry.extensions.Keys | Sort-Object)) {
        $item = $registry.extensions[$key]
        [pscustomobject]@{ Id=$key; Version=$item.version; Enabled=($item.enabled -ne $false); Release=$item.release }
    }
}
function Enable-AppShellExtension { param([Parameter(Mandatory)][string]$Id,[Alias('Home')][string]$AppShellHome)
    Test-AppShellId $Id; Add-AppShellQueue (Get-AppShellHome $AppShellHome) @{action='enable';id=$Id}
}
function Disable-AppShellExtension { param([Parameter(Mandatory)][string]$Id,[Alias('Home')][string]$AppShellHome)
    Test-AppShellId $Id; Add-AppShellQueue (Get-AppShellHome $AppShellHome) @{action='disable';id=$Id}
}
function Remove-AppShellExtension { param([Parameter(Mandatory)][string]$Id,[Alias('Home')][string]$AppShellHome)
    Test-AppShellId $Id; Add-AppShellQueue (Get-AppShellHome $AppShellHome) @{action='remove';id=$Id}
}
function Restore-AppShell { param([Alias('Home')][string]$AppShellHome)
    $root = Get-AppShellHome $AppShellHome
    if (Test-AppShellSessionActive $root) { throw 'Close AppShell before restoring' }
    $snapshot = Read-AppShellJson (Join-Path $root 'last-good.json') @{}
    if (-not $snapshot.ContainsKey('extensions')) { throw 'No valid last-known-good snapshot' }
    Backup-AppShellRegistry $root
    Write-AppShellJson (Join-Path $root 'registry.json') $snapshot
    # Explicit restore: a stale marker from a crash must not trigger another automatic one.
    Remove-Item -LiteralPath (Join-Path $root 'running.json') -Force -ErrorAction SilentlyContinue
    return 'Restored last-known-good configuration; extension data unchanged.'
}
function Test-AppShell { param([Alias('Home')][string]$AppShellHome)
    $root = Get-AppShellHome $AppShellHome
    Initialize-AppShellHome $root
    $issues = @()
    $count = 0; $pendingCount = 0
    try {
        $reg = Read-AppShellJson (Join-Path $root 'registry.json') @{version=1;extensions=@{}}
        if ($reg.extensions -isnot [System.Collections.IDictionary]) { throw 'registry extensions must be an object' }
        $count = $reg.extensions.Count
        foreach ($id in @($reg.extensions.Keys)) {
            try { Test-AppShellId $id } catch { $issues += $_.Exception.Message }
            $release = [string]$reg.extensions[$id].release
            if (-not $release -or -not (Test-Path -LiteralPath $release)) { $issues += "Missing release: $id" }
        }
    } catch { $issues += $_.Exception.Message }
    try { $pendingCount = @((Read-AppShellJson (Join-Path $root 'pending.json') @{operations=@()}).operations).Count }
    catch { $issues += $_.Exception.Message }
    $running = Test-AppShellSessionActive $root
    [pscustomobject]@{ Home=$root; Extensions=$count; Pending=$pendingCount; Running=$running
        UncleanMarker=((Test-Path -LiteralPath (Join-Path $root 'running.json')) -and -not $running); Issues=$issues }
}
