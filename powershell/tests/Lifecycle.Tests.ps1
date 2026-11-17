# Extension lifecycle, worker isolation and failure paths. Pester 5; PowerShell 7 and Windows PowerShell 5.1.
# Real worker processes and disposable AppShell homes under $TestDrive. No native GUI.
BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '../NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1'
    Import-Module $script:ModuleManifest -Force
    $script:Worker = Join-Path $PSScriptRoot '../NativeHTMLKit.AppShell/AppShell.Worker.ps1'
    $script:Mod = Get-Module NativeHTMLKit.AppShell
    function script:New-TestModule {
        # A module with AppShell metadata whose handler body is $Body (inside the switch on $Operation).
        param([string]$Path, [string]$Id = 'org.example.chaos', [string]$Version = '0.1.0', [string]$Body,
              [string]$ManifestVersion, [string]$ModuleName)
        if (-not $ManifestVersion) { $ManifestVersion = $Version }
        $null = New-Item -ItemType Directory -Path $Path -Force
        $name = if ($ModuleName) { $ModuleName } else { 'AppShell.' + (($Id -split '\.')[-1]) }
        $psd1 = @"
@{
    RootModule = '$name.psm1'
    ModuleVersion = '$Version'
    GUID = '$([guid]::NewGuid())'
    Author = 'test'
    Description = 'AppShell test extension'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-AppShellExtension')
    PrivateData = @{ AppShell = @{ Id = '$Id'; ApiVersion = 1 } }
}
"@
        $psm1 = @"
function Invoke-AppShellExtension {
    param([string]`$Operation, `$Payload, `$Context)
    `$manifest = @{ api_version = 1; id = '$Id'; title = 'Chaos'; version = '$ManifestVersion'
        pages = @(@{ id = 'overview'; title = 'Overview' })
        commands = @(@{ id = 'go'; title = 'Go'; risk = 'read' },
                     @{ id = 'write'; title = 'Write'; risk = 'write'; confirmation = 'Write?' }) }
    if (`$Operation -eq 'manifest') {
        if (Test-Path -LiteralPath (Join-Path `$Context.data_dir 'fail-manifest')) { throw 'manifest refused by test switch' }
        return `$manifest
    }
$Body
}
Export-ModuleMember -Function Invoke-AppShellExtension
"@
        $bom = New-Object Text.UTF8Encoding($true)
        [IO.File]::WriteAllText((Join-Path $Path "$name.psd1"), $psd1, $bom)
        [IO.File]::WriteAllText((Join-Path $Path "$name.psm1"), $psm1, $bom)
        return (Join-Path $Path "$name.psd1")
    }
    function script:Invoke-TestWorker {
        param([string]$Manifest, [string]$Operation = 'action', [hashtable]$Payload = @{ command_id = 'go'; values = @{}; params = @{} },
              [int]$Timeout = 20000, [string]$Log = (Join-Path $TestDrive 'worker.log'))
        Invoke-AppShellWorker -ModulePath $Manifest -ExtensionId 'org.example.chaos' -DataDirectory (Join-Path $TestDrive 'data') `
            -Operation $Operation -Payload $Payload -WorkerFile $script:Worker -TimeoutMilliseconds $Timeout -LogPath $Log
    }
    function script:Invoke-Private { param([scriptblock]$Block, [object[]]$Arguments) & $script:Mod $Block @Arguments }
    function script:Get-Registry { param([string]$StateHome) (Get-Content -LiteralPath (Join-Path $StateHome 'registry.json') -Raw | ConvertFrom-Json) }
    function script:Complete-Session { param([string]$StateHome) & $script:Mod { param($h) Complete-AppShellSession -Home $h -Commit } $StateHome }
    $script:IsWin = ($env:OS -eq 'Windows_NT')
}

Describe 'Worker channel isolation' {
    It 'ignores every incidental stream and keeps them in the log' {
        $m = New-TestModule -Path (Join-Path $TestDrive 'noisy') -Body @'
    Write-Host 'host message'
    Write-Warning 'warning message'
    Write-Verbose 'verbose message' -Verbose
    Write-Information 'information message'
    Write-Progress -Activity 'progress' -Status 'running'
    Write-Error 'non-terminating error'
    Write-Output 'stray pipeline string'
    [Console]::WriteLine('console writeline')
    [Console]::Out.Write("console out`n")
    if ($env:OS -eq 'Windows_NT') { cmd.exe /c echo native stdout | Out-Host } else { /bin/echo native stdout | Out-Host }
    return [pscustomobject]@{ message = 'noisy done' }
'@
        $log = Join-Path $TestDrive 'noisy.log'
        (Invoke-TestWorker $m -Log $log).message | Should -Be 'noisy done'
        $text = [IO.File]::ReadAllText($log)
        foreach ($expected in 'host message','warning message','verbose message','information message','non-terminating error',
                              'stray pipeline string','console writeline','console out','native stdout') {
            $text | Should -Match ([regex]::Escape($expected))
        }
    }
    It 'round-trips non-ASCII text, nulls, booleans, numbers and arrays exactly' {
        $m = New-TestModule -Path (Join-Path $TestDrive 'echo') -Body @'
    return @{ message = ('got:' + $Payload.values.text); refresh = $false; echo = $Payload.values }
'@
        $text = "caf$([char]0xE9) $([char]0x4E2D) $([char]0xD83D)$([char]0xDE00) `"q`" \ <b>"
        $r = Invoke-TestWorker $m -Payload @{ command_id = 'go'; values = @{ text = $text; n = $null; b = $false; i = 7; list = @('a'); empty = @() }; params = @{} }
        $r.message | Should -BeExactly ('got:' + $text)
        $r.echo.b | Should -BeOfType [bool]
        $r.echo.b | Should -BeFalse
        $r.echo.i | Should -Be 7
        $r.echo.ContainsKey('n') | Should -BeTrue
        $null -eq $r.echo.n | Should -BeTrue
        @($r.echo.list).Count | Should -Be 1
        @($r.echo.empty).Count | Should -Be 0
    }
    It 'accepts an action without a result and rejects two results' {
        $m = New-TestModule -Path (Join-Path $TestDrive 'none') -Body "    if (`$Payload.command_id -eq 'go') { return }`n    @{a=1}; @{b=2}"
        (Invoke-TestWorker $m).Count | Should -Be 0
        { Invoke-TestWorker $m -Payload @{ command_id = 'write'; values = @{}; params = @{} } } | Should -Throw '*exactly one*'
    }
    It 'reports an extension exception as a definite EXTENSION_ERROR' {
        $m = New-TestModule -Path (Join-Path $TestDrive 'throws') -Body "    throw 'refused before writing'"
        { Invoke-TestWorker $m } | Should -Throw 'EXTENSION_ERROR: refused before writing'
    }
    It 'treats a crash after a write as an unknown outcome and never retries it' {
        $m = New-TestModule -Path (Join-Path $TestDrive 'crash') -Body @'
    $marker = Join-Path $Context.data_dir 'written.txt'
    Add-Content -LiteralPath $marker -Value 'x'
    [Environment]::Exit(4)
'@
        { Invoke-TestWorker $m } | Should -Throw '*outcome may be unknown*'
        @(Get-Content -LiteralPath (Join-Path $TestDrive 'data/written.txt')).Count | Should -Be 1
    }
    It 'kills a hung worker and its child process at the deadline' {
        $pidFile = Join-Path $TestDrive 'child.pid'
        $m = New-TestModule -Path (Join-Path $TestDrive 'hang') -Body @"
    `$exe = (Get-Process -Id `$PID).Path
    `$child = Start-Process -FilePath `$exe -ArgumentList @('-NoProfile','-Command','Start-Sleep 120') -PassThru
    Set-Content -LiteralPath '$pidFile' -Value `$child.Id
    Start-Sleep -Seconds 120
"@
        $clock = [Diagnostics.Stopwatch]::StartNew()
        { Invoke-TestWorker $m -Timeout 4000 } | Should -Throw 'TIMEOUT:*'
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 20
        Start-Sleep -Milliseconds 500
        $childId = [int](Get-Content -LiteralPath $pidFile)
        Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
    It 'bounds incidental output and keeps draining it' {
        $m = New-TestModule -Path (Join-Path $TestDrive 'flood') -Body @'
    $line = 'y' * 1023
    for ($i = 0; $i -lt 4096; $i++) { [Console]::Error.WriteLine($line); [Console]::WriteLine($line) }
    return @{ message = 'flooded' }
'@
        $log = Join-Path $TestDrive 'flood.log'
        (Invoke-TestWorker $m -Log $log -Timeout 60000).message | Should -Be 'flooded'
        (Get-Item -LiteralPath $log).Length | Should -BeLessThan (1MB * 4 + 4096)
        [IO.File]::ReadAllText($log) | Should -Match 'characters of worker output discarded'
    }
    It 'rejects an oversized result instead of truncating it' {
        $m = New-TestModule -Path (Join-Path $TestDrive 'huge') -Body "    return @{ message = ('z' * 1200000) }"
        { Invoke-TestWorker $m } | Should -Throw '*too large*'
    }
    It 'passes paths with spaces and non-ASCII characters to the worker' {
        $dir = Join-Path $TestDrive "dir with spaces $([char]0xE9)$([char]0x4E2D)"
        $m = New-TestModule -Path (Join-Path $dir 'mod') -Body "    return @{ message = `$Context.data_dir }"
        $data = Join-Path $dir 'data é'
        $r = Invoke-AppShellWorker -ModulePath $m -ExtensionId 'org.example.chaos' -DataDirectory $data -Operation action `
            -Payload @{ command_id = 'go'; values = @{}; params = @{} } -WorkerFile $script:Worker
        $r.message | Should -BeExactly $data
        Test-Path -LiteralPath $data | Should -BeTrue
    }
}

Describe 'Boot lifecycle' {
    It 'snapshots a drop-in, never modifies it and does not reinstall it unchanged' {
        $h = Join-Path $TestDrive 'drop-home'
        $null = New-AppShellExtension -Id org.example.drop -OutputPath (Join-Path $h 'extensions/Drop')
        $drop = Join-Path $h 'extensions/Drop'
        $before = @(Get-ChildItem -LiteralPath $drop -Recurse -Force | ForEach-Object { $_.FullName + ':' + $_.Length }) -join '|'
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker
        $s.status['org.example.drop'] | Should -Be 'ACTIVE'
        Complete-Session $h
        $release = $s.registry.extensions['org.example.drop'].release
        (@(Get-ChildItem -LiteralPath $drop -Recurse -Force | ForEach-Object { $_.FullName + ':' + $_.Length }) -join '|') | Should -Be $before
        $again = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker
        $again.registry.extensions['org.example.drop'].release | Should -Be $release
        Complete-Session $h
    }
    It 'suppresses a removed drop-in only while its folder exists' {
        $h = Join-Path $TestDrive 'suppress-home'
        $src = New-AppShellExtension -Id org.example.drop -OutputPath (Join-Path $TestDrive 'drop-src')
        $null = New-Item -ItemType Directory (Join-Path $h 'extensions') -Force
        Copy-Item -LiteralPath $src -Destination (Join-Path $h 'extensions/Drop') -Recurse
        $null = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        Remove-AppShellExtension -Id org.example.drop -Home $h
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.registry.extensions.ContainsKey('org.example.drop') | Should -BeFalse
        @($s.registry.suppressed_dropins) | Should -Be @('Drop')
        (Get-Content (Join-Path $h 'registry.json') -Raw) | Should -Not -Match '"Count"'
        Remove-Item -LiteralPath (Join-Path $h 'extensions/Drop') -Recurse -Force
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        @($s.registry.suppressed_dropins | Where-Object { $_ }).Count | Should -Be 0
        Copy-Item -LiteralPath $src -Destination (Join-Path $h 'extensions/Drop') -Recurse
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.status['org.example.drop'] | Should -Be 'ACTIVE'
    }
    It 'quarantines a broken drop-in by fingerprint until it is edited' {
        $h = Join-Path $TestDrive 'quarantine-home'
        $drop = Join-Path $h 'extensions/Broken'
        $null = New-TestModule -Path $drop -Id 'org.example.chaos' -Body "    return @{}" -ManifestVersion '9.9.9'
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.errors.ContainsKey('Broken') | Should -BeTrue
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.errors.ContainsKey('Broken') | Should -BeFalse
        $null = New-TestModule -Path $drop -Id 'org.example.chaos' -Body "    return @{}"
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.status['org.example.chaos'] | Should -Be 'ACTIVE'
    }
    It 'keeps the previous release when an upgrade fails, then upgrades, disables, enables and removes' {
        $h = Join-Path $TestDrive 'upgrade-home'
        $v1 = Split-Path -Parent (New-TestModule -Path (Join-Path $TestDrive 'v1') -Version '0.1.0' -Body "    return @{}")
        Add-AppShellExtension -SourcePath $v1 -Home $h | Should -Match 'restart'
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $old = $s.registry.extensions['org.example.chaos'].release
        Test-Path -LiteralPath (Join-Path $h 'incoming/*') | Should -BeFalse
        $bad = Split-Path -Parent (New-TestModule -Path (Join-Path $TestDrive 'v2') -Version '0.2.0' -ManifestVersion '7.0.0' -Body "    return @{}")
        $null = Add-AppShellExtension -SourcePath $bad -Home $h
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.status['org.example.chaos'] | Should -Be 'ACTIVE'
        $s.registry.extensions['org.example.chaos'].release | Should -Be $old
        (@($s.errors.Values) -join ' ') | Should -Match 'version mismatches'
        @(Get-ChildItem -LiteralPath (Join-Path $h 'releases') -Force | Where-Object { $_.Name -like '.candidate-*' }).Count | Should -Be 0
        $v3 = Split-Path -Parent (New-TestModule -Path (Join-Path $TestDrive 'v3') -Version '0.3.0' -Body "    return @{}")
        $null = Add-AppShellExtension -SourcePath $v3 -Home $h
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.registry.extensions['org.example.chaos'].version | Should -Be '0.3.0'
        Test-Path -LiteralPath $old | Should -BeTrue
        Disable-AppShellExtension -Id org.example.chaos -Home $h
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.status['org.example.chaos'] | Should -Be 'DISABLED'
        Enable-AppShellExtension -Id org.example.chaos -Home $h
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.status['org.example.chaos'] | Should -Be 'ACTIVE'
        Set-Content -LiteralPath (Join-Path $h 'extension-data/org.example.chaos/keep.txt') -Value 'user data'
        Remove-AppShellExtension -Id org.example.chaos -Home $h
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.registry.extensions.ContainsKey('org.example.chaos') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $h 'extension-data/org.example.chaos/keep.txt') | Should -Be 'user data'
        (Get-Content (Join-Path $h 'pending.json') -Raw) | Should -Not -Match '"Count"'
    }
    It 'fails only the extension whose manifest throws' {
        $h = Join-Path $TestDrive 'isolation-home'
        $null = Add-AppShellExtension -SourcePath (Split-Path -Parent (New-TestModule -Path (Join-Path $TestDrive 'c1') -Body "    return @{}")) -Home $h
        $null = Add-AppShellExtension -SourcePath (New-AppShellExtension -Id org.example.greeter -OutputPath (Join-Path $TestDrive 'g1')) -Home $h
        $null = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $null = New-Item -ItemType File -Path (Join-Path $h 'extension-data/org.example.chaos/fail-manifest') -Force
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker
        $s.status['org.example.chaos'] | Should -Be 'FAILED'
        $s.errors['org.example.chaos'] | Should -Match 'manifest refused'
        $s.status['org.example.greeter'] | Should -Be 'ACTIVE'
        Complete-Session $h
    }
    It 'starts in recovery mode on a corrupt registry, keeps the damaged bytes and restores explicitly' {
        $h = Join-Path $TestDrive 'corrupt-home'
        $null = Add-AppShellExtension -SourcePath (New-AppShellExtension -Id org.example.greeter -OutputPath (Join-Path $TestDrive 'g2')) -Home $h
        $null = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        [IO.File]::WriteAllBytes((Join-Path $h 'registry.json'), [byte[]](0x7B, 0x6E, 0x6F, 0xFF))
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker
        $s.safe_mode | Should -BeTrue
        $s.message | Should -Match 'recovery mode'
        & $script:Mod { param($h) Complete-AppShellSession -Home $h } $h
        [IO.File]::ReadAllBytes((Join-Path $h 'registry.json')).Count | Should -Be 4
        Restore-AppShell -Home $h | Should -Match 'Restored'
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.status['org.example.greeter'] | Should -Be 'ACTIVE'
        @(Get-ChildItem -LiteralPath (Join-Path $h 'backups') -Filter 'registry-*.json').Count | Should -BeGreaterThan 0
    }
    It 'restores last-known-good after an unclean exit' {
        $h = Join-Path $TestDrive 'unclean-home'
        $null = Add-AppShellExtension -SourcePath (New-AppShellExtension -Id org.example.greeter -OutputPath (Join-Path $TestDrive 'g3')) -Home $h
        $null = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $null = Add-AppShellExtension -SourcePath (Split-Path -Parent (New-TestModule -Path (Join-Path $TestDrive 'c3') -Body "    return @{}")) -Home $h
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker   # no Complete: process "crashed"
        $s.status['org.example.chaos'] | Should -Be 'ACTIVE'
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.message | Should -Match 'Restored'
        @($s.registry.extensions.Keys) | Should -Be @('org.example.greeter')
    }
    It 'holds a session lock; Restore-AppShell refuses while running and works after a crash' {
        $h = Join-Path $TestDrive 'lock-home'
        & $script:Mod { param($h) Initialize-AppShellHome $h } $h
        & $script:Mod { param($h) Write-AppShellJson (Join-Path $h 'last-good.json') @{version=1;extensions=@{}} } $h
        $lock = & $script:Mod { param($h) Enter-AppShellSession $h } $h
        try {
            { & $script:Mod { param($h) Enter-AppShellSession $h } $h } | Should -Throw '*already running*'
            { Restore-AppShell -Home $h } | Should -Throw '*Close AppShell*'
            (Test-AppShell -Home $h).Running | Should -BeTrue
        } finally { $lock.Dispose() }
        Set-Content -LiteralPath (Join-Path $h 'running.json') -Value '{}'
        (Test-AppShell -Home $h).UncleanMarker | Should -BeTrue
        Restore-AppShell -Home $h | Should -Match 'Restored'
        Test-Path -LiteralPath (Join-Path $h 'running.json') | Should -BeFalse
    }
}

Describe 'Paths, staging and generator' {
    It 'resolves relative -Home and -OutputPath against the PowerShell location' {
        Push-Location $TestDrive
        try {
            $null = New-Item -ItemType Directory -Path 'rel' -Force
            Set-Location 'rel'
            $made = New-AppShellExtension -Id org.example.rel -OutputPath './RelExt'
            $made | Should -Be (Join-Path (Join-Path $TestDrive 'rel') 'RelExt')
            $null = Add-AppShellExtension -SourcePath './RelExt' -Home './state'
            Test-Path -LiteralPath (Join-Path (Join-Path $TestDrive 'rel') 'state/pending.json') | Should -BeTrue
        } finally { Pop-Location }
    }
    It 'rejects symlinked sources and unpinned gallery versions' {
        $src = New-AppShellExtension -Id org.example.link -OutputPath (Join-Path $TestDrive 'link-src')
        $target = Join-Path $TestDrive 'outside'
        $null = New-Item -ItemType Directory -Path $target
        try { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $src 'escape') -Target $target -ErrorAction Stop; $linked = $true }
        catch { $linked = $false }
        if ($linked) { { Add-AppShellExtension -SourcePath $src -Home (Join-Path $TestDrive 'l') } | Should -Throw '*eparse*' }
        foreach ($bad in @('1', '1.2.3-beta', 'latest', '*', '1.2.3.4.5')) {
            { Add-AppShellExtension -Name Some.Module -RequiredVersion $bad -Home (Join-Path $TestDrive 'l') } | Should -Throw
        }
        { Add-AppShellExtension -Name '../evil' -RequiredVersion '1.0.0' -Home (Join-Path $TestDrive 'l') } | Should -Throw
    }
    It 'generates a module with a non-ASCII title containing quotes that imports on this edition' {
        $title = "Caf$([char]0xE9) it's `"ok`""
        $out = New-AppShellExtension -Id org.example.cafe -OutputPath (Join-Path $TestDrive 'cafe') -Title $title
        $psd1 = Get-ChildItem -LiteralPath $out -Filter '*.psd1' | Select-Object -First 1
        $bytes = [IO.File]::ReadAllBytes($psd1.FullName)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        (Import-PowerShellDataFile -LiteralPath $psd1.FullName).Description | Should -BeExactly "$title for NativeHTMLKit AppShell"
        $m = Invoke-AppShellWorker -ModulePath $psd1.FullName -ExtensionId org.example.cafe -DataDirectory (Join-Path $TestDrive 'cafe-data') -Operation manifest -WorkerFile $script:Worker
        $m.title | Should -BeExactly $title
    }
}

Describe 'Pinned package source (local PSResource repository)' {
    BeforeAll {
        $script:Repo = $null
        if (Get-Command Publish-PSResource -ErrorAction SilentlyContinue) {
            $script:Repo = 'AppShellTest' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $feed = Join-Path $TestDrive 'feed'
            $null = New-Item -ItemType Directory -Path $feed
            Register-PSResourceRepository -Name $script:Repo -Uri $feed -Trusted
            foreach ($v in '1.0.0', '1.1.0') {
                $dir = Join-Path $TestDrive "pkg-$v/AppShell.Gallery"
                $null = New-TestModule -Path $dir -Id 'org.example.gallery' -Version $v -ModuleName 'AppShell.Gallery' -Body "    return @{ message = 'gallery $v' }"
                Publish-PSResource -Path $dir -Repository $script:Repo
            }
            $env:APPSHELL_PS_REPOSITORY = $script:Repo
        }
    }
    AfterAll {
        Remove-Item Env:APPSHELL_PS_REPOSITORY -ErrorAction SilentlyContinue
        if ($script:Repo) { Unregister-PSResourceRepository -Name $script:Repo }
    }
    It 'installs exactly the pinned version on boot and skips a repeated stage' {
        if (-not $script:Repo) { Set-ItResult -Skipped -Because 'PSResourceGet Publish-PSResource is not available'; return }
        $h = Join-Path $TestDrive 'gallery-home'
        Add-AppShellExtension -Name AppShell.Gallery -RequiredVersion 1.0.0 -Home $h | Should -Match 'restart'
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.errors.Count | Should -Be 0
        $s.registry.extensions['org.example.gallery'].version | Should -Be '1.0.0'
        $release = $s.registry.extensions['org.example.gallery'].release
        $null = Add-AppShellExtension -Name AppShell.Gallery -RequiredVersion 1.0.0 -Home $h
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.registry.extensions['org.example.gallery'].release | Should -Be $release
        $null = Add-AppShellExtension -Name AppShell.Gallery -RequiredVersion 1.1.0 -Home $h
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.registry.extensions['org.example.gallery'].version | Should -Be '1.1.0'
    }
    It 'reports a missing pinned version without touching the installed release' {
        if (-not $script:Repo) { Set-ItResult -Skipped -Because 'PSResourceGet Publish-PSResource is not available'; return }
        $h = Join-Path $TestDrive 'gallery-home'
        $null = Add-AppShellExtension -Name AppShell.Gallery -RequiredVersion 9.9.9 -Home $h
        $s = Invoke-AppShellBoot -Home $h -WorkerFile $script:Worker; Complete-Session $h
        $s.errors.Count | Should -Be 1
        $s.registry.extensions['org.example.gallery'].version | Should -Be '1.1.0'
        $s.status['org.example.gallery'] | Should -Be 'ACTIVE'
    }
}
