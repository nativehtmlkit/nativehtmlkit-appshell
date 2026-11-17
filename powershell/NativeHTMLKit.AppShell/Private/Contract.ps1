# Versioned language-neutral v1 contract. Avoid requiring JSON Schema/NPM at runtime.
function Assert-AppShellKeys {
    param($Object,[string[]]$Required,[string[]]$Allowed,[string]$Where)
    if ($Object -isnot [System.Collections.IDictionary]) { throw "$Where must be object" }
    foreach ($key in $Required) { if (-not $Object.Contains($key)) { throw "$Where missing $key" } }
    foreach ($key in $Object.Keys) { if ($Allowed -cnotcontains $key) { throw "$Where unknown field: $key" } }
}
function Assert-AppShellText {
    param($Value,[string]$Name,[int]$Length,[bool]$Nonempty=$false)
    if ($Value -isnot [string] -or $Value.Length -gt $Length -or ($Nonempty -and -not $Value.Trim())) {
        throw "$Name must be string (maximum $Length)"
    }
}
function Assert-AppShellSlug {
    param([string]$Value)
    if ($Value.Length -gt 64 -or $Value -cnotmatch '^[a-z][a-z0-9_-]*$') { throw "Invalid extension-local ID: $Value" }
}
function Assert-AppShellJsonSize {
    param($Value,[int]$Maximum,[string]$Kind)
    $json = $Value | ConvertTo-Json -Depth 50 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $Maximum) { throw "$Kind exceeds $Maximum bytes" }
}
function Assert-AppShellManifest {
    param($Manifest,[string]$ExpectedId,[string]$ExpectedVersion)
    $m = ConvertTo-AppShellTable $Manifest
    Assert-AppShellKeys $m @('api_version','id','title','version','pages') @('api_version','id','title','version','description','platforms','pages','commands') 'manifest'
    if (($m.api_version -isnot [int] -and $m.api_version -isnot [long]) -or $m.api_version -ne 1) { throw 'Unsupported manifest api_version' }
    Test-AppShellId ([string]$m.id)
    if ($m.id -cne $ExpectedId) { throw 'Manifest ID mismatches module metadata' }
    if ($m.version -cne $ExpectedVersion) { throw 'Manifest version mismatches module manifest' }
    Assert-AppShellText $m.title 'title' 120 $true
    Assert-AppShellText $m.version 'version' 100 $true
    if ($m.ContainsKey('description')) { Assert-AppShellText $m.description 'description' 2000 }
    if ($m.ContainsKey('platforms')) {
        if (@($m.platforms).Count -lt 1 -or @($m.platforms).Count -gt 2) { throw 'Invalid platforms count' }
        $target = if ($env:OS -eq 'Windows_NT') { 'windows' } else { 'linux' }
        if (@($m.platforms) -cnotcontains $target) { throw "Unsupported platform: $target" }
    }
    if (@($m.pages).Count -lt 1 -or @($m.pages).Count -gt 100) { throw 'pages length must be 1..100' }
    $ids = @{}
    foreach ($p in $m.pages) {
        Assert-AppShellKeys $p @('id','title') @('id','title','description','order') 'page'
        Assert-AppShellSlug $p.id
        if ($ids.ContainsKey($p.id)) { throw 'Duplicate page ID' }
        $ids[$p.id] = $true
        Assert-AppShellText $p.title 'page.title' 120 $true
        if ($p.ContainsKey('description')) { Assert-AppShellText $p.description 'page.description' 500 }
        if ($p.ContainsKey('order') -and (($p.order -isnot [int] -and $p.order -isnot [long]) -or $p.order -lt 0 -or $p.order -gt 9999)) { throw 'Invalid page.order' }
    }
    if (-not $m.ContainsKey('commands')) { $m.commands = @() }
    if (@($m.commands).Count -gt 100) { throw 'Too many commands' }
    $ids = @{}
    foreach ($c in @($m.commands)) {
        Assert-AppShellKeys $c @('id','title','risk') @('id','title','risk','confirmation') 'command'
        Assert-AppShellSlug $c.id
        if ($ids.ContainsKey($c.id)) { throw 'Duplicate command ID' }
        $ids[$c.id] = $true
        Assert-AppShellText $c.title 'command.title' 120 $true
        if (@('read','write','destructive') -cnotcontains $c.risk) { throw 'Invalid command risk' }
        if ($c.risk -ne 'read' -and -not $c.confirmation) { throw 'Write/destructive command requires confirmation' }
        if ($c.ContainsKey('confirmation')) { Assert-AppShellText $c.confirmation 'confirmation' 500 $true }
    }
    Assert-AppShellJsonSize $m 131072 'manifest'
    return ,$m
}
function Assert-AppShellView {
    param($View,$Manifest)
    $v = ConvertTo-AppShellTable $View
    Assert-AppShellKeys $v @('title','blocks') @('title','blocks') 'view'
    Assert-AppShellText $v.title 'view.title' 120 $true
    if (@($v.blocks).Count -gt 300) { throw 'Too many blocks' }
    $declared = @{}
    foreach ($c in @($Manifest.commands)) { $declared[$c.id] = $true }
    $fields = @{}
    $count = [ref]0
    foreach ($block in @($v.blocks)) { Assert-AppShellBlock $block $declared $fields $count 0 }
    Assert-AppShellJsonSize $v 1048576 'view'
    return ,$v
}
function Assert-AppShellBlock {
    param($Block,$Commands,$Fields,[ref]$Count,[int]$Depth)
    if ($Depth -gt 10) { throw 'View nesting too deep' }
    if ($Block -isnot [System.Collections.IDictionary]) { throw 'Block must be object' }
    $Count.Value++
    if ($Count.Value -gt 300) { throw 'View node count exceeded' }
    $kind = $Block.kind
    switch ($kind) {
        { $_ -in @('text','caption','code','badge','heading','notice') } {
            $allowed = @('kind','text')
            if ($kind -eq 'heading') { $allowed += 'level' }
            if ($kind -eq 'notice') { $allowed += 'tone' }
            Assert-AppShellKeys $Block @('kind','text') $allowed 'text block'
            $limit = if ($kind -eq 'heading') { 300 } elseif ($kind -eq 'notice') { 5000 } else { 10000 }
            Assert-AppShellText $Block.text 'block.text' $limit
            if ($kind -eq 'heading' -and $Block.ContainsKey('level') -and
                 (($Block.level -isnot [int] -and $Block.level -isnot [long]) -or $Block.level -lt 1 -or $Block.level -gt 4)) { throw 'Invalid heading level' }
            if ($kind -eq 'notice' -and $Block.ContainsKey('tone') -and @('info','success','warning','danger') -cnotcontains $Block.tone) { throw 'Invalid notice tone' }
            break
        }
        divider { Assert-AppShellKeys $Block @('kind') @('kind') 'divider'; break }
        { $_ -in @('row','column','card') } {
            Assert-AppShellKeys $Block @('kind','children') @('kind','children') 'container'
            if (@($Block.children).Count -gt 300) { throw 'Too many children' }
            foreach ($child in @($Block.children)) { Assert-AppShellBlock $child $Commands $Fields $Count ($Depth+1) }
            break
        }
        { $_ -in @('input','textarea','checkbox','select') } {
            $keys = switch ($kind) {
                input { @('kind','name','label','value','placeholder','password') }
                textarea { @('kind','name','label','value') }
                checkbox { @('kind','name','label','checked') }
                select { @('kind','name','label','value','options') }
            }
            $required = @('kind','name','label')
            if ($kind -eq 'select') { $required += 'options' }
            Assert-AppShellKeys $Block $required $keys 'form field'
            Assert-AppShellSlug $Block.name
            if ($Fields.ContainsKey($Block.name)) { throw 'Duplicate form field name' }
            $Fields[$Block.name] = $true
            if ($Fields.Count -gt 80) { throw 'Too many fields' }
            Assert-AppShellText $Block.label 'field.label' 200
            if ($kind -ne 'checkbox' -and $Block.ContainsKey('value')) { Assert-AppShellText $Block.value 'field.value' 10000 }
            if ($kind -eq 'checkbox' -and $Block.ContainsKey('checked') -and $Block.checked -isnot [bool]) { throw 'checked must be boolean' }
            if ($kind -eq 'input') {
                if ($Block.ContainsKey('placeholder')) { Assert-AppShellText $Block.placeholder 'placeholder' 200 }
                if ($Block.ContainsKey('password') -and $Block.password -isnot [bool]) { throw 'password must be boolean' }
            }
            if ($kind -eq 'select') {
                if (@($Block.options).Count -gt 100) { throw 'Too many options' }
                $values = @{}
                foreach ($opt in @($Block.options)) {
                    Assert-AppShellKeys $opt @('value','label') @('value','label') 'select option'
                    Assert-AppShellText $opt.value 'option.value' 200
                    Assert-AppShellText $opt.label 'option.label' 200
                    if ($values.ContainsKey($opt.value)) { throw 'Duplicate select option' }
                    $values[$opt.value] = $true
                }
                if ($Block.value -and -not $values.ContainsKey($Block.value)) { throw 'Selected option does not exist' }
            }
            break
        }
        button {
            Assert-AppShellKeys $Block @('kind','text','command') @('kind','text','command','params') 'button'
            Assert-AppShellSlug $Block.command
            Assert-AppShellText $Block.text 'button.text' 200
            if (-not $Commands.ContainsKey($Block.command)) { throw 'Button references undeclared command' }
            if ($Block.ContainsKey('params') -and $Block.params -isnot [System.Collections.IDictionary]) { throw 'Button params must be object' }
            break
        }
        table {
            Assert-AppShellKeys $Block @('kind','columns','rows') @('kind','columns','rows') 'table'
            if (@($Block.columns).Count -gt 24 -or @($Block.rows).Count -gt 200) { throw 'Table exceeds bounds' }
            $keys = @{}
            foreach ($col in @($Block.columns)) {
                Assert-AppShellKeys $col @('key','title') @('key','title') 'column'
                Assert-AppShellSlug $col.key
                Assert-AppShellText $col.title 'column.title' 120
                if ($keys.ContainsKey($col.key)) { throw 'Duplicate column' }
                $keys[$col.key]=$true
            }
            foreach ($row in @($Block.rows)) {
                if ($row -isnot [System.Collections.IDictionary]) { throw 'Table row must be object' }
                foreach ($cell in $row.Values) {
                    if ($null -ne $cell -and $cell -isnot [string] -and $cell -isnot [ValueType]) { throw 'Table cells must be scalar' }
                }
            }
            break
        }
        default { throw "Unsupported view block: $kind" }
    }
}
function Assert-AppShellResult {
    param($Value)
    $r = ConvertTo-AppShellTable $Value
    Assert-AppShellKeys $r @() @('message','refresh') 'action result'
    if ($r.ContainsKey('message')) { Assert-AppShellText $r.message 'message' 500 }
    if ($r.ContainsKey('refresh') -and $r.refresh -isnot [bool]) { throw 'refresh must be boolean' }
    return ,$r
}
