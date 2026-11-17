BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../AppShell.Greeter.psd1') -Force
}
Describe 'PowerShell Greeter' {
    It 'responds to the manifest operation' {
        $context = @{ data_dir=$TestDrive; extension_id='org.nativehtmlkit.examples.greeter'; app_version='0.1.0' }
        $manifest = Invoke-AppShellExtension -Operation manifest -Payload @{} -Context $context
        $manifest.id | Should -Be 'org.nativehtmlkit.examples.greeter'
        $manifest.api_version | Should -Be 1
    }
    It 'renders its page and has a working read action' {
        $context = @{ data_dir=$TestDrive; extension_id='org.nativehtmlkit.examples.greeter'; app_version='0.1.0' }
        $view = Invoke-AppShellExtension -Operation page -Payload @{page_id='overview'} -Context $context
        $view.blocks.Count | Should -BeGreaterThan 1
        (Invoke-AppShellExtension -Operation action -Payload @{command_id='refresh'} -Context $context).refresh | Should -BeTrue
    }
}
