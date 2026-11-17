# Test extension for the AppShell desktop scenario. Not shipped.
$script:Hostile = '<script>alert(1)</script> & " '' <b>bold</b>'
function Invoke-AppShellExtension {
    param([string]$Operation, $Payload, $Context)
    $data = $Context.data_dir
    $saved = Join-Path $data 'saved.txt'
    $count = Join-Path $data 'count.txt'
    switch ($Operation) {
        'manifest' {
            return @{ api_version = 1; id = 'org.example.showcase'; title = 'Showcase'; version = '0.1.0'
                pages = @(@{ id = 'controls'; title = 'Controls'; order = 1 }, @{ id = 'second'; title = 'Second page'; order = 2 })
                commands = @(
                    @{ id = 'echo'; title = 'Echo'; risk = 'read' },
                    @{ id = 'save'; title = 'Save values'; risk = 'write'; confirmation = 'Save the form values?' },
                    @{ id = 'wipe'; title = 'Wipe data'; risk = 'destructive'; confirmation = 'Delete the saved values?' },
                    @{ id = 'crash_write'; title = 'Crash while writing'; risk = 'write'; confirmation = 'Start a write that crashes?' },
                    @{ id = 'count'; title = 'Count'; risk = 'read' }) }
        }
        'page' {
            if ($Payload.page_id -eq 'second') { return @{ title = 'Second page'; blocks = @(@{ kind = 'text'; text = 'second page body' }) } }
            $savedText = if (Test-Path -LiteralPath $saved) { [IO.File]::ReadAllText($saved) } else { '' }
            $n = if (Test-Path -LiteralPath $count) { [IO.File]::ReadAllText($count) } else { '0' }
            $cafe = "caf$([char]0xE9) $([char]0x4E2D)"
            return @{ title = 'Controls'; blocks = @(
                @{ kind = 'heading'; text = ('Level one ' + $script:Hostile); level = 1 },
                @{ kind = 'heading'; text = 'Level four'; level = 4 },
                @{ kind = 'text'; text = ('Saved: ' + $savedText) },
                @{ kind = 'caption'; text = ('Count: ' + $n) },
                @{ kind = 'code'; text = ("line 1`n  line 2 " + $script:Hostile) },
                @{ kind = 'badge'; text = 'beta' },
                @{ kind = 'notice'; text = 'info notice' },
                @{ kind = 'notice'; text = 'danger notice'; tone = 'danger' },
                @{ kind = 'divider' },
                @{ kind = 'card'; children = @(@{ kind = 'row'; children = @(
                    @{ kind = 'column'; children = @(
                        @{ kind = 'input'; name = 'title'; label = ('Title ' + $script:Hostile); value = $cafe; placeholder = ('Type ' + $script:Hostile) },
                        @{ kind = 'input'; name = 'secret'; label = 'Secret'; password = $true }) },
                    @{ kind = 'column'; children = @(
                        @{ kind = 'textarea'; name = 'notes'; label = 'Notes'; value = "a`nb" },
                        @{ kind = 'checkbox'; name = 'agree'; label = 'Agree'; checked = $true },
                        @{ kind = 'select'; name = 'level'; label = 'Level'; value = 'two'; options = @(
                            @{ value = 'one'; label = 'One' }, @{ value = 'two'; label = 'Two' },
                            @{ value = 'x"<'; label = ('Odd ' + $script:Hostile) }) }) }) }) },
                @{ kind = 'table'; columns = @(@{ key = 'name'; title = 'Name' }, @{ key = 'n'; title = 'N' })
                   rows = @(@{ name = $script:Hostile; n = 1 }, @{ name = $null; n = 2.5 }, @{ name = $true }) },
                @{ kind = 'row'; children = @(
                    @{ kind = 'button'; text = 'Echo'; command = 'echo'; params = @{ p = "param $([char]0xE9)" } },
                    @{ kind = 'button'; text = 'Save'; command = 'save' },
                    @{ kind = 'button'; text = 'Wipe'; command = 'wipe' },
                    @{ kind = 'button'; text = 'Crash write'; command = 'crash_write' },
                    @{ kind = 'button'; text = 'Count'; command = 'count' }) }) }
        }
        'action' {
            $null = New-Item -ItemType Directory -Path $data -Force
            $utf8 = New-Object Text.UTF8Encoding($false)
            switch ($Payload.command_id) {
                'echo' {
                    $parts = @($Payload.values.PSObject.Properties | Sort-Object Name | ForEach-Object { $_.Name + '=' + [string]$_.Value })
                    return @{ message = ('echo ' + ($parts -join ',') + ' params=' + $Payload.params.p) }
                }
                'save' { [IO.File]::WriteAllText($saved, [string]$Payload.values.title, $utf8); return @{ message = 'Saved'; refresh = $true } }
                'wipe' { Remove-Item -LiteralPath $saved -ErrorAction SilentlyContinue; return @{ message = 'Wiped'; refresh = $true } }
                'crash_write' { [IO.File]::WriteAllText((Join-Path $data 'crash-write.txt'), 'partial', $utf8); [Environment]::Exit(9) }
                'count' {
                    $value = if (Test-Path -LiteralPath $count) { [int][IO.File]::ReadAllText($count) + 1 } else { 1 }
                    [IO.File]::WriteAllText($count, [string]$value, $utf8)
                    return @{ message = "count $value"; refresh = $true }
                }
                default { throw 'unknown command' }
            }
        }
        default { return @{} }
    }
}
Export-ModuleMember -Function Invoke-AppShellExtension
