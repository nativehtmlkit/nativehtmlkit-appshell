# GUI probe (test tooling): the real PowerShell AppShell desktop plus a read-only state channel.
# usage: pwsh|powershell -File probe_ps.ps1 CHANNEL_DIR HOME
# Starts what Start-AppShell starts (Initialize-AppShellDesktop, then the SDK pump). Between pumps
# it answers the GUI driver's questions through files in CHANNEL_DIR (req-N.json -> resp-N.json).
# It never injects events: all input comes from the OS.
param([string]$Channel, [string]$StateHome)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../powershell/NativeHTMLKit.AppShell/NativeHTMLKit.AppShell.psd1') -Force
Import-Module NativeHTMLKit.UI
$app = Start-NativeHTMLKitScript -Name 'NativeHTMLKit AppShell' -AppId 'org.nativehtmlkit.AppShell.PowerShellGuiProbe' `
    -Instance multiple -ScriptPath $PSCommandPath -ArgumentList @($Channel, $StateHome)
$mod = Get-Module NativeHTMLKit.AppShell
$ctx = & $mod { param($a, $h) Initialize-AppShellDesktop -Application $a -Home $h } $app $StateHome
$doc = $ctx.Document
function Answer($Request) {
    switch ([string]$Request.cmd) {
        'state' {
            $buttons = @{}; foreach ($k in @($ctx.Actions.Keys)) { $buttons[$ctx.Actions[$k].command] = $k }
            $fields = @{}; foreach ($k in @($ctx.Fields.Keys)) { $fields[$k] = $ctx.Fields[$k].id }
            $nav = @{}; foreach ($k in @($ctx.Nav.Keys)) { $nav[$k] = @($ctx.Nav[$k].id, $ctx.Nav[$k].page) }
            $special = @{}; foreach ($k in @($ctx.Special.Keys)) { $special[$k] = @($ctx.Special[$k].operation, $ctx.Special[$k].id) }
            return @{ booted = [bool]$ctx.BootCompleted; safe_mode = [bool]$ctx.State.safe_mode; status = [string]$ctx.StatusText
                title = [string](Get-NativeHTMLKitDocumentText -Document $doc -Element 'as-title')
                selected = $(if ($ctx.Selected) { @($ctx.Selected.id, $ctx.Selected.page) } else { $null })
                page_ready = [bool]$ctx.PageReady; generation = $ctx.Generation; nav = $nav; nav_container = 'as-nav'
                outlet = 'as-content'; buttons = $buttons; fields = $fields; special = $special
                pending = ($null -ne $ctx.Pending); busy = [bool]$ctx.Busy
                dialog_open = [bool](Invoke-NativeHTMLKitDocumentCommand $doc 'get_dialog' @{ element = 'as-confirm' }).open
                focused = [string](Get-NativeHTMLKitFocusedElement -Document $doc).element
                workers = @(); ui_errors = @(); callback_failures = [int]$app.CallbackFailures }
        }
        'rect' {
            # The only non-OS action: scroll the target into view, as a user would with the wheel.
            if ($Request.reveal) { $null = Invoke-NativeHTMLKitDocumentCommand $doc 'scroll_into_view' @{ element = [string]$Request.id } }
            $rect = (Invoke-NativeHTMLKitDocumentCommand $doc 'get_rect' @{ element = [string]$Request.id }).rect
            return @{ x = $rect.x; y = $rect.y; width = $rect.width; height = $rect.height
                      scroll_y = (Invoke-NativeHTMLKitDocumentCommand $doc 'get_scroll' @{}).y }
        }
        'text' { return [string](Get-NativeHTMLKitDocumentText -Document $doc -Element ([string]$Request.id)) }
        'value' { return [string](Get-NativeHTMLKitValue -Document $doc -Element ([string]$Request.id)) }
        'checked' { return [bool](Get-NativeHTMLKitChecked -Document $doc -Element ([string]$Request.id)) }
        'query' { return (Invoke-NativeHTMLKitDocumentCommand $doc 'query' @{ selector = [string]$Request.selector }) }
        'sidebar_button' {
            foreach ($id in @((Invoke-NativeHTMLKitDocumentCommand $doc 'query' @{ selector = '.as-sidebar button' }).ids)) {
                if (([string](Get-NativeHTMLKitDocumentText -Document $doc -Element $id)).Trim() -eq [string]$Request.label) { return $id }
            }
            return $null
        }
        'a11y' { return (Invoke-NativeHTMLKitDocumentCommand $doc 'get_accessibility_tree' @{}) }
        default { throw ('unknown probe command ' + $Request.cmd) }
    }
}
[IO.File]::WriteAllText((Join-Path $Channel 'ready'), [string]$PID)
$seq = 0
$clean = $false
try {
    while (-not $app.ShutdownRequested -and -not $app.Closed) {
        try { $null = Wait-NativeHTMLKit -Application $app -TimeoutMilliseconds 30 }
        catch [NativeHTMLKit.DisconnectedException] { if ($app.ShutdownRequested) { break }; throw }
        $req = Join-Path $Channel "req-$seq.json"
        if (-not (Test-Path -LiteralPath $req)) { continue }
        $box = @{}
        try { $box.result = Answer (Get-Content -LiteralPath $req -Raw | ConvertFrom-Json) }
        catch { $box.error = [string]$_.Exception.Message }
        $tmp = Join-Path $Channel "resp-$seq.tmp"
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $box -Depth 30 -Compress), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination (Join-Path $Channel "resp-$seq.json") -Force
        $seq++
    }
    $clean = $true
} finally {
    & $mod { param($c, $ok) Close-AppShellDesktop $c -Clean:$ok } $ctx $clean
    Close-NativeHTMLKit -Application $app
}
