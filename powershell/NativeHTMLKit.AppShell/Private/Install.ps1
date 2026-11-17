# Installation and boot logic. Never imports third-party modules into AppShell's host runspace.
function Get-AppShellModuleMetadata {
    param([string]$Root)
    $manifests = @(Get-ChildItem -LiteralPath $Root -Filter '*.psd1' -Recurse -File -ErrorAction Stop)
    $matching = @()
    foreach ($item in $manifests) {
        try { $record = Import-PowerShellDataFile -LiteralPath $item.FullName -ErrorAction Stop }
        catch { continue }
        if ($record.PrivateData -and $record.PrivateData.AppShell -and $record.PrivateData.AppShell.Id) {
            $matching += ,@{ file=$item.FullName; meta=$record }
        }
    }
    if ($matching.Count -ne 1) { throw "Expected exactly one AppShell module manifest under $Root; found $($matching.Count)" }
    $entry = $matching[0]
    $id = [string]$entry.meta.PrivateData.AppShell.Id
    Test-AppShellId $id
    $version = [string]$entry.meta.ModuleVersion
    if (-not $version -or $version -notmatch '^\d+(\.\d+){1,3}$') { throw 'Invalid ModuleVersion' }
    if (-not $entry.meta.RootModule) { throw 'Module requires a RootModule' }
    $moduleRoot = Split-Path -Parent $entry.file
    $moduleCode = Join-Path $moduleRoot $entry.meta.RootModule
    if (-not (Test-Path -LiteralPath $moduleCode -PathType Leaf)) { throw 'Module RootModule is missing' }
    return @{ id=$id; version=$version; manifest=$entry.file; root=$moduleRoot }
}
function Get-AppShellWorkerLog {
    param([string]$AppShellHome, [string]$Id)
    return (Join-Path (Join-Path $AppShellHome 'logs') ($Id + '.log'))
}
function Invoke-AppShellRecordWorker {
    # One worker request for an installed registry record.
    param([string]$AppShellHome, [hashtable]$Record, [string]$Operation, [hashtable]$Payload = @{},
          [string]$WorkerFile, [int]$TimeoutMilliseconds = 30000)
    $id = [string]$Record.id
    return (Invoke-AppShellWorker -ModulePath ([string]$Record.module) -ExtensionId $id `
        -DataDirectory (Join-Path (Join-Path $AppShellHome 'extension-data') $id) -Operation $Operation -Payload $Payload `
        -WorkerFile $WorkerFile -TimeoutMilliseconds $TimeoutMilliseconds -ModuleSearchPath ([string]$Record.modules) `
        -LogPath (Get-AppShellWorkerLog $AppShellHome $id))
}
function Install-AppShellCandidate {
    param([Alias('Home')][string]$AppShellHome,[hashtable]$Source,[string]$WorkerFile)
    $token = [guid]::NewGuid().ToString('N')
    $stage = Join-Path (Join-Path $AppShellHome 'releases') ('.candidate-' + $token)
    $null = New-Item -ItemType Directory -Path $stage
    try {
        if ($Source.kind -eq 'local') {
            $inputPath = [IO.Path]::GetFullPath([string]$Source.path)
            $fromIncoming = Join-Path $AppShellHome 'incoming'
            $fromDrop = Join-Path $AppShellHome 'extensions'
            if (-not ($inputPath.StartsWith($fromIncoming + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                       $inputPath.StartsWith($fromDrop + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
                throw 'Local source must reside in AppShell incoming/extensions folder'
            }
            Test-AppShellFileTree $inputPath
            # The copy is the immutable snapshot; it must be exactly what was fingerprinted.
            Copy-Item -LiteralPath $inputPath -Destination (Join-Path $stage 'module') -Recurse -ErrorAction Stop
            if ($Source.fingerprint -and (Get-AppShellFingerprint (Join-Path $stage 'module')) -ne [string]$Source.fingerprint) {
                throw 'Extension folder changed while AppShell copied it; restart to retry'
            }
        } elseif ($Source.kind -eq 'gallery') {
            $name = [string]$Source.name; $version = [string]$Source.version
            if ($name -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,127}$' -or $version -notmatch '^\d+(\.\d+){1,3}$') { throw 'Invalid pinned gallery source' }
            # A registered repository name; PSGallery unless an organisation mirror is configured.
            $repository = if ($env:APPSHELL_PS_REPOSITORY) { $env:APPSHELL_PS_REPOSITORY } else { 'PSGallery' }
            if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
                Save-PSResource -Name $name -Version "[$version]" -Repository $repository -Path $stage -TrustRepository -AcceptLicense -Quiet -ErrorAction Stop
            } elseif (Get-Command Save-Module -ErrorAction SilentlyContinue) {
                Save-Module -Name $name -RequiredVersion $version -Repository $repository -Path $stage -ErrorAction Stop
            } else {
                throw 'PSResourceGet or PowerShellGet is required for gallery extensions'
            }
        } else { throw 'Unsupported extension source type' }
        $metadata = Get-AppShellModuleMetadata $stage
        if ($Source.kind -eq 'gallery' -and $metadata.version -ne [string]$Source.version) {
            throw "Gallery returned version $($metadata.version), expected $($Source.version)"
        }
        $releaseRoot = Join-Path (Join-Path $AppShellHome 'releases') $metadata.id
        $null = New-Item -ItemType Directory -Path $releaseRoot -Force
        $release = Join-Path $releaseRoot $token
        Move-Item -LiteralPath $stage -Destination $release -ErrorAction Stop
        # Only validated releases are kept; resolve the module location after promotion.
        try {
            $newMetadata = Get-AppShellModuleMetadata $release
            $record = @{ id=$metadata.id; version=$metadata.version; release=$release; modules=$release
                         module=$newMetadata.manifest; enabled=$true; source=$Source }
            $check = Invoke-AppShellRecordWorker $AppShellHome $record 'manifest' @{} $WorkerFile 15000
            $manifest = Assert-AppShellManifest $check $metadata.id $metadata.version
        } catch { Remove-Item -LiteralPath $release -Recurse -Force -ErrorAction SilentlyContinue; throw }
        return @{ record=$record; manifest=$manifest }
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force -Recurse } }
}
function Get-AppShellSafeState {
    param([string]$Message, $Registry)
    if ($null -eq $Registry) { $Registry = @{version=1;extensions=@{}} }
    return @{ registry=$Registry; manifests=@{}; status=@{}; errors=@{}; message=$Message; safe_mode=$true; boot_complete=$false }
}
function Invoke-AppShellBoot {
    [CmdletBinding()]
    param([Alias('Home')][string]$AppShellHome,[switch]$SafeMode,[string]$WorkerFile)
    $root = Get-AppShellHome $AppShellHome
    Initialize-AppShellHome $root
    if (-not $WorkerFile) { $WorkerFile = Join-Path $script:AppShellModuleRoot 'AppShell.Worker.ps1' }
    $registryPath = Join-Path $root 'registry.json'
    $pendingPath = Join-Path $root 'pending.json'
    $runningPath = Join-Path $root 'running.json'
    $lastGoodPath = Join-Path $root 'last-good.json'
    $restorePath = Join-Path $root 'restore-on-next-start'
    $status = @{}; $errors = @{}; $manifests = @{}; $message=''
    try {
        if ((Test-Path $runningPath) -or (Test-Path $restorePath)) {
            if (Test-Path $lastGoodPath) {
                $old = Read-AppShellJson $lastGoodPath @{version=1;extensions=@{}}
                if ((Test-Path $runningPath) -and (Test-Path $registryPath)) {
                    $unstable = $null
                    try { $unstable = Read-AppShellJson $registryPath @{version=1;extensions=@{}} } catch { }
                    if ($unstable -and $unstable.extensions -is [System.Collections.IDictionary]) {
                        foreach ($id in @($unstable.extensions.Keys)) {
                            $candidate=$unstable.extensions[$id]
                            $previous=$old.extensions[$id]
                            if ($previous -and $previous.release -eq $candidate.release) { continue }
                            $source=$candidate.source
                            if ($source -and $source.path -and ([string]$source.path).StartsWith((Join-Path $root 'extensions') + [IO.Path]::DirectorySeparatorChar)) {
                                $key='dropin:'+(Split-Path -Leaf ([string]$source.path))+':'+[string]$source.fingerprint
                                Set-AppShellFailure $root $key 'Quarantined after interrupted session; edit folder to retry.'
                            }
                        }
                    }
                }
                Backup-AppShellRegistry $root
                Write-AppShellJson $registryPath $old
                $message='Restored last-known-good configuration after interrupted session or manual request.'
            } else {
                $SafeMode=$true
                $message='No last-good snapshot after interrupted session; safe mode enabled.'
            }
            if (Test-Path $restorePath) { Remove-Item -LiteralPath $restorePath -Force }
        }
        Write-AppShellJson $runningPath @{pid=$PID;started=([DateTime]::UtcNow.ToString('o'))}
        $registry = Read-AppShellJson $registryPath @{version=1;extensions=@{}}
        if ($registry.extensions -isnot [System.Collections.IDictionary]) { throw 'Registry extensions must be object' }
    } catch {
        # Damaged state is never reset silently: the shell stays usable and restore is explicit.
        return (Get-AppShellSafeState ("Startup state error; recovery mode: " + $_.Exception.Message + ' Use Settings > Restore or Restore-AppShell.'))
    }
    if ($SafeMode) {
        return (Get-AppShellSafeState ($message+' Safe mode: no extensions loaded.') $registry)
    }
    try {
        $pending = Read-AppShellJson $pendingPath @{version=1;operations=@()}
        # Clear the queue before performing slow package work; only this boot applies it.
        Invoke-AppShellLocked $root { Write-AppShellJson $pendingPath @{version=1;operations=@()} }
        $failures = (Get-AppShellFailures $root).items
    } catch {
        return (Get-AppShellSafeState ("Startup state error; recovery mode: " + $_.Exception.Message) $registry)
    }
    $adds = @()
    foreach ($op in @($pending.operations)) {
        if ($op.action -eq 'add') { $adds += ,$op; continue }
        $id = [string]$op.id
        if (-not $registry.extensions.ContainsKey($id)) { $errors[$id]='Extension is not installed'; continue }
        switch ($op.action) {
            enable { $registry.extensions[$id].enabled=$true }
            disable { $registry.extensions[$id].enabled=$false }
            remove {
                $path = [string]$registry.extensions[$id].source.path
                if ($path -and $path.StartsWith((Join-Path $root 'extensions') + [IO.Path]::DirectorySeparatorChar)) {
                    $registry.suppressed_dropins = [object[]](@($registry.suppressed_dropins | Where-Object { $_ }) + (Split-Path -Leaf $path))
                }
                $registry.extensions.Remove($id)
            }
            default { $errors[$id]='Unknown pending operation' }
        }
    }
    # A removed drop-in stays suppressed only while its folder exists.
    $present = @(Get-ChildItem -LiteralPath (Join-Path $root 'extensions') -Force | ForEach-Object { $_.Name })
    $registry.suppressed_dropins = [object[]]@(@($registry.suppressed_dropins) | Where-Object { $_ -and $present -contains $_ })
    Write-AppShellJson $registryPath $registry
    $candidates = @()
    foreach ($op in $adds) {
        $source = ConvertTo-AppShellTable $op.source
        if ($source.kind -eq 'gallery') {
            $same = @($registry.extensions.Values | Where-Object { $_.source -and $_.source.kind -eq 'gallery' -and
                $_.source.name -eq $source.name -and $_.source.version -eq $source.version })
            if ($same.Count -gt 0) { continue }   # already installed from the same pinned source
        }
        $candidates += ,@{label=[string]$op.operation_id;source=$source}
    }
    $existing = @{}
    foreach ($id in $registry.extensions.Keys) {
        $src = $registry.extensions[$id].source
        if ($src -and $src.path) { $existing[[string]$src.path]=[string]$src.fingerprint }
    }
    foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path $root 'extensions') -Directory -ErrorAction Stop)) {
        if (@($registry.suppressed_dropins) -contains $folder.Name -or $folder.Name.StartsWith('.')) { continue }
        try {
            $fingerprint = Get-AppShellFingerprint $folder.FullName
            if ($existing[$folder.FullName] -eq $fingerprint) { continue }
            $source = @{kind='local';path=$folder.FullName;fingerprint=$fingerprint}
            $key='dropin:'+$folder.Name+':'+$fingerprint
            if (-not $failures.ContainsKey($key)) {
                $candidates += ,@{label=$folder.Name;source=$source;failureKey=$key}
            }
        } catch { $errors[$folder.Name]=$_.Exception.Message }
    }
    foreach ($candidate in $candidates) {
        $key = $candidate.label
        try {
            $output = Install-AppShellCandidate -Home $root -Source $candidate.source -WorkerFile $WorkerFile
            $id = $output.record.id
            $registry.extensions[$id] = $output.record
            $manifests[$id] = $output.manifest
            $status[$id]='ACTIVE'
            $errors.Remove($id)
            Write-AppShellJson $registryPath $registry
            if ($candidate.failureKey) { Clear-AppShellFailure $root $candidate.failureKey }
            $incoming = Join-Path $root 'incoming'
            if ($candidate.source.kind -eq 'local' -and ([string]$candidate.source.path).StartsWith($incoming + [IO.Path]::DirectorySeparatorChar)) {
                # The staged copy now lives in the release; drop incoming/<token>/.
                Remove-Item -LiteralPath (Split-Path -Parent ([string]$candidate.source.path)) -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {
            $errors[$key]=$_.Exception.Message; $status[$key]='FAILED'
            if ($candidate.failureKey) { Set-AppShellFailure $root $candidate.failureKey $_.Exception.Message }
        }
    }
    foreach ($id in @($registry.extensions.Keys)) {
        if ($registry.extensions[$id].enabled -eq $false) { $status[$id]='DISABLED'; continue }
        if ($manifests.ContainsKey($id)) { continue }
        try {
            $r = $registry.extensions[$id]
            $manifest = Invoke-AppShellRecordWorker $root $r 'manifest' @{} $WorkerFile 15000
            $manifests[$id] = Assert-AppShellManifest $manifest $id $r.version
            $status[$id]='ACTIVE'
        } catch { $errors[$id]=$_.Exception.Message; $status[$id]='FAILED' }
    }
    Write-AppShellJson $registryPath $registry
    return @{ registry=$registry; manifests=$manifests; status=$status;errors=$errors;message=$message;safe_mode=$false;boot_complete=$true }
}
function Complete-AppShellSession {
    param([Alias('Home')][string]$AppShellHome,[switch]$Commit)
    if ($Commit) {
        $registry = Read-AppShellJson (Join-Path $AppShellHome 'registry.json') @{version=1;extensions=@{}}
        Write-AppShellJson (Join-Path $AppShellHome 'last-good.json') $registry
    }
    Remove-Item -LiteralPath (Join-Path $AppShellHome 'running.json') -Force -ErrorAction SilentlyContinue
}
