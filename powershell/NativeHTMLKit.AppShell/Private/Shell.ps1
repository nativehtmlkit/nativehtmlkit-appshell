# The desktop layer uses only public NativeHTMLKit PowerShell SDK/UI APIs.
#
# Callbacks: the SDK invokes document-event and task-completion scriptblocks on this owner
# runspace while it pumps. They are plain scriptblocks defined in this module (bound to the
# module's session state), NOT .GetNewClosure() copies: a closure is re-bound to a dynamic
# module and can no longer call this module's private functions. Per-request data travels in
# the task result instead of captured variables.
$script:AppShellDesktop = $null
$script:AppShellMaxInFlight = 6   # the SDK allows 8 background tasks per application

$script:AppShellOnClick = { param($evt) Invoke-AppShellClick $script:AppShellDesktop $evt }
$script:AppShellOnDialogClose = { param($evt) Complete-AppShellConfirm $script:AppShellDesktop $evt }
$script:AppShellOnRequestDone = { param($data) Complete-AppShellRequest $script:AppShellDesktop $data }
$script:AppShellOnRequestFailed = { param($failure) Fail-AppShellRequest $script:AppShellDesktop $failure }
$script:AppShellOnBoot = { param($data) Complete-AppShellBoot $script:AppShellDesktop $data }
$script:AppShellOnBootFailed = { param($failure) Set-AppShellStatus $script:AppShellDesktop ('Boot failed: ' + $failure.Message) }
$script:AppShellOnStaged = { param($data) Complete-AppShellStage $script:AppShellDesktop $data }

$script:AppShellRequestTask = {
    # Runs in a fresh runspace: plain data in, plain data out; never throws.
    param($moduleManifest, $call, $meta)
    try {
        Import-Module -Name $moduleManifest -Force -ErrorAction Stop
        $result = Invoke-AppShellWorker @call
        @{ meta = $meta; ok = $true; result = $result }
    } catch { @{ meta = $meta; ok = $false; error = [string]$_.Exception.Message } }
}

function Escape-AppShellHtml {
    param($Value)
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}
function Set-AppShellContent {
    param([hashtable]$Context,[string]$Title,[string]$Html)
    $Context.Generation++
    $Context.Actions=@{}; $Context.Fields=@{}; $Context.Special=@{}
    Set-NativeHTMLKitDocumentText -Document $Context.Document -Element 'as-title' -Text $Title
    Set-NativeHTMLKitDocumentHtml -Document $Context.Document -Element 'as-content' -Html $Html
}
function Set-AppShellStatus {
    param([hashtable]$Context,[string]$Message)
    $Context.StatusText = $Message
    Set-NativeHTMLKitDocumentText -Document $Context.Document -Element 'as-status' -Text $Message
}
function Get-AppShellPages {
    # Same order as the Python edition: extension title, page order (default 100), page id.
    param([hashtable]$Context)
    $pages = @()
    foreach ($id in @($Context.State.manifests.Keys)) {
        if ($Context.State.status[$id] -ne 'ACTIVE') { continue }
        $manifest = $Context.State.manifests[$id]
        foreach ($page in @($manifest.pages)) {
            $order = if ($page.ContainsKey('order')) { [int]$page.order } else { 100 }
            $pages += ,([pscustomobject]@{ id=$id; page=$page.id; title=$page.title; sortTitle=([string]$manifest.title).ToLowerInvariant(); order=$order })
        }
    }
    return @($pages | Sort-Object -Property sortTitle, order, page)
}
function Update-AppShellNav {
    param([hashtable]$Context)
    $Context.Nav=@{}
    $html = '<div class="as-nav-label">Installed</div>'
    $i=0
    foreach ($entry in @(Get-AppShellPages $Context)) {
        $key="as-nav-$i"; $i++
        $Context.Nav[$key]=@{ id=$entry.id; page=$entry.page }
        $active = if ($Context.Selected -and $Context.Selected.id -eq $entry.id -and $Context.Selected.page -eq $entry.page) { ' active' } else { '' }
        $html += ('<button type="button" class="as-nav-link' + $active + '" id="' + $key + '">' + (Escape-AppShellHtml $entry.title) + '</button>')
    }
    Set-NativeHTMLKitDocumentHtml -Document $Context.Document -Element 'as-nav' -Html $html
}
function Show-AppShellHome {
    param([hashtable]$Context)
    $Context.Selected=$null
    $intro = '<p class="as-text">NativeHTMLKit AppShell ' + (Escape-AppShellHtml $script:AppShellVersion) + ' — native PowerShell edition. No Python required.</p>'
    if ($Context.State.message) { $intro += '<div class="as-notice as-notice-warning">' + (Escape-AppShellHtml $Context.State.message) + '</div>' }
    if ($Context.State.errors.Count -gt 0) { $intro += '<div class="as-notice as-notice-danger">' + $Context.State.errors.Count + ' extension errors. See Extensions for details.</div>' }
    $intro += '<div class="as-card"><h3>Getting started</h3><p class="as-text">Add a PowerShell module on the Extensions page or copy it to the extensions folder. Restart AppShell to activate it.</p></div>'
    Set-AppShellContent $Context 'Home' $intro
    Update-AppShellNav $Context
}
function Show-AppShellExtensions {
    param([hashtable]$Context)
    $Context.Selected=$null
    $markup = '<p class="as-caption">Add a module folder or a pinned gallery module (Name==1.2.3). Changes apply after restart.</p>' +
              '<div class="as-card"><label class="as-field-label" for="as-source">Module folder or Name==Version</label>' +
              '<input type="text" id="as-source" placeholder="./MyExtension or My.Module==1.2.3">' +
              '<label class="as-field-label"><input type="checkbox" id="as-trust"> I trust this module to execute with my user permissions.</label>' +
              '<button type="button" id="as-add" class="as-button">Add for next restart</button></div>' +
              '<p class="as-caption">Drop-in directory: ' + (Escape-AppShellHtml (Join-Path $Context.Home 'extensions')) + '</p>'
    $actions = @{}
    $i=0
    foreach ($id in @($Context.State.registry.extensions.Keys | Sort-Object)) {
        $record = $Context.State.registry.extensions[$id]
        $status = if ($Context.State.status.ContainsKey($id)) { $Context.State.status[$id] } else { 'NOT LOADED' }
        $toggle=if ($record.enabled -eq $false) { 'enable' } else { 'disable' }
        $toggleKey = 'as-ext-'+$i; $removeKey='as-ext-'+$i+'-remove'; $i++
        $actions[$toggleKey]=@{operation=$toggle;id=$id}
        $actions[$removeKey]=@{operation='remove';id=$id}
        $label = $toggle.Substring(0,1).ToUpperInvariant() + $toggle.Substring(1) + ' on restart'
        $markup += '<div class="as-extension"><strong>' + (Escape-AppShellHtml $id) + '</strong><p class="as-meta">' +
            (Escape-AppShellHtml ([string]$record.version + ' · ' + $status)) + '</p>' +
            '<button type="button" id="'+$toggleKey+'" class="as-button">' + $label + '</button>' +
            '<button type="button" id="'+$removeKey+'" class="as-button">Remove</button></div>'
    }
    foreach ($key in @($Context.State.errors.Keys | Sort-Object)) {
        $markup += '<div class="as-notice as-notice-danger"><strong>'+(Escape-AppShellHtml $key)+'</strong>: '+(Escape-AppShellHtml $Context.State.errors[$key])+'</div>'
    }
    Set-AppShellContent $Context 'Extensions' $markup
    $Context.Special=$actions
    Update-AppShellNav $Context
}
function Show-AppShellSettings {
    param([hashtable]$Context)
    $Context.Selected=$null
    $markup = '<div class="as-card"><h3>Local configuration</h3><p class="as-text">Data: '+(Escape-AppShellHtml $Context.Home)+'</p>' +
              '<p class="as-text">Extensions: '+(Escape-AppShellHtml (Join-Path $Context.Home 'extensions'))+'</p>' +
              '<p class="as-text">No telemetry, marketplace backend, or remote server.</p></div>' +
              '<div class="as-card"><button id="as-restore" class="as-button" type="button">Restore last-known-good on next restart</button></div>'
    Set-AppShellContent $Context 'Settings' $markup
    Update-AppShellNav $Context
}
function Render-AppShellBlocks {
    # Same markup and class names as the Python renderer; every extension value is escaped.
    param([object[]]$Blocks,[hashtable]$Context)
    $result = New-Object Text.StringBuilder
    foreach ($b in @($Blocks)) {
        $Context.BlockIndex++
        $n=$Context.BlockIndex
        $text = if ($b.ContainsKey('text')) { Escape-AppShellHtml $b.text } else { '' }
        switch ($b.kind) {
            heading { $level=if ($b.level) { [int]$b.level } else { 2 }; [void]$result.Append("<h$level class=`"as-heading`">$text</h$level>") }
            text { [void]$result.Append('<p class="as-text">'+$text+'</p>') }
            caption { [void]$result.Append('<small class="as-caption">'+$text+'</small>') }
            code { [void]$result.Append('<pre class="as-code">'+$text+'</pre>') }
            badge { [void]$result.Append('<span class="as-badge">'+$text+'</span>') }
            notice { $tone=if ($b.tone) { [string]$b.tone } else { 'info' }; [void]$result.Append('<div role="status" class="as-notice as-notice-'+$tone+'">'+$text+'</div>') }
            divider { [void]$result.Append('<hr class="as-divider">') }
            { $_ -in @('row','column','card') } {
                [void]$result.Append('<div class="as-'+$b.kind+'">'+(Render-AppShellBlocks @($b.children) $Context)+'</div>')
            }
            { $_ -in @('input','textarea','checkbox','select') } {
                $id='as-field-'+$Context.Generation+'-'+$n
                $name=Escape-AppShellHtml $b.name
                $Context.Fields[[string]$b.name]=@{id=$id;kind=[string]$b.kind}
                [void]$result.Append('<div class="as-field"><label class="as-field-label" for="'+$id+'">'+(Escape-AppShellHtml $b.label)+'</label>')
                if ($b.kind -eq 'input') {
                    $kind=if ($b.password) { 'password' } else { 'text' }
                    [void]$result.Append('<input id="'+$id+'" name="'+$name+'" type="'+$kind+'" value="'+(Escape-AppShellHtml $b.value)+'" placeholder="'+(Escape-AppShellHtml $b.placeholder)+'">')
                } elseif ($b.kind -eq 'textarea') {
                    [void]$result.Append('<textarea id="'+$id+'" name="'+$name+'">'+(Escape-AppShellHtml $b.value)+'</textarea>')
                } elseif ($b.kind -eq 'checkbox') {
                    $check=if ($b.checked) { ' checked' } else { '' }
                    [void]$result.Append('<input id="'+$id+'" name="'+$name+'" type="checkbox"'+$check+'>')
                } else {
                    [void]$result.Append('<select id="'+$id+'" name="'+$name+'">')
                    foreach ($o in @($b.options)) {
                        $sel=if ([string]$o.value -ceq [string]$b.value) { ' selected' } else { '' }
                        [void]$result.Append('<option value="'+(Escape-AppShellHtml $o.value)+'"'+$sel+'>'+(Escape-AppShellHtml $o.label)+'</option>')
                    }
                    [void]$result.Append('</select>')
                }
                [void]$result.Append('</div>')
            }
            button {
                $id='as-button-'+$Context.Generation+'-'+$n
                $params=if ($b.params) { ConvertTo-AppShellTable $b.params } else { @{} }
                $Context.Actions[$id]=@{command=[string]$b.command;params=$params}
                [void]$result.Append('<button type="button" id="'+$id+'" class="as-button">'+$text+'</button>')
            }
            table {
                [void]$result.Append('<div class="as-table-wrap"><table class="as-table"><thead><tr>')
                foreach ($c in @($b.columns)) { [void]$result.Append('<th scope="col">'+(Escape-AppShellHtml $c.title)+'</th>') }
                [void]$result.Append('</tr></thead><tbody>')
                foreach ($row in @($b.rows)) {
                    [void]$result.Append('<tr>')
                    foreach ($c in @($b.columns)) {
                        $cell = $row[[string]$c.key]
                        # JSON booleans render like the Python edition (True/False), numbers invariantly.
                        $shown = if ($cell -is [bool]) { if ($cell) { 'True' } else { 'False' } }
                                 elseif ($cell -is [IFormattable]) { $cell.ToString($null, [Globalization.CultureInfo]::InvariantCulture) }
                                 else { $cell }
                        [void]$result.Append('<td>'+(Escape-AppShellHtml $shown)+'</td>')
                    }
                    [void]$result.Append('</tr>')
                }
                [void]$result.Append('</tbody></table></div>')
            }
            default { throw 'Unexpected view block after validation' }
        }
    }
    return $result.ToString()
}
function Start-AppShellRequest {
    param([hashtable]$Context,[string]$Operation,[hashtable]$Payload,[string]$ExtensionId,[int]$Generation,[string]$Risk='read')
    if ($Context.InFlight -ge $script:AppShellMaxInFlight) {
        Set-AppShellStatus $Context 'AppShell is busy with earlier requests; try again in a moment.'
        return $false
    }
    $record=$Context.State.registry.extensions[$ExtensionId]
    $call=@{ ModulePath=[string]$record.module; ExtensionId=$ExtensionId; Operation=$Operation; Payload=$Payload
             DataDirectory=(Join-Path (Join-Path $Context.Home 'extension-data') $ExtensionId); WorkerFile=$Context.WorkerFile
             TimeoutMilliseconds=$Context.WorkerTimeout; ModuleSearchPath=[string]$record.modules
             LogPath=(Join-Path (Join-Path $Context.Home 'logs') ($ExtensionId + '.log')) }
    $meta=@{ operation=$Operation; extension=$ExtensionId; generation=$Generation; risk=$Risk }
    # No task-level deadline: the worker call has its own timeout and kills the worker.
    $null=Start-NativeHTMLKitTask -Application $Context.Application -ArgumentList @($Context.ModuleManifest,$call,$meta) `
        -ScriptBlock $script:AppShellRequestTask -OnCompleted $script:AppShellOnRequestDone -OnFailed $script:AppShellOnRequestFailed
    $Context.InFlight++
    if ($Operation -eq 'action') { $Context.Busy = $true }
    Set-AppShellStatus $Context ('Running '+$Operation+'…')
    return $true
}
function Complete-AppShellRequest {
    param([hashtable]$Context,$Data)
    $Context.InFlight = [Math]::Max(0, $Context.InFlight - 1)
    Resume-AppShellDeferredPage $Context
    $item = @($Data)[0]
    $meta = $item.meta
    if ($meta.operation -eq 'action') { $Context.Busy = $false }
    $current = ($Context.Generation -eq $meta.generation -and $Context.Selected -and $Context.Selected.id -eq $meta.extension)
    if (-not $item.ok) {
        $msg = [string]$item.error
        if ($meta.risk -ne 'read' -and $msg -notlike 'EXTENSION_ERROR:*') {
            $msg = 'Outcome unknown for ' + $meta.extension + '; do not retry: ' + $msg
        }
        Set-AppShellStatus $Context ($msg.Substring(0, [Math]::Min(500, $msg.Length)))
        if ($current) {
            $notice = '<div class="as-notice as-notice-danger">'+(Escape-AppShellHtml $msg)+'</div>'
            if ($meta.operation -eq 'page') { Set-NativeHTMLKitDocumentHtml -Document $Context.Document -Element 'as-content' -Html $notice }
            else {
                # Keep the page visible; never retry a write whose outcome is unknown.
                $null = Invoke-NativeHTMLKitDocumentCommand $Context.Document 'insert_html' @{ element='as-content'; position='afterbegin'; html=$notice }
            }
        }
        return
    }
    try {
        if ($meta.operation -eq 'page') {
            if (-not $current) { return }
            $view=Assert-AppShellView $item.result $Context.State.manifests[$meta.extension]
            $Context.BlockIndex=0; $Context.Fields=@{}; $Context.Actions=@{}
            $html=Render-AppShellBlocks @($view.blocks) $Context
            Set-NativeHTMLKitDocumentText -Document $Context.Document -Element 'as-title' -Text $view.title
            Set-NativeHTMLKitDocumentHtml -Document $Context.Document -Element 'as-content' -Html $html
            $Context.PageReady = $true
            Set-AppShellStatus $Context 'Ready'
        } else {
            $result=Assert-AppShellResult $item.result
            $message = if ($result.ContainsKey('message')) { [string]$result.message } else { 'Action completed' }
            Set-AppShellStatus $Context $message
            if ($result.refresh -and $current) { Show-AppShellPage $Context $Context.Selected.id $Context.Selected.page }
        }
    } catch { Set-AppShellStatus $Context ('Extension response failed: '+$_.Exception.Message) }
}
function Fail-AppShellRequest {
    # Only for failures of the task machinery itself; worker errors arrive as results.
    param([hashtable]$Context,$Failure)
    $Context.InFlight = [Math]::Max(0, $Context.InFlight - 1)
    $Context.Busy = $false
    Resume-AppShellDeferredPage $Context
    Set-AppShellStatus $Context ('Background request failed; outcome unknown, do not retry automatically: ' + [string]$Failure.Message)
}
function Show-AppShellPage {
    param([hashtable]$Context,[string]$ExtensionId,[string]$PageId)
    if (-not $Context.State.manifests.ContainsKey($ExtensionId)) { return }
    $Context.Selected=@{id=$ExtensionId;page=$PageId}
    $Context.PageReady = $false
    Set-AppShellContent $Context $Context.State.manifests[$ExtensionId].title '<p class="as-caption">Loading extension page…</p>'
    Update-AppShellNav $Context
    $Context.DeferredPage = $null
    if ($Context.InFlight -ge $script:AppShellMaxInFlight) {
        # Only the latest navigation matters: load it as soon as a request slot frees up.
        $Context.DeferredPage = @{ id=$ExtensionId; page=$PageId; generation=$Context.Generation }
        return
    }
    $null = Start-AppShellRequest $Context 'page' @{page_id=$PageId} $ExtensionId $Context.Generation
}
function Resume-AppShellDeferredPage {
    param([hashtable]$Context)
    $next = $Context.DeferredPage
    if (-not $next -or $Context.InFlight -ge $script:AppShellMaxInFlight) { return }
    $Context.DeferredPage = $null
    if ($Context.Generation -eq $next.generation -and $Context.Selected -and $Context.Selected.id -eq $next.id) {
        $null = Start-AppShellRequest $Context 'page' @{page_id=$next.page} $next.id $next.generation
    }
}
function Invoke-AppShellAction {
    param([hashtable]$Context)
    if (-not $Context.Pending -or $Context.Busy) { return }
    $entry=$Context.Pending; $Context.Pending=$null
    if ($Context.Generation -ne $entry.generation -or -not $Context.Selected -or $Context.Selected.id -ne $entry.id) { return }
    $null = Start-AppShellRequest $Context 'action' @{command_id=$entry.command;values=$entry.values;params=$entry.params} $entry.id $Context.Generation $entry.risk
}
function Complete-AppShellConfirm {
    # Confirm, Cancel and Escape all end in the dialog's close event.
    param([hashtable]$Context,$Event)
    $confirmed = ([string]$Event.return_value) -eq 'ok'
    $origin = $Context.ConfirmOrigin; $Context.ConfirmOrigin = $null
    if (-not $confirmed) { $Context.Pending = $null; Set-AppShellStatus $Context 'Cancelled' }
    if ($origin -and $Context.Actions.ContainsKey($origin)) {
        try { Set-NativeHTMLKitFocus -Document $Context.Document -Element $origin } catch { }
    }
    if ($confirmed) { Invoke-AppShellAction $Context }
}
function Complete-AppShellBoot {
    param([hashtable]$Context,$Data)
    $Context.State=ConvertTo-AppShellTable @($Data)[0]
    $Context.BootCompleted=[bool]$Context.State.boot_complete
    $active = @($Context.State.status.Values | Where-Object { $_ -eq 'ACTIVE' }).Count
    $summary = "$active extensions active"
    if ($Context.State.errors.Count -gt 0) { $summary += ' · ' + $Context.State.errors.Count + ' errors' }
    if ($Context.State.safe_mode) { $summary += ' · safe mode' }
    if ($Context.Selected) { Update-AppShellNav $Context } else { Show-AppShellHome $Context }
    Set-AppShellStatus $Context $summary
}
function Complete-AppShellStage {
    param([hashtable]$Context,$Data)
    $item = @($Data)[0]
    if ($item.ok) { Set-AppShellStatus $Context 'Extension staged · Restart AppShell to install and activate'; Show-AppShellExtensions $Context }
    else { Set-AppShellStatus $Context ('Install request failed: ' + [string]$item.error) }
}
function Get-AppShellEventTarget {
    # The element itself or, for delegated clicks on a child, the nearest known id on its path.
    param([hashtable]$Context,$Event)
    foreach ($id in @(@([string]$Event.element) + @($Event.path))) {
        $s = [string]$id
        if (-not $s) { continue }
        if ($s -in @('as-home','as-extensions','as-settings','as-yes','as-no','as-restore','as-add') -or
            $Context.Nav.ContainsKey($s) -or $Context.Special.ContainsKey($s) -or $Context.Actions.ContainsKey($s)) { return $s }
    }
    return ''
}
function Invoke-AppShellClick {
    param([hashtable]$Context,$Event)
    $id = Get-AppShellEventTarget $Context $Event
    if (-not $id) { return }
    if ($id -eq 'as-home') { Show-AppShellHome $Context; return }
    if ($id -eq 'as-extensions') { Show-AppShellExtensions $Context; return }
    if ($id -eq 'as-settings') { Show-AppShellSettings $Context; return }
    if ($Context.Nav.ContainsKey($id)) { Show-AppShellPage $Context $Context.Nav[$id].id $Context.Nav[$id].page; return }
    if ($id -eq 'as-yes') { Show-NativeHTMLKitHtmlDialog -Document $Context.Document -Element 'as-confirm' -Close -ReturnValue 'ok'; return }
    if ($id -eq 'as-no') { Show-NativeHTMLKitHtmlDialog -Document $Context.Document -Element 'as-confirm' -Close -ReturnValue 'cancel'; return }
    if ($id -eq 'as-restore') {
        [IO.File]::WriteAllText((Join-Path $Context.Home 'restore-on-next-start'),'1')
        Set-AppShellStatus $Context 'Restore requested. Restart AppShell.'
        return
    }
    if ($Context.Special.ContainsKey($id)) {
        $op=$Context.Special[$id]
        Add-AppShellQueue $Context.Home @{action=$op.operation;id=$op.id}
        $verb = $op.operation.Substring(0,1).ToUpperInvariant() + $op.operation.Substring(1)
        Set-AppShellStatus $Context ($verb+' queued for '+$op.id+' · Restart required')
        return
    }
    if ($id -eq 'as-add') {
        if (-not (Get-NativeHTMLKitChecked -Document $Context.Document -Element 'as-trust')) {
            Set-AppShellStatus $Context 'Confirm that you trust this module source.'
            return
        }
        $source=([string](Get-NativeHTMLKitValue -Document $Context.Document -Element 'as-source')).Trim()
        if (-not $source) { Set-AppShellStatus $Context 'Enter a source first'; return }
        if ($Context.InFlight -ge $script:AppShellMaxInFlight) { Set-AppShellStatus $Context 'AppShell is busy; try again in a moment.'; return }
        $null=Start-NativeHTMLKitTask -Application $Context.Application -ArgumentList @($Context.ModuleManifest,$Context.Home,$source,(Get-Location).ProviderPath) -ScriptBlock {
            param($moduleFile,$stateHome,$src,$location)
            try {
                Import-Module -Name $moduleFile -Force -ErrorAction Stop
                Set-Location -LiteralPath $location
                if ($src -match '^([A-Za-z][A-Za-z0-9_.-]*)==(\d+(?:\.\d+){1,3})$') {
                    $null = Add-AppShellExtension -Name $matches[1] -RequiredVersion $matches[2] -Home $stateHome
                } else { $null = Add-AppShellExtension -SourcePath $src -Home $stateHome }
                @{ ok=$true }
            } catch { @{ ok=$false; error=[string]$_.Exception.Message } }
        } -OnCompleted $script:AppShellOnStaged
        Set-AppShellStatus $Context 'Staging module…'
        return
    }
    if (-not $Context.Actions.ContainsKey($id) -or -not $Context.Selected) { return }
    $action = $Context.Actions[$id]
    $manifest=$Context.State.manifests[$Context.Selected.id]
    $command=@(@($manifest.commands) | Where-Object { $_.id -ceq $action.command } | Select-Object -First 1)
    if ($command.Count -ne 1) { return }
    if ($Context.Busy) { Set-AppShellStatus $Context 'Another action is still running; wait for it to finish'; return }
    $values=@{}
    foreach ($name in @($Context.Fields.Keys)) {
        $field=$Context.Fields[$name]
        if ($field.kind -eq 'checkbox') {
            $values[$name]=[bool](Get-NativeHTMLKitChecked -Document $Context.Document -Element $field.id)
        } else {
            $values[$name]=[string](Get-NativeHTMLKitValue -Document $Context.Document -Element $field.id)
        }
    }
    $Context.Pending=@{ id=$Context.Selected.id;command=$action.command;values=$values;params=$action.params;
        risk=[string]$command[0].risk;generation=$Context.Generation }
    if ($command[0].risk -ne 'read') {
        $Context.ConfirmOrigin = $id
        Set-NativeHTMLKitDocumentText -Document $Context.Document -Element 'as-confirm-title' -Text $command[0].title
        Set-NativeHTMLKitDocumentText -Document $Context.Document -Element 'as-confirm-text' -Text $command[0].confirmation
        Show-NativeHTMLKitHtmlDialog -Document $Context.Document -Element 'as-confirm'
        # Explicit initial focus: Cancel for destructive commands, so Enter is safe.
        Set-NativeHTMLKitFocus -Document $Context.Document -Element $(if ($command[0].risk -eq 'destructive') { 'as-no' } else { 'as-yes' })
    } else { Invoke-AppShellAction $Context }
}
function Initialize-AppShellDesktop {
    # Mounts the shell window and starts the background boot. Returns the desktop context.
    param([switch]$SafeMode,[Alias('Home')][string]$AppShellHome,[Parameter(Mandatory)]$Application)
    Import-Module NativeHTMLKit.UI -ErrorAction Stop
    $root=Get-AppShellHome $AppShellHome
    Initialize-AppShellHome $root
    $lock = Enter-AppShellSession $root
    try {
        $css=[IO.File]::ReadAllText((Join-Path $script:AppShellModuleRoot 'Resources/appshell.css'))
        $ui=New-NHKUi -Title 'NativeHTMLKit AppShell' -Theme cobalt -Density compact -Width 1110 -Height 740 -ExtraCss $css
        $markup=@'
<div class="as-layout"><aside class="as-sidebar" aria-label="AppShell navigation">
<div class="as-brand">AppShell</div>
<button id="as-home" class="as-nav-link" type="button">Home</button>
<button id="as-extensions" class="as-nav-link" type="button">Extensions</button>
<button id="as-settings" class="as-nav-link" type="button">Settings</button>
<div id="as-nav" class="as-nav"></div>
</aside><section class="as-content-shell">
<header class="as-toolbar"><h2 id="as-title" class="as-heading">Home</h2></header>
<div id="as-content" class="as-content">Loading AppShell…</div>
</section></div><footer id="as-status" class="as-footer" role="status" aria-live="polite">Starting extensions…</footer>
<dialog id="as-confirm" aria-labelledby="as-confirm-title" aria-describedby="as-confirm-text"><h3 id="as-confirm-title">Confirm action</h3><p id="as-confirm-text"></p>
<div class="as-row"><button id="as-yes" type="button" class="as-button">Confirm</button>
<button id="as-no" type="button" class="as-button">Cancel</button></div></dialog>
'@
        $null=Add-NHKUiHtml -UI $ui -Markup $markup
        $Context=@{ Application=$Application; UI=$ui; Home=$root; Document=$null; SessionLock=$lock
            ModuleManifest=(Join-Path $script:AppShellModuleRoot 'NativeHTMLKit.AppShell.psd1')
            WorkerFile=(Join-Path $script:AppShellModuleRoot 'AppShell.Worker.ps1'); WorkerTimeout=30000
            State=@{registry=@{extensions=@{}};manifests=@{};errors=@{};status=@{};message='';safe_mode=[bool]$SafeMode}
            Generation=0;BlockIndex=0;Nav=@{};Actions=@{};Fields=@{};Special=@{};Selected=$null;Pending=$null
            ConfirmOrigin=$null;DeferredPage=$null;InFlight=0;Busy=$false;PageReady=$false;StatusText='';BootCompleted=$false
            BootTask=$null;Subscriptions=@() }
        $script:AppShellDesktop = $Context
        $null=Start-NHKUi -UI $ui -Application $Application
        $Context.Document=$ui.Document
        $Context.Subscriptions += ,(Register-NativeHTMLKitDocumentEvent -Document $Context.Document -Type click -Callback $script:AppShellOnClick)
        $Context.Subscriptions += ,(Register-NativeHTMLKitDocumentEvent -Document $Context.Document -Type close -Element 'as-confirm' -Callback $script:AppShellOnDialogClose)
        Show-AppShellHome $Context
        $Context.BootTask=Start-NativeHTMLKitTask -Application $Application -ArgumentList @($Context.ModuleManifest,$root,[bool]$SafeMode,$Context.WorkerFile) -ScriptBlock {
            param($moduleFile,$homeDir,$safe,$workerFile)
            Import-Module -Name $moduleFile -Force
            Invoke-AppShellBoot -Home $homeDir -SafeMode:$safe -WorkerFile $workerFile
        } -OnCompleted $script:AppShellOnBoot -OnFailed $script:AppShellOnBootFailed
        return $Context
    } catch {
        $lock.Dispose()
        $script:AppShellDesktop = $null
        throw
    }
}
function Close-AppShellDesktop {
    # Clean = the host shut down normally; otherwise the unclean marker stays for recovery.
    param([hashtable]$Context,[switch]$Clean)
    if (-not $Context) { return }
    try {
        foreach ($sub in @($Context.Subscriptions)) { try { Unregister-NativeHTMLKitDocumentEvent -Subscription $sub } catch { } }
        if ($Context.BootTask -and -not $Context.BootCompleted) { try { Stop-NativeHTMLKitTask -Task $Context.BootTask } catch { } }
        try { Stop-NHKUi -UI $Context.UI } catch { }
        if ($Clean) {
            $commit = $Context.BootCompleted -and -not $Context.State.safe_mode -and -not (@($Context.State.status.Values) -contains 'FAILED')
            try { Complete-AppShellSession $Context.Home -Commit:$commit } catch { Write-Warning "Could not save last-known-good state: $_" }
        }
    } finally {
        $Context.SessionLock.Dispose()
        if ($script:AppShellDesktop -eq $Context) { $script:AppShellDesktop = $null }
    }
}
function Start-AppShell {
    [CmdletBinding()]
    param([switch]$SafeMode,[Alias('Home')][string]$AppShellHome,$Application)
    if (-not $Application) {
        & (Join-Path $script:AppShellModuleRoot 'AppShell.Host.ps1') -SafeMode:$SafeMode -Home $AppShellHome
        return
    }
    $Context = Initialize-AppShellDesktop -SafeMode:$SafeMode -Home $AppShellHome -Application $Application
    $clean = $false
    try {
        Wait-NativeHTMLKit -Application $Application -UntilShutdown
        $clean = $true
    } finally {
        Close-AppShellDesktop $Context -Clean:$clean
    }
}
