#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Tests the functions of AppIntBlocker.ps1 against a firewall kept in memory. The script itself is
# an interactive menu that needs administrator rights, so the tests load only its settings and its
# functions (read from the script's syntax tree, nothing is run), and replace the firewall cmdlets
# with functions of the same name: no real firewall rule is read or written, on any machine.

BeforeAll {
    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AppIntBlocker.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw "AppIntBlocker.ps1 does not parse: $($parseErrors[0].Message)" }

    # The settings at the top ($RuleNamePrefix, the colors), then every function. The log goes to
    # TestDrive instead of next to the script.
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and $statement.Extent.Text -notmatch 'PSScriptRoot') {
            . ([scriptblock]::Create($statement.Extent.Text))
        }
    }
    $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($function in $functions) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $script:LogFilePath = Join-Path $TestDrive 'AppBlocker.log'

    # The firewall, in memory. Get-NetFirewallRule -DisplayName takes wildcards, as the real one does.
    $script:Rules = [System.Collections.Generic.List[object]]::new()
    $script:Refused = @()
    function Get-NetFirewallRule {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Rest', Justification = 'Takes the arguments the stand-in ignores.')]
        param([string]$DisplayName = '*', [Parameter(ValueFromRemainingArguments)]$Rest)
        @($script:Rules | Where-Object { $_.DisplayName -like $DisplayName })
    }
    function New-NetFirewallRule {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Rest', Justification = 'Takes the arguments the stand-in ignores.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A stand-in for the cmdlet; it changes a list in memory.')]
        param([string]$DisplayName, [string]$Direction, [string]$Program, [Parameter(ValueFromRemainingArguments)]$Rest)
        if ($script:Refused -contains $DisplayName) { throw "The firewall refused '$DisplayName'." }
        $rule = [pscustomobject]@{ DisplayName = $DisplayName; Direction = $Direction; Program = $Program }
        $script:Rules.Add($rule)
        $rule
    }
    function Remove-NetFirewallRule {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Rest', Justification = 'Takes the arguments the stand-in ignores.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A stand-in for the cmdlet; it changes a list in memory.')]
        param([Parameter(ValueFromPipeline)]$InputObject, [Parameter(ValueFromRemainingArguments)]$Rest)
        process { [void]$script:Rules.Remove($InputObject) }
    }

    # Makes empty files under TestDrive and returns the folder.
    function New-AppFolder {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A test helper that only writes under TestDrive.')]
        param([string]$Name, [string[]]$Files)
        $root = Join-Path $TestDrive $Name
        foreach ($file in $Files) {
            $path = Join-Path $root $file
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
            [System.IO.File]::WriteAllText($path, '')
        }
        $root
    }

    function Get-RuleName { @($script:Rules | ForEach-Object DisplayName | Sort-Object) }
}

Describe 'AppIntBlocker.ps1' {
    BeforeEach {
        $script:Rules.Clear()
        $script:Refused = @()
    }

    Describe 'Block-Application' {
        It 'blocks every .exe in the folder and its subfolders, both ways, and nothing else' {
            $app = New-AppFolder 'Demo' @('demo.exe', 'bin\helper.exe', 'bin\engine.dll', 'readme.txt')

            Block-Application -ApplicationPath $app -ApplicationName 'Demo' 6>$null 3>$null

            Get-RuleName | Should -Be @(
                'AppBlocker Rule -Demo - bin\helper.exe (Inbound)'.Replace('\', [System.IO.Path]::DirectorySeparatorChar)
                'AppBlocker Rule -Demo - bin\helper.exe (Outbound)'.Replace('\', [System.IO.Path]::DirectorySeparatorChar)
                'AppBlocker Rule -Demo - demo.exe (Inbound)'
                'AppBlocker Rule -Demo - demo.exe (Outbound)'
            )
            ($script:Rules | Where-Object DisplayName -like '*demo.exe (Inbound)').Program | Should -Be (Join-Path $app 'demo.exe')
        }

        It 'keeps rules that are there and adds none twice' {
            $app = New-AppFolder 'Again' @('again.exe')
            Block-Application -ApplicationPath $app -ApplicationName 'Again' 6>$null 3>$null
            Block-Application -ApplicationPath $app -ApplicationName 'Again' 6>$null 3>$null
            $script:Rules.Count | Should -Be 2
        }

        It 'goes on after a rule the firewall refuses' {
            $app = New-AppFolder 'Partly' @('a.exe', 'b.exe')
            $script:Refused = @('AppBlocker Rule -Partly - a.exe (Inbound)')

            Block-Application -ApplicationPath $app -ApplicationName 'Partly' 6>$null 3>$null

            Get-RuleName | Should -Be @('AppBlocker Rule -Partly - a.exe (Outbound)', 'AppBlocker Rule -Partly - b.exe (Inbound)', 'AppBlocker Rule -Partly - b.exe (Outbound)')
        }

        It 'changes nothing for a folder that does not exist' {
            Block-Application -ApplicationPath (Join-Path $TestDrive 'missing') -ApplicationName 'Missing' 6>$null 3>$null
            $script:Rules.Count | Should -Be 0
        }
    }

    Describe 'Get-BlockRule and Remove-ExistingRule' {
        BeforeEach {
            foreach ($name in @('Demo', 'Demo Pro', 'Tool [x64]', 'Toolx')) {
                foreach ($direction in @('Inbound', 'Outbound')) {
                    $script:Rules.Add([pscustomobject]@{ DisplayName = "AppBlocker Rule -$name - app.exe ($direction)"; Direction = $direction; Program = 'C:\app.exe' })
                }
            }
            $script:Rules.Add([pscustomobject]@{ DisplayName = 'Someone else''s rule'; Direction = 'Inbound'; Program = 'C:\x.exe' })
        }

        It 'finds the rules of one application, with [ and ] in its name read as text' {
            @(Get-BlockRule -ApplicationName 'Tool [x64]').DisplayName | Should -Be @('AppBlocker Rule -Tool [x64] - app.exe (Inbound)', 'AppBlocker Rule -Tool [x64] - app.exe (Outbound)')
            @(Get-BlockRule -ApplicationName 'Demo').Count | Should -Be 2
            @(Get-BlockRule).Count | Should -Be 8
        }

        It 'removes only that application''s rules when asked' {
            Mock Read-Host { 'y' }
            Remove-ExistingRule -ApplicationName 'Demo' 6>$null
            Get-RuleName | Should -Not -Contain 'AppBlocker Rule -Demo - app.exe (Inbound)'
            $script:Rules.Count | Should -Be 7
        }

        It 'keeps the rules when the answer is no' {
            Mock Read-Host { 'n' }
            Remove-ExistingRule -ApplicationName 'Demo' 6>$null
            $script:Rules.Count | Should -Be 9
        }
    }

    Describe 'Show-RuleManager' {
        BeforeEach {
            foreach ($name in @('Demo', 'Tool [x64]')) {
                foreach ($direction in @('Inbound', 'Outbound')) {
                    $script:Rules.Add([pscustomobject]@{ DisplayName = "AppBlocker Rule -$name - app.exe ($direction)"; Direction = $direction; Program = 'C:\app.exe' })
                }
            }
            $script:Rules.Add([pscustomobject]@{ DisplayName = 'Someone else''s rule'; Direction = 'Inbound'; Program = 'C:\x.exe' })
        }

        It 'removes the rules of the application chosen by number' {
            $script:Answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('S', '2'))
            Mock Read-Host { $script:Answers.Dequeue() }
            Show-RuleManager 6>$null
            Get-RuleName | Should -Be @('AppBlocker Rule -Demo - app.exe (Inbound)', 'AppBlocker Rule -Demo - app.exe (Outbound)', 'Someone else''s rule')
        }

        It 'removes all of its own rules and no other' {
            Mock Read-Host { 'A' }
            Show-RuleManager 6>$null
            Get-RuleName | Should -Be @('Someone else''s rule')
        }

        It 'changes nothing for a number that is not listed' {
            $script:Answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('S', 'x'))
            Mock Read-Host { $script:Answers.Dequeue() }
            Show-RuleManager 6>$null 3>$null
            $script:Rules.Count | Should -Be 5
        }
    }
}
