# The desktop layer uses only public NativeHTMLKit PowerShell SDK/UI APIs.
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
    Set-NativeHTMLKitDocumentText -Document $Context.Document -Element 'as-status' -Text $Message
}
function Update-AppShellNav {
    param([hashtable]$Context)
    $Context.Nav=@{}
    $html = '<div class="as-nav-heading">Installed</div>'
    $i=0
    foreach ($id in @($Context.State.manifests.Keys | Sort-Object)) {
        if ($Context.State.status[$id] -ne 'ACTIVE') { continue }
        $manifest = $Context.State.manifests[$id]
        foreach ($page in @($manifest.pages | Sort-Object { $_.order }, { $_.id })) {
            $key="as-nav-$i"; $i++
            $Context.Nav[$key]=@{ id=$id; page=$page.id }
            $html += ('<button type="button" class="as-nav-item" id="' + $key + '">' + (Escape-AppShellHtml $page.title) + '</button>')
        }
    }
    Set-NativeHTMLKitDocumentHtml -Document $Context.Document -Element 'as-nav' -Html $html
}
function Show-AppShellHome {
    param([hashtable]$Context)
    $Context.Selected=$null
    $intro = '<p class="as-text">NativeHTMLKit AppShell — native PowerShell edition. No Python required.</p>'
    if ($Context.State.message) { $intro += '<div class="as-notice">' + (Escape-AppShellHtml $Context.State.message) + '</div>' }
    if ($Context.State.errors.Count -gt 0) { $intro += '<div class="as-notice as-danger">There are ' + $Context.State.errors.Count + ' extension errors. Open Extensions for diagnostics.</div>' }
    $intro += '<div class="as-card">Add a PowerShell module in the Extensions page or copy it to the extensions folder. Restart to activate it.</div>'
    Set-AppShellContent $Context 'Home' $intro
}
function Show-AppShellExtensions {
    param([hashtable]$Context)
    $Context.Selected=$null
    $markup = '<p class="as-text">Add a folder or a pinned PSGallery source (Name==Version). Restart required.</p>' +
              '<div class="as-card"><label for="as-source">Module folder or Name==Version</label>' +
              '<input type="text" id="as-source" placeholder="./MyExtension or My.Module==1.2.3">' +
              '<label class="as-field-label"><input type="checkbox" id="as-trust"> I trust this module to execute with my user permissions.</label>' +
              '<button type="button" id="as-add" class="as-button">Add on restart</button></div>'
    $actions = @{}
    $i=0
    foreach ($id in @($Context.State.registry.extensions.Keys | Sort-Object)) {
        $record = $Context.State.registry.extensions[$id]
        $status = if ($Context.State.status.ContainsKey($id)) { $Context.State.status[$id] } else { 'NOT LOADED' }
        $toggle=if ($record.enabled -eq $false) { 'enable' } else { 'disable' }
        $toggleKey = 'as-toggle-'+$i; $removeKey='as-remove-'+$i; $i++
        $actions[$toggleKey]=@{operation=$toggle;id=$id}
        $actions[$removeKey]=@{operation='remove';id=$id}
        $markup += '<div class="as-card"><b>' + (Escape-AppShellHtml $id) + '</b><p class="as-muted">' +
            (Escape-AppShellHtml ([string]$record.version + ' · ' + $status)) + '</p>' +
            '<button type="button" id="'+$toggleKey+'" class="as-button">' + $toggle + '</button>' +
            '<button type="button" id="'+$removeKey+'" class="as-button">remove</button></div>'
    }
    foreach ($key in @($Context.State.errors.Keys)) {
        $markup += '<div class="as-notice as-danger">'+(Escape-AppShellHtml ($key + ': ' + $Context.State.errors[$key]))+'</div>'
    }
    Set-AppShellContent $Context 'Extensions' $markup
    $Context.Special=$actions
}
function Show-AppShellSettings {
    param([hashtable]$Context)
    $Context.Selected=$null
    $markup = '<div class="as-card"><h3>Local paths</h3><p>'+(Escape-AppShellHtml $Context.Home)+'</p>' +
              '<p>No accounts, telemetry or external server.</p><button id="as-restore" class="as-button" type="button">Restore last known good on restart</button></div>'
    Set-AppShellContent $Context 'Settings' $markup
}
function Render-AppShellBlocks {
    param([object[]]$Blocks,[hashtable]$Context)
    $result=''
    foreach ($b in @($Blocks)) {
        $Context.BlockIndex++
        $n=$Context.BlockIndex
        $text = if ($b.ContainsKey('text')) { Escape-AppShellHtml $b.text } else { '' }
        switch ($b.kind) {
            heading { $level=if ($b.level) { [int]$b.level } else { 2 }; $result+="<h$level class='as-heading'>$text</h$level>" }
            text { $result+='<p class="as-text">'+$text+'</p>' }
            caption { $result+='<small class="as-muted">'+$text+'</small>' }
            code { $result+='<pre class="as-code">'+$text+'</pre>' }
            badge { $result+='<span class="as-badge">'+$text+'</span>' }
            notice { $tone=if ($b.tone) { $b.tone } else { 'info' }; $result+='<div class="as-notice as-'+$tone+'">'+$text+'</div>' }
            divider { $result+='<hr class="as-divider">' }
            { $_ -in @('row','column','card') } {
                $result += '<div class="as-'+$b.kind+'">'+(Render-AppShellBlocks $b.children $Context)+'</div>'
            }
            { $_ -in @('input','textarea','checkbox','select') } {
                $id='as-f-'+$Context.Generation+'-'+$n
                $name=Escape-AppShellHtml $b.name
                $label=Escape-AppShellHtml $b.label
                $Context.Fields[$b.name]=@{id=$id;kind=$b.kind}
                $result += '<div class="as-field"><label for="'+$id+'">'+$label+'</label>'
                if ($b.kind -eq 'input') {
                    $kind=if ($b.password) { 'password' } else { 'text' }
                    $result+='<input id="'+$id+'" name="'+$name+'" type="'+$kind+'" value="'+(Escape-AppShellHtml $b.value)+'" placeholder="'+(Escape-AppShellHtml $b.placeholder)+'">'
                } elseif ($b.kind -eq 'textarea') {
                    $result+='<textarea id="'+$id+'" name="'+$name+'">'+(Escape-AppShellHtml $b.value)+'</textarea>'
                } elseif ($b.kind -eq 'checkbox') {
                    $check=if ($b.checked) { 'checked' } else { '' }
                    $result+='<input id="'+$id+'" name="'+$name+'" type="checkbox" '+$check+'>'
                } else {
                    $result+='<select id="'+$id+'" name="'+$name+'">'
                    foreach ($o in @($b.options)) {
                        $sel=if ($o.value -ceq $b.value) { 'selected' } else { '' }
                        $result+='<option value="'+(Escape-AppShellHtml $o.value)+'" '+$sel+'>'+(Escape-AppShellHtml $o.label)+'</option>'
                    }
                    $result+='</select>'
                }
                $result+='</div>'
            }
            button {
                $id='as-b-'+$Context.Generation+'-'+$n
                $params=if ($b.params) { ConvertTo-AppShellTable $b.params } else { @{} }
                $Context.Actions[$id]=@{command=$b.command;params=$params}
                $result+='<button type="button" id="'+$id+'" class="as-button">'+$text+'</button>'
            }
            table {
                $result+='<div class="as-table-wrap"><table class="as-table"><thead><tr>'
                foreach ($c in @($b.columns)) { $result+='<th>'+(Escape-AppShellHtml $c.title)+'</th>' }
                $result+='</tr></thead><tbody>'
                foreach ($row in @($b.rows)) {
                    $result+='<tr>'
                    foreach ($c in @($b.columns)) { $result+='<td>'+(Escape-AppShellHtml $row[$c.key])+'</td>' }
                    $result+='</tr>'
                }
                $result+='</tbody></table></div>'
            }
            default { throw 'Unexpected view block after validation' }
        }
    }
    return $result
}
function Invoke-AppShellAsyncRequest {
    param([hashtable]$Context,[string]$Operation,[hashtable]$Payload,[string]$ExtensionId,[int]$Generation,[string]$Risk='read')
    $record=$Context.State.registry.extensions[$ExtensionId]
    $params=@($Context.ModuleManifest,$record.module,$ExtensionId,(Join-Path (Join-Path $Context.Home 'extension-data') $ExtensionId),$Operation,$Payload,$Context.WorkerFile)
    Set-AppShellStatus $Context ('Running '+$Operation+'…')
    $callbackContext=$Context
    $callback = {
        param($data)
        $ctx=$callbackContext
        if ($ctx.Generation -ne $Generation -or -not $ctx.Selected -or $ctx.Selected.id -ne $ExtensionId) { return }
        try {
            $received=ConvertTo-AppShellTable $data[0]
            if ($Operation -eq 'page') {
                $manifest=$ctx.State.manifests[$ExtensionId]
                $view=Assert-AppShellView $received $manifest
                $ctx.BlockIndex=0; $ctx.Fields=@{}; $ctx.Actions=@{}
                $html=Render-AppShellBlocks $view.blocks $ctx
                Set-NativeHTMLKitDocumentText -Document $ctx.Document -Element 'as-title' -Text $view.title
                Set-NativeHTMLKitDocumentHtml -Document $ctx.Document -Element 'as-content' -Html $html
                Set-AppShellStatus $ctx 'Ready'
            } else {
                $result=Assert-AppShellResult $received
                Set-AppShellStatus $ctx ([string]$result.message)
                if ($result.refresh -and $ctx.Selected) { Show-AppShellPage $ctx $ctx.Selected.id $ctx.Selected.page }
            }
        } catch { Set-AppShellStatus $ctx ('Extension response failed: '+$_.Exception.Message) }
    }.GetNewClosure()
    $failCallback = {
        param($failure)
        $ctx=$callbackContext
        $msg=[string]$failure.Message
        if ($Risk -ne 'read' -and $msg -notlike 'EXTENSION_ERROR:*') {
            $msg='Outcome unknown — do not retry the write automatically. '+$msg
        }
        Set-AppShellStatus $ctx $msg
        if ($Operation -eq 'page' -and $ctx.Generation -eq $Generation) {
            Set-NativeHTMLKitDocumentHtml -Document $ctx.Document -Element 'as-content' -Html ('<div class="as-notice as-danger">'+(Escape-AppShellHtml $msg)+'</div>')
        }
    }.GetNewClosure()
    $null=Start-NativeHTMLKitTask -Application $Context.Application -ArgumentList $params -TimeoutMilliseconds 40000 -ScriptBlock {
        param($moduleManifest,$path,$extension,$dataDir,$op,$payload,$workerFile)
        Import-Module -Name $moduleManifest -Force
        Invoke-AppShellWorker -ModulePath $path -ExtensionId $extension -DataDirectory $dataDir -Operation $op -Payload $payload -WorkerFile $workerFile -TimeoutMilliseconds 30000
    } -OnCompleted $callback -OnFailed $failCallback
}
function Show-AppShellPage {
    param([hashtable]$Context,[string]$ExtensionId,[string]$PageId)
    if (-not $Context.State.manifests.ContainsKey($ExtensionId)) { return }
    $Context.Selected=@{id=$ExtensionId;page=$PageId}
    Set-AppShellContent $Context $Context.State.manifests[$ExtensionId].title '<p class="as-muted">Loading extension page…</p>'
    Invoke-AppShellAsyncRequest $Context 'page' @{page_id=$PageId} $ExtensionId $Context.Generation
}
function Invoke-AppShellAction {
    param([hashtable]$Context)
    if (-not $Context.Pending) { return }
    $entry=$Context.Pending; $Context.Pending=$null
    if ($Context.Generation -ne $entry.generation -or -not $Context.Selected -or $Context.Selected.id -ne $entry.id) { return }
    Invoke-AppShellAsyncRequest $Context 'action' @{command_id=$entry.command;values=$entry.values;params=$entry.params} $entry.id $Context.Generation $entry.risk
}
function Invoke-AppShellClick {
    param([hashtable]$Context,$Event)
    $id=[string]$Event.element
    if ($id -eq 'as-home') { Show-AppShellHome $Context; return }
    if ($id -eq 'as-extensions') { Show-AppShellExtensions $Context; return }
    if ($id -eq 'as-settings') { Show-AppShellSettings $Context; return }
    if ($Context.Nav.ContainsKey($id)) { Show-AppShellPage $Context $Context.Nav[$id].id $Context.Nav[$id].page; return }
    if ($id -eq 'as-yes') {
        Show-NativeHTMLKitHtmlDialog -Document $Context.Document -Element 'as-confirm' -Close
        Invoke-AppShellAction $Context
        return
    }
    if ($id -eq 'as-no') {
        $Context.Pending=$null
        Show-NativeHTMLKitHtmlDialog -Document $Context.Document -Element 'as-confirm' -Close
        return
    }
    if ($id -eq 'as-restore') {
        [IO.File]::WriteAllText((Join-Path $Context.Home 'restore-on-next-start'),'1')
        Set-AppShellStatus $Context 'Restore requested for next restart.'
        return
    }
    if ($Context.Special.ContainsKey($id)) {
        $op=$Context.Special[$id]
        Add-AppShellQueue $Context.Home @{action=$op.operation;id=$op.id}
        Set-AppShellStatus $Context ($op.operation+' requested; restart required.')
        return
    }
    if ($id -eq 'as-add') {
        if (-not (Get-NativeHTMLKitChecked -Document $Context.Document -Element 'as-trust')) {
            Set-AppShellStatus $Context 'Confirm that you trust this module source.'
            return
        }
        $source=Get-NativeHTMLKitValue -Document $Context.Document -Element 'as-source'
        $source=$source.Trim()
        $moduleManifest=$Context.ModuleManifest
        $stateHome=$Context.Home
        $callbackContext=$Context
        $complete={ param($result) Set-AppShellStatus $callbackContext 'Extension staged. Restart required.' }.GetNewClosure()
        $failed={ param($err) Set-AppShellStatus $callbackContext ('Stage failed: '+$err.Message) }.GetNewClosure()
        $null=Start-NativeHTMLKitTask -Application $Context.Application -ArgumentList @($moduleManifest,$stateHome,$source) -TimeoutMilliseconds 60000 -ScriptBlock {
            param($moduleFile,$h,$src)
            Import-Module -Name $moduleFile -Force
            if ($src -match '^([A-Za-z][A-Za-z0-9_.-]*)==(\d+(?:\.\d+){1,3})$') {
                Add-AppShellExtension -Name $matches[1] -RequiredVersion $matches[2] -Home $h
            } else { Add-AppShellExtension -SourcePath $src -Home $h }
        } -OnCompleted $complete -OnFailed $failed
        Set-AppShellStatus $Context 'Staging module…'
        return
    }
    if (-not $Context.Actions.ContainsKey($id) -or -not $Context.Selected) { return }
    $action = $Context.Actions[$id]
    $manifest=$Context.State.manifests[$Context.Selected.id]
    $command=@($manifest.commands | Where-Object { $_.id -ceq $action.command } | Select-Object -First 1)
    if ($command.Count -ne 1) { return }
    $values=@{}
    foreach ($name in $Context.Fields.Keys) {
        $field=$Context.Fields[$name]
        if ($field.kind -eq 'checkbox') {
            $values[$name]=[bool](Get-NativeHTMLKitChecked -Document $Context.Document -Element $field.id)
        } else {
            $values[$name]=[string](Get-NativeHTMLKitValue -Document $Context.Document -Element $field.id)
        }
    }
    $Context.Pending=@{ id=$Context.Selected.id;command=$action.command;values=$values;params=$action.params;
        risk=$command[0].risk;generation=$Context.Generation }
    if ($command[0].risk -ne 'read') {
        Set-NativeHTMLKitDocumentText -Document $Context.Document -Element 'as-confirm-title' -Text $command[0].title
        Set-NativeHTMLKitDocumentText -Document $Context.Document -Element 'as-confirm-text' -Text $command[0].confirmation
        Show-NativeHTMLKitHtmlDialog -Document $Context.Document -Element 'as-confirm'
    } else { Invoke-AppShellAction $Context }
}
function Start-AppShell {
    [CmdletBinding()]
    param([switch]$SafeMode,[Alias('Home')][string]$AppShellHome,$Application)
    if (-not $Application) {
        & (Join-Path $script:AppShellModuleRoot 'AppShell.Host.ps1') -SafeMode:$SafeMode -Home $AppShellHome
        return
    }
    Import-Module NativeHTMLKit.UI -ErrorAction Stop
    $root=Get-AppShellHome $AppShellHome
    Initialize-AppShellHome $root
    $css=[IO.File]::ReadAllText((Join-Path $script:AppShellModuleRoot 'Resources/appshell.css'))
    $ui=New-NHKUi -Title 'NativeHTMLKit AppShell' -Theme cobalt -Density compact -Width 1110 -Height 740 -ExtraCss $css
    $markup=@'
<div class="as-layout"><aside class="as-sidebar">
<div class="as-brand">AppShell</div>
<button id="as-home" class="as-nav-item" type="button">Home</button>
<button id="as-extensions" class="as-nav-item" type="button">Extensions</button>
<button id="as-settings" class="as-nav-item" type="button">Settings</button>
<div id="as-nav"></div>
</aside><section class="as-content-shell">
<header class="as-toolbar"><h2 id="as-title">Home</h2></header>
<div id="as-content">Loading extensions…</div>
</section></div><footer id="as-status" class="as-footer">Starting…</footer>
<dialog id="as-confirm"><h3 id="as-confirm-title">Confirm</h3><p id="as-confirm-text"></p>
<button id="as-yes" type="button" class="as-button">Confirm</button>
<button id="as-no" type="button" class="as-button">Cancel</button></dialog>
'@
    $null=Add-NHKUiHtml -UI $ui -Markup $markup
    $Context=@{ Application=$Application; UI=$ui; Home=$root; Document=$null;
        ModuleManifest=(Join-Path $script:AppShellModuleRoot 'NativeHTMLKit.AppShell.psd1');
        WorkerFile=(Join-Path $script:AppShellModuleRoot 'AppShell.Worker.ps1');
        State=@{registry=@{extensions=@{}};manifests=@{};errors=@{};status=@{};message=''};
        Generation=0;BlockIndex=0;Nav=@{};Actions=@{};Fields=@{};Special=@{};Selected=$null;Pending=$null;BootCompleted=$false }
    $subscription=$null
    try {
        $null=Start-NHKUi -UI $ui -Application $Application
        $Context.Document=$ui.Document
        $callbackContext=$Context
        $onClick={ param($evt) Invoke-AppShellClick $callbackContext $evt }.GetNewClosure()
        $subscription=Register-NativeHTMLKitDocumentEvent -Document $Context.Document -Type click -Callback $onClick
        Show-AppShellHome $Context
        $moduleManifest=$Context.ModuleManifest
        $worker=$Context.WorkerFile
        $onBoot={
            param($data)
            $callbackContext.State=ConvertTo-AppShellTable $data[0]
            $callbackContext.BootCompleted=$true
            Update-AppShellNav $callbackContext
            Show-AppShellHome $callbackContext
            Set-AppShellStatus $callbackContext ('Activated '+$callbackContext.State.manifests.Count+' extensions')
        }.GetNewClosure()
        $bootFailed={
            param($failure)
            Set-AppShellStatus $callbackContext ('Boot failed: '+$failure.Message)
        }.GetNewClosure()
        $null=Start-NativeHTMLKitTask -Application $Application -ArgumentList @($moduleManifest,$root,[bool]$SafeMode,$worker) -TimeoutMilliseconds 300000 -ScriptBlock {
            param($moduleFile,$homeDir,$safe,$workerFile)
            Import-Module -Name $moduleFile -Force
            Invoke-AppShellBoot -Home $homeDir -SafeMode:$safe -WorkerFile $workerFile
        } -OnCompleted $onBoot -OnFailed $bootFailed
        Wait-NativeHTMLKit -Application $Application -UntilShutdown
    } finally {
        if ($subscription) { Unregister-NativeHTMLKitDocumentEvent -Subscription $subscription }
        Stop-NHKUi -UI $ui
        try { Complete-AppShellSession $root -Commit:($Context.BootCompleted -and -not $Context.State.safe_mode -and -not (@($Context.State.status.Values) -contains 'FAILED')) } catch { Write-Warning "Could not save last-known-good state: $_" }
    }
}
