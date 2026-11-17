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
            Copy-Item -LiteralPath $inputPath -Destination (Join-Path $stage 'module') -Recurse -ErrorAction Stop
        } elseif ($Source.kind -eq 'gallery') {
            $name = [string]$Source.name; $version = [string]$Source.version
            if ($name -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,127}$' -or $version -notmatch '^\d+(\.\d+){1,3}$') { throw 'Invalid pinned gallery source' }
            if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
                Save-PSResource -Name $name -Version $version -Repository PSGallery -Path $stage -TrustRepository -AcceptLicense -ErrorAction Stop
            } elseif (Get-Command Save-Module -ErrorAction SilentlyContinue) {
                Save-Module -Name $name -RequiredVersion $version -Repository PSGallery -Path $stage -ErrorAction Stop
            } else {
                throw 'PSResourceGet or PowerShellGet is required for gallery extensions'
            }
        } else { throw 'Unsupported extension source type' }
        $metadata = Get-AppShellModuleMetadata $stage
        $data = Join-Path (Join-Path $AppShellHome 'extension-data') $metadata.id
        $manifest = Invoke-AppShellWorker -ModulePath $metadata.manifest -ExtensionId $metadata.id -DataDirectory $data -Operation 'manifest' -WorkerFile $WorkerFile -TimeoutMilliseconds 15000
        $null = Assert-AppShellManifest $manifest $metadata.id $metadata.version
        $releaseRoot = Join-Path (Join-Path $AppShellHome 'releases') $metadata.id
        $null = New-Item -ItemType Directory -Path $releaseRoot -Force
        $release = Join-Path $releaseRoot $token
        Move-Item -LiteralPath $stage -Destination $release -ErrorAction Stop
        # Re-resolve module location after promotion; never store staging paths.
        $newMetadata = Get-AppShellModuleMetadata $release
        $check = Invoke-AppShellWorker -ModulePath $newMetadata.manifest -ExtensionId $metadata.id -DataDirectory $data -Operation 'manifest' -WorkerFile $WorkerFile -TimeoutMilliseconds 15000
        $null = Assert-AppShellManifest $check $metadata.id $metadata.version
        return @{ record=@{ id=$metadata.id;version=$metadata.version;release=$release;
                             module=$newMetadata.manifest;enabled=$true;source=$Source }; manifest=$check }
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force -Recurse } }
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
    if ((Test-Path $runningPath) -or (Test-Path $restorePath)) {
        if (Test-Path $lastGoodPath) {
            $old = Read-AppShellJson $lastGoodPath @{version=1;extensions=@{}}
            if ((Test-Path $runningPath) -and (Test-Path $registryPath)) {
                $unstable = Read-AppShellJson $registryPath @{version=1;extensions=@{}}
                foreach ($id in @($unstable.extensions.Keys)) {
                    $candidate=$unstable.extensions[$id]
                    $previous=$old.extensions[$id]
                    if ($previous -and $previous.release -eq $candidate.release) { continue }
                    $source=$candidate.source
                    if ($source -and $source.path -and ([string]$source.path).StartsWith((Join-Path $root 'extensions'))) {
                        $key='dropin:'+(Split-Path -Leaf ([string]$source.path))+':'+[string]$source.fingerprint
                        Set-AppShellFailure $root $key 'Quarantined after interrupted session; edit folder to retry.'
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
    if ($registry.extensions -isnot [hashtable]) { throw 'Registry extensions must be object' }
    if ($SafeMode) {
        return @{ registry=$registry; manifests=$manifests; status=$status; errors=$errors;message=($message+' Safe mode: no extensions loaded.');safe_mode=$true }
    }
    $pending = Read-AppShellJson $pendingPath @{version=1;operations=@()}
    # Clear the queue before performing slow package work; only this boot applies it.
    Invoke-AppShellLocked $root { Write-AppShellJson $pendingPath @{version=1;operations=@()} }
    $adds = @()
    foreach ($op in @($pending.operations)) {
        if ($op.action -eq 'add') { $adds += ,$op; continue }
        $id = [string]$op.id
        if (-not $registry.extensions.ContainsKey($id)) { $errors[$id]='Extension is not installed'; continue }
        switch ($op.action) {
            enable { $registry.extensions[$id].enabled=$true }
            disable { $registry.extensions[$id].enabled=$false }
            remove {
                if ($registry.extensions[$id].source.path -and ([string]$registry.extensions[$id].source.path).StartsWith((Join-Path $root 'extensions'))) {
                    if (-not $registry.ContainsKey('suppressed_dropins')) { $registry.suppressed_dropins=@() }
                    $registry.suppressed_dropins += (Split-Path -Leaf ([string]$registry.extensions[$id].source.path))
                }
                $registry.extensions.Remove($id)
            }
            default { $errors[$id]='Unknown pending operation' }
        }
    }
    Write-AppShellJson $registryPath $registry
    $candidates = @()
    foreach ($op in $adds) { $candidates += ,@{label=[string]$op.operation_id;source=(ConvertTo-AppShellTable $op.source)} }
    $existing = @{}
    foreach ($id in $registry.extensions.Keys) {
        $src = $registry.extensions[$id].source
        if ($src -and $src.path) { $existing[[string]$src.path]=[string]$src.fingerprint }
    }
    foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path $root 'extensions') -Directory -ErrorAction Stop)) {
        if ($registry.suppressed_dropins -contains $folder.Name) { continue }
        try {
            $fingerprint = Get-AppShellFingerprint $folder.FullName
            if ($existing[$folder.FullName] -eq $fingerprint) { continue }
            $source = @{kind='local';path=$folder.FullName;fingerprint=$fingerprint}
            $key='dropin:'+$folder.Name+':'+$fingerprint
            if (-not (Get-AppShellFailures $root).items.ContainsKey($key)) {
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
            Write-AppShellJson $registryPath $registry
            if ($candidate.failureKey) { Clear-AppShellFailure $root $candidate.failureKey }
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
            $manifest = Invoke-AppShellWorker -ModulePath $r.module -ExtensionId $id -DataDirectory (Join-Path (Join-Path $root 'extension-data') $id) -Operation manifest -WorkerFile $WorkerFile -TimeoutMilliseconds 15000
            $manifests[$id] = Assert-AppShellManifest $manifest $id $r.version
            $status[$id]='ACTIVE'
        } catch { $errors[$id]=$_.Exception.Message; $status[$id]='FAILED' }
    }
    Write-AppShellJson $registryPath $registry
    return @{ registry=$registry; manifests=$manifests; status=$status;errors=$errors;message=$message;safe_mode=$false }
}
function Complete-AppShellSession {
    param([Alias('Home')][string]$AppShellHome,[switch]$Commit)
    if ($Commit) {
        $registry = Read-AppShellJson (Join-Path $AppShellHome 'registry.json') @{version=1;extensions=@{}}
        Write-AppShellJson (Join-Path $AppShellHome 'last-good.json') $registry
    }
    Remove-Item -LiteralPath (Join-Path $AppShellHome 'running.json') -Force -ErrorAction SilentlyContinue
}
