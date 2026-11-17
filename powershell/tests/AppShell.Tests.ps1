# Run under Pester 5 with both PowerShell 7 and Windows PowerShell 5.1.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1') -Force
}
Describe 'PowerShell AppShell: module and contract' {
    It 'imports without loading Python or NativeHTMLKit UI' {
        (Get-Command New-AppShellExtension -ErrorAction Stop).Name | Should -Be 'New-AppShellExtension'
    }
    It 'generates a real PowerShell module' {
        $dest=Join-Path $TestDrive 'ExampleExtension'
        $result=New-AppShellExtension -Id org.example.hello -OutputPath $dest -Title Hello
        Test-Path (Join-Path $result 'README.md') | Should -BeTrue
        $meta=Get-ChildItem $dest -Filter '*.psd1' | Select-Object -First 1
        $data=Import-PowerShellDataFile -LiteralPath $meta.FullName
        $data.PrivateData.AppShell.Id | Should -Be 'org.example.hello'
    }
    It 'rejects bad extension IDs' {
        { New-AppShellExtension -Id '../unsafe' -OutputPath (Join-Path $TestDrive 'Bad') } | Should -Throw
    }
    It 'queues local modules without importing code' {
        $module=Join-Path $TestDrive 'LocalExtension'
        $null=New-AppShellExtension -Id org.example.local -OutputPath $module
        $stateHome=Join-Path $TestDrive 'state'
        Add-AppShellExtension -SourcePath $module -Home $stateHome | Should -Match 'restart'
        $pending=Get-Content (Join-Path $stateHome 'pending.json') -Raw | ConvertFrom-Json
        $pending.operations.Count | Should -Be 1
    }
}
Describe 'PowerShell AppShell: real same-language worker' {
    It 'loads and invokes a generated extension without NativeHTMLKit UI' {
        $source=Join-Path $TestDrive 'WorkerExample'
        $null=New-AppShellExtension -Id org.example.worker -OutputPath $source -Title 'Worker Example'
        $meta=Get-ChildItem -LiteralPath $source -Filter '*.psd1' | Select-Object -First 1
        $stateHome=Join-Path $TestDrive 'worker-data'
        $moduleRoot=Join-Path $PSScriptRoot '../NativeHTMLKit.AppShell'
        $worker=Join-Path $moduleRoot 'AppShell.Worker.ps1'
        $manifest=Invoke-AppShellWorker -ModulePath $meta.FullName -ExtensionId 'org.example.worker' -DataDirectory $stateHome -Operation manifest -WorkerFile $worker
        $manifest.id | Should -Be 'org.example.worker'
        $view=Invoke-AppShellWorker -ModulePath $meta.FullName -ExtensionId 'org.example.worker' -DataDirectory $stateHome -Operation page -Payload @{page_id='overview'} -WorkerFile $worker
        $view.blocks.Count | Should -BeGreaterThan 1
        $result=Invoke-AppShellWorker -ModulePath $meta.FullName -ExtensionId 'org.example.worker' -DataDirectory $stateHome -Operation action -Payload @{command_id='refresh';values=@{};params=@{}} -WorkerFile $worker
        $result.refresh | Should -BeTrue
    }
    It 'installs from local source only on boot and preserves last-good' {
        $source=Join-Path $TestDrive 'BootExample'
        $null=New-AppShellExtension -Id org.example.boot -OutputPath $source
        $stateHome=Join-Path $TestDrive 'boot-state'
        $worker=Join-Path $PSScriptRoot '../NativeHTMLKit.AppShell/AppShell.Worker.ps1'
        Add-AppShellExtension -SourcePath $source -Home $stateHome | Should -Match 'restart'
        @(Get-AppShellExtension -Home $stateHome).Count | Should -Be 0
        $state=Invoke-AppShellBoot -Home $stateHome -WorkerFile $worker
        $state.status['org.example.boot'] | Should -Be 'ACTIVE'
        & (Get-Module NativeHTMLKit.AppShell) { param($h) Complete-AppShellSession -Home $h -Commit } $stateHome
        Test-Path (Join-Path $stateHome 'last-good.json') | Should -BeTrue
        $restarted=Invoke-AppShellBoot -Home $stateHome -WorkerFile $worker
        $restarted.status['org.example.boot'] | Should -Be 'ACTIVE'
        & (Get-Module NativeHTMLKit.AppShell) { param($h) Complete-AppShellSession -Home $h -Commit } $stateHome
    }
}
Describe 'PowerShell AppShell: shared JSON contract fixtures' {
    BeforeAll {
        $script:Fix = Join-Path $PSScriptRoot '../../fixtures'
        $script:Mod = Get-Module NativeHTMLKit.AppShell
        function script:Read-Fixture([string]$Name) { Get-Content -LiteralPath (Join-Path $script:Fix $Name) -Raw -Encoding UTF8 | ConvertFrom-Json }
        $script:Manifest = & $script:Mod { param($m) Assert-AppShellManifest $m $m.id $m.version } (Read-Fixture 'valid/manifest.json')
    }
    It 'accepts the valid manifest and view fixtures parsed from JSON' {
        $script:Manifest.api_version | Should -Be 1
        $view = & $script:Mod { param($v, $m) Assert-AppShellView $v $m } (Read-Fixture 'valid/view.json') $script:Manifest
        @($view.blocks).Count | Should -BeGreaterThan 0
    }
    It 'rejects invalid manifest fixture <_>' -ForEach @('manifest-bad-id.json', 'manifest-duplicate-page.semantic.json',
            'manifest-missing-confirmation.json', 'manifest-unsupported-version.json') {
        $m = Read-Fixture ('invalid/' + $_)
        { & $script:Mod { param($m) Assert-AppShellManifest $m ([string]$m.id) ([string]$m.version) } $m } | Should -Throw
    }
    It 'rejects invalid view fixture <_>' -ForEach @('view-bad-heading-level.json', 'view-raw-html.json', 'view-unknown-command.semantic.json') {
        $v = Read-Fixture ('invalid/' + $_)
        { & $script:Mod { param($v, $m) Assert-AppShellView $v $m } $v $script:Manifest } | Should -Throw
    }
    It 'renders hostile text escaped' {
        $view = @{ title = 'x'; blocks = @(@{ kind = 'heading'; text = '<script>alert(1)</script>'; level = 3 },
            @{ kind = 'table'; columns = @(@{ key = 'a'; title = '<i>' }); rows = @(@{ a = '<iframe>' }) }) }
        $html = & $script:Mod { param($v) $c = @{ BlockIndex = 0; Generation = 1; Fields = @{}; Actions = @{} }; Render-AppShellBlocks @($v.blocks) $c } $view
        $html | Should -Not -Match '<script>|<iframe>|<i>'
        $html | Should -Match '&lt;script&gt;'
    }
}
