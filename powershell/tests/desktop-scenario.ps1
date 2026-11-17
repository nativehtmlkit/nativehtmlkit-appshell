# Desktop scenario: the real PowerShell AppShell desktop on the native host, driven in-process.
# usage: pwsh -File desktop-scenario.ps1 OUT.json HOME   (NATIVEHTMLKIT_TEST_MODE=1 for headless)
# The SDK re-runs this file as the host backend. The driver calls the same module function the
# click callback calls (Invoke-AppShellClick) and pumps the SDK between steps so real host events
# (dialog close, task completions) are delivered; DOM state is read back with public SDK cmdlets.
# This proves AppShell logic and SDK/UI compatibility, not native input (see docs/VERIFICATION.md).
param([string]$Out, [string]$StateHome)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1') -Force
Import-Module NativeHTMLKit.UI
$app = Start-NativeHTMLKitScript -Name 'AppShell PS scenario' -AppId 'org.nativehtmlkit.AppShell.PowerShellScenario' `
    -Instance multiple -ScriptPath $PSCommandPath -ArgumentList @($Out, $StateHome)
$clock = [Diagnostics.Stopwatch]::StartNew()
$mod = Get-Module NativeHTMLKit.AppShell
$results = @{ checks = New-Object System.Collections.ArrayList; failed = New-Object System.Collections.ArrayList; timings = @{}; finished = $false }
function Check([string]$Name, $Ok, $Detail = '') {
    $d = [string]$Detail; if ($d.Length -gt 3000) { $d = $d.Substring(0, 3000) }
    [void]$results.checks.Add(@{ name = $Name; ok = [bool]$Ok; detail = $d })
    if (-not $Ok) { [void]$results.failed.Add($Name) }
}
function Pump([scriptblock]$Until, [int]$Timeout = 30000, [string]$What = 'condition') {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Until)) {
        if ($sw.ElapsedMilliseconds -gt $Timeout) { throw "timed out waiting for $What" }
        $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 20
    }
}
function Settle { for ($i = 0; $i -lt 5; $i++) { $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 20 } }
function Click([string]$Id, [object[]]$Path = @()) {
    & $mod { param($c, $e) Invoke-AppShellClick $c $e } $ctx ([pscustomobject]@{ type = 'click'; element = $Id; path = @($Path + 'as-content') })
    Settle
}
function Text([string]$Id) { [string](Get-NativeHTMLKitDocumentText -Document $doc -Element $Id) }
function Count([string]$Selector) { [int](Invoke-NativeHTMLKitDocumentCommand $doc 'query' @{ selector = $Selector }).matched_nodes }
function DialogOpen { [bool](Invoke-NativeHTMLKitDocumentCommand $doc 'get_dialog' @{ element = 'as-confirm' }).open }
function Focused { [string](Get-NativeHTMLKitFocusedElement -Document $doc).element }
function Buttons { $map = @{}; foreach ($k in @($ctx.Actions.Keys)) { $map[$ctx.Actions[$k].command] = $k }; $map }
function OpenPage([string]$NavId) { Click $NavId; Pump { $ctx.PageReady } 30000 "page $NavId"; Settle }
$ctx = $null
$cafe = "caf$([char]0xE9) $([char]0x4E2D)"
try {
    $ctx = & $mod { param($a, $h) Initialize-AppShellDesktop -Application $a -Home $h } $app $StateHome
    $doc = $ctx.Document
    $results.timings.mounted_s = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
    Check 'home visible before boot finishes' ((Text 'as-content') -match 'AppShell')
    Pump { $ctx.BootCompleted -or $ctx.State.safe_mode } 120000 'boot'
    Settle
    $results.timings.booted_s = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
    $nav = Text 'as-nav'
    Check 'nav lists extension pages' ($nav -match 'Controls' -and $nav -match 'Second page') $nav
    Check 'status reports active extensions' ($ctx.StatusText -eq '1 extensions active') $ctx.StatusText
    $controls = @($ctx.Nav.Keys | Where-Object { $ctx.Nav[$_].page -eq 'controls' })[0]
    $second = @($ctx.Nav.Keys | Where-Object { $ctx.Nav[$_].page -eq 'second' })[0]
    # Delegated click: element is a child without a known id, the nav button is on the path.
    & $mod { param($c, $e) Invoke-AppShellClick $c $e } $ctx ([pscustomobject]@{ type = 'click'; element = ''; path = @($controls, 'as-nav') })
    Pump { $ctx.PageReady } 30000 'controls'
    Settle
    $text = Text 'as-content'
    Check 'page rendered' ($text -match 'Level one' -and $text -match 'Saved:') $text
    Check 'hostile text shown as text' ($text.Contains('<script>alert(1)</script>')) $text
    Check 'no script/b element from extension text' ((Count '#as-content script, #as-content b') -eq 0)
    foreach ($pair in @(@('h1.as-heading', 'heading 1'), @('h4.as-heading', 'heading 4'), @('small.as-caption', 'caption'),
                        @('pre.as-code', 'code'), @('span.as-badge', 'badge'), @('.as-notice-danger', 'danger notice'),
                        @('hr.as-divider', 'divider'), @('.as-card .as-row .as-column', 'containers'),
                        @('table.as-table th', 'table header'), @('input[type=password]', 'password'),
                        @('textarea', 'textarea'), @('input[type=checkbox]', 'checkbox'), @('select option', 'select options'))) {
        Check ('control rendered: ' + $pair[1]) ((Count ('#as-content ' + $pair[0])) -gt 0) $pair[0]
    }
    Check 'table cells render like the Python edition' ($text.Contains('2.5') -and $text.Contains('True')) $text
    $f = $ctx.Fields
    Check 'all fields registered' ((@($f.Keys | Sort-Object) -join ',') -eq 'agree,level,notes,secret,title') (@($f.Keys) -join ',')
    Check 'input initial value' ((Get-NativeHTMLKitValue -Document $doc -Element $f.title.id) -ceq $cafe)
    Check 'textarea initial value' ((Get-NativeHTMLKitValue -Document $doc -Element $f.notes.id) -ceq "a`nb")
    Check 'checkbox initial' ((Get-NativeHTMLKitChecked -Document $doc -Element $f.agree.id) -eq $true)
    Check 'select initial' ((Get-NativeHTMLKitValue -Document $doc -Element $f.level.id) -eq 'two')
    $opts = @((Get-NativeHTMLKitSelectOptions -Document $doc -Element $f.level.id) | ForEach-Object { $_.value })
    Check 'select option values escaped' (($opts -join '|') -ceq 'one|two|x"<') ($opts -join '|')
    $b = Buttons
    $typed = "typed $([char]0xE9) <x>"
    Set-NativeHTMLKitDocumentValue -Document $doc -Element $f.title.id -Value $typed
    Set-NativeHTMLKitDocumentValue -Document $doc -Element $f.secret.id -Value 'hunter2'
    Set-NativeHTMLKitChecked -Document $doc -Element $f.agree.id -Checked $false
    Set-NativeHTMLKitDocumentValue -Document $doc -Element $f.level.id -Value 'x"<'
    Click $b.echo
    Pump { $ctx.StatusText -like 'echo*' } 30000 'echo'
    $s = $ctx.StatusText
    Check 'read action sends current values and params' ($s.Contains("title=$typed") -and $s.Contains('agree=False') -and
        $s.Contains('level=x"<') -and $s.Contains('secret=hunter2') -and $s.Contains("params=param $([char]0xE9)")) $s
    Check 'read action shows no dialog' (-not (DialogOpen))
    $data = Join-Path $StateHome 'extension-data/org.example.showcase'
    Click $b.save
    Check 'write opens confirm dialog' (DialogOpen)
    Check 'confirm text is the manifest confirmation' ((Text 'as-confirm-text') -eq 'Save the form values?') (Text 'as-confirm-text')
    Check 'write dialog focuses Confirm' ((Focused) -eq 'as-yes') (Focused)
    Click 'as-no'
    Pump { -not (DialogOpen) -and $ctx.StatusText -eq 'Cancelled' } 10000 'cancel'
    Check 'cancel runs nothing' (-not (Test-Path (Join-Path $data 'saved.txt')) -and $null -eq $ctx.Pending)
    Check 'focus returns to the Save button after cancel' ((Focused) -eq $b.save) (Focused)
    Click $b.save
    Click 'as-yes'
    Pump { (Test-Path (Join-Path $data 'saved.txt')) -and $ctx.PageReady -and $ctx.StatusText -eq 'Ready' } 30000 'save'
    Settle
    Check 'confirmed write ran once with typed value' ([IO.File]::ReadAllText((Join-Path $data 'saved.txt')) -ceq $typed)
    Check 'refresh shows saved value' ((Text 'as-content').Contains("Saved: $typed"))
    $b = Buttons
    Click $b.wipe
    Check 'destructive dialog focuses Cancel' ((Focused) -eq 'as-no') (Focused)
    Show-NativeHTMLKitHtmlDialog -Document $doc -Element 'as-confirm' -Close   # what Escape produces
    Pump { -not (DialogOpen) -and $null -eq $ctx.Pending } 10000 'escape'
    Check 'escape cancels destructive' (Test-Path (Join-Path $data 'saved.txt'))
    Click $b.wipe
    OpenPage $second
    Click 'as-yes'
    Settle; Start-Sleep -Milliseconds 500; Settle
    Check 'confirm after navigation does not run the stale command' (Test-Path (Join-Path $data 'saved.txt'))
    Click $b.wipe
    Check 'stale button id from previous page ignored' (-not (DialogOpen))
    for ($i = 0; $i -lt 100; $i++) {
        $target = if ($i % 2) { $controls } else { $second }
        & $mod { param($c, $e) Invoke-AppShellClick $c $e } $ctx ([pscustomobject]@{ type = 'click'; element = $target; path = @() })
        if ($i % 10 -eq 0) { $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 1 }
    }
    Pump { $ctx.PageReady -and $ctx.InFlight -eq 0 } 60000 'rapid navigation'
    Settle
    Check 'rapid navigation ends on the last page' ((Text 'as-content') -match 'Level one' -and (Text 'as-title') -eq 'Controls') (Text 'as-title')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt 100; $i++) {
        $b = Buttons
        $ctx.PageReady = $false
        Click $b.count
        Pump { $ctx.PageReady -and $ctx.StatusText -eq 'Ready' } 30000 "count $i"
    }
    $results.timings.refresh_100_s = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    Check '100 refresh actions all applied' ([IO.File]::ReadAllText((Join-Path $data 'count.txt')) -eq '100' -and (Text 'as-content').Contains('Count: 100'))
    $b = Buttons
    Click $b.crash_write
    Click 'as-yes'
    Pump { $ctx.StatusText -like 'Outcome unknown*' } 30000 'unknown outcome'
    Settle
    Check 'crash during write reports unknown outcome' ((Text 'as-content') -match 'do not retry') $ctx.StatusText
    Remove-Item -LiteralPath (Join-Path $data 'crash-write.txt')
    Start-Sleep -Seconds 1
    Check 'crashed write not retried' (-not (Test-Path (Join-Path $data 'crash-write.txt')))
    OpenPage $controls
    Check 'extension usable again after crash' ((Text 'as-content') -match 'Level one')
    Click 'as-extensions'
    $text = Text 'as-content'
    Check 'extensions page lists extension' ($text.Contains('org.example.showcase') -and $text.Contains('ACTIVE')) $text
    $key = @($ctx.Special.Keys | Where-Object { $ctx.Special[$_].operation -eq 'disable' })[0]
    Click $key
    $pending = Get-Content -LiteralPath (Join-Path $StateHome 'pending.json') -Raw | ConvertFrom-Json
    Check 'disable queued for restart' (@($pending.operations)[-1].action -eq 'disable')
    & $mod { param($h) Write-AppShellJson (Join-Path $h 'pending.json') @{version=1;operations=@()} } $StateHome
    Click 'as-add'
    Check 'staging requires trust confirmation' ($ctx.StatusText -match 'trust') $ctx.StatusText
    $src = New-AppShellExtension -Id org.example.staged -OutputPath (Join-Path $StateHome '../staged src')
    Set-NativeHTMLKitDocumentValue -Document $doc -Element 'as-source' -Value $src
    Set-NativeHTMLKitChecked -Document $doc -Element 'as-trust' -Checked $true
    Click 'as-add'
    Pump { $ctx.StatusText -like 'Extension staged*' -or $ctx.StatusText -like 'Install request failed*' } 30000 'stage'
    Check 'staging from the Extensions page queues the module' ($ctx.StatusText -like 'Extension staged*') $ctx.StatusText
    & $mod { param($h) Write-AppShellJson (Join-Path $h 'pending.json') @{version=1;operations=@()} } $StateHome
    Click 'as-settings'
    Check 'settings page' ((Text 'as-content') -match 'No telemetry')
    Click 'as-home'
    Check 'home page' ((Text 'as-content') -match 'Getting started')
    Check 'status footer is a live region' ((Count '#as-status[role=status]') -eq 1)
    # The SDK swallows callback exceptions into this counter; a broken callback would hide here.
    Check 'no SDK callback failures' ([int]$app.CallbackFailures -eq 0) $app.CallbackFailures
} catch {
    $state = if ($ctx) { " status=[$($ctx.StatusText)] inflight=$($ctx.InFlight) ready=$($ctx.PageReady) " } else { '' }
    $diagText = " callback_failures=$($app.CallbackFailures)"
    Check 'driver exception' $false ($_.Exception.Message + $state + $diagText + ' ' + $_.ScriptStackTrace)
} finally {
    $results.finished = $true
    [IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject $results -Depth 6), (New-Object Text.UTF8Encoding($false)))
    try {
        Request-NativeHTMLKitQuit -Application $app
        Wait-NativeHTMLKit -Application $app -UntilShutdown
        & $mod { param($c) Close-AppShellDesktop $c -Clean } $ctx
    } finally { Close-NativeHTMLKit -Application $app }
}
