# Real native host in headless test mode (NATIVEHTMLKIT_TEST_MODE=1) driving the PowerShell desktop.
Describe 'PowerShell AppShell desktop on the native host' -Tag 'native' {
    BeforeAll {
        $script:HaveUi = [bool](Get-Module -ListAvailable NativeHTMLKit.UI)
    }
    It 'passes the desktop scenario and exits cleanly' {
        if (-not $script:HaveUi) { Set-ItResult -Skipped -Because 'NativeHTMLKit.UI is not installed'; return }
        $stateHome = Join-Path $TestDrive 'home'
        Import-Module (Join-Path $PSScriptRoot '../NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1') -Force
        $null = Add-AppShellExtension -SourcePath (Join-Path $PSScriptRoot 'Showcase') -Home $stateHome
        $out = Join-Path $TestDrive 'scenario.json'
        $exe = (Get-Process -Id $PID).Path
        $old = $env:NATIVEHTMLKIT_TEST_MODE
        $env:NATIVEHTMLKIT_TEST_MODE = '1'
        try {
            $log = Join-Path $TestDrive 'scenario.log'
            $p = Start-Process -FilePath $exe -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                ('"' + (Join-Path $PSScriptRoot 'desktop-scenario.ps1') + '"'), ('"' + $out + '"'), ('"' + $stateHome + '"')) `
                -PassThru -NoNewWindow -RedirectStandardError $log -RedirectStandardOutput ($log + '.out')
            $null = $p.Handle
            if (-not $p.WaitForExit(600000)) { $p.Kill(); throw 'scenario timed out' }
        } finally { $env:NATIVEHTMLKIT_TEST_MODE = $old }
        Test-Path -LiteralPath $out | Should -BeTrue -Because ((Get-Content $log -Raw -ErrorAction SilentlyContinue) + (Get-Content ($log + '.out') -Raw -ErrorAction SilentlyContinue))
        $r = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        $report = (@($r.checks) | ForEach-Object { $(if ($_.ok) { 'PASS ' } else { 'FAIL ' }) + $_.name + $(if (-not $_.ok) { ' ' + $_.detail } else { '' }) }) -join "`n"
        Write-Host $report
        Write-Host ('timings ' + (ConvertTo-Json -InputObject $r.timings -Compress))
        @($r.failed).Count | Should -Be 0 -Because $report
        @($r.checks).Count | Should -BeGreaterOrEqual 50
        $p.ExitCode | Should -Be 0 -Because (Get-Content $log -Raw -ErrorAction SilentlyContinue)
        Test-Path -LiteralPath (Join-Path $stateHome 'running.json') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $stateHome 'last-good.json') -Raw | ConvertFrom-Json).extensions.'org.example.showcase' | Should -Not -BeNullOrEmpty
    }
}
