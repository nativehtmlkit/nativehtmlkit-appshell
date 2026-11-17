# Standalone PowerShell module implementing the AppShell v1 contract.
# No Python, AppShell runtime module or NativeHTMLKit UI dependency.
function Invoke-AppShellExtension {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Operation,$Payload,$Context)
    $path = Join-Path $Context.data_dir 'message.txt'
    switch ($Operation) {
        'manifest' {
            return @{
                api_version = 1
                id = 'org.nativehtmlkit.examples.greeter'
                title = 'PowerShell Greeter'
                version = '0.1.0'
                pages = @(@{ id = 'overview'; title = 'Overview'; order = 10 })
                commands = @(
                    @{ id = 'refresh'; title = 'Refresh'; risk = 'read' }
                    @{ id = 'save'; title = 'Save text'; risk = 'write'; confirmation = 'Save this text to the extension data directory?' }
                )
            }
        }
        'page' {
            if ($Payload.page_id -ne 'overview') { throw 'Unknown page' }
            $value = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { 'Hello from PowerShell.' }
            return @{
                title = 'PowerShell Greeter'
                blocks = @(
                    @{ kind = 'heading'; text = 'PowerShell Greeter'; level = 2 }
                    @{ kind = 'text'; text = 'A standalone native PowerShell module extension.' }
                    @{ kind = 'input'; name = 'message'; label = 'Message'; value = [string]$value }
                    @{ kind = 'row'; children = @(
                        @{ kind = 'button'; text = 'Refresh'; command = 'refresh' }
                        @{ kind = 'button'; text = 'Save'; command = 'save' }
                    ) }
                )
            }
        }
        'action' {
            switch ($Payload.command_id) {
                'refresh' { return @{ message = 'Refreshed'; refresh = $true } }
                'save' {
                    $text = [string]$Payload.values.message
                    if ($text.Length -gt 10000) { throw 'Maximum length exceeded' }
                    $null = New-Item -ItemType Directory -Path $Context.data_dir -Force
                    [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
                    return @{ message = 'Saved'; refresh = $true }
                }
                default { throw 'Unknown command' }
            }
        }
        'shutdown' { return @{ closed = $true } }
        default { throw 'Unknown operation' }
    }
}
Export-ModuleMember -Function Invoke-AppShellExtension
