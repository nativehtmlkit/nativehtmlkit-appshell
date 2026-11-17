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
        $home=Join-Path $TestDrive 'state'
        Add-AppShellExtension -SourcePath $module -Home $home | Should -Match 'restart'
        $pending=Get-Content (Join-Path $home 'pending.json') -Raw | ConvertFrom-Json
        $pending.operations.Count | Should -Be 1
    }
}
Describe 'PowerShell AppShell: real same-language worker' {
    It 'loads and invokes a generated extension without NativeHTMLKit UI' {
        $source=Join-Path $TestDrive 'WorkerExample'
        $null=New-AppShellExtension -Id org.example.worker -OutputPath $source -Title 'Worker Example'
        $meta=Get-ChildItem -LiteralPath $source -Filter '*.psd1' | Select-Object -First 1
        $home=Join-Path $TestDrive 'worker-data'
        $moduleRoot=Join-Path $PSScriptRoot '../NativeHTMLKit.AppShell'
        $worker=Join-Path $moduleRoot 'AppShell.Worker.ps1'
        $manifest=Invoke-AppShellWorker -ModulePath $meta.FullName -ExtensionId 'org.example.worker' -DataDirectory $home -Operation manifest -WorkerFile $worker
        $manifest.id | Should -Be 'org.example.worker'
        $view=Invoke-AppShellWorker -ModulePath $meta.FullName -ExtensionId 'org.example.worker' -DataDirectory $home -Operation page -Payload @{page_id='overview'} -WorkerFile $worker
        $view.blocks.Count | Should -BeGreaterThan 1
        $result=Invoke-AppShellWorker -ModulePath $meta.FullName -ExtensionId 'org.example.worker' -DataDirectory $home -Operation action -Payload @{command_id='refresh';values=@{};params=@{}} -WorkerFile $worker
        $result.refresh | Should -BeTrue
    }
    It 'installs from local source only on boot and preserves last-good' {
        $source=Join-Path $TestDrive 'BootExample'
        $null=New-AppShellExtension -Id org.example.boot -OutputPath $source
        $home=Join-Path $TestDrive 'boot-state'
        $worker=Join-Path $PSScriptRoot '../NativeHTMLKit.AppShell/AppShell.Worker.ps1'
        Add-AppShellExtension -SourcePath $source -Home $home | Should -Match 'restart'
        @(Get-AppShellExtension -Home $home).Count | Should -Be 0
        $state=Invoke-AppShellBoot -Home $home -WorkerFile $worker
        $state.status['org.example.boot'] | Should -Be 'ACTIVE'
        & (Get-Module NativeHTMLKit.AppShell) { param($h) Complete-AppShellSession -Home $h -Commit } $home
        Test-Path (Join-Path $home 'last-good.json') | Should -BeTrue
        $restarted=Invoke-AppShellBoot -Home $home -WorkerFile $worker
        $restarted.status['org.example.boot'] | Should -Be 'ACTIVE'
        & (Get-Module NativeHTMLKit.AppShell) { param($h) Complete-AppShellSession -Home $h -Commit } $home
    }
}
