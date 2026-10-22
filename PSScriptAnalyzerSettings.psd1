# Settings for Invoke-ScriptAnalyzer, used by the CI workflow:
#   Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The script is an interactive console tool: its analysis, prompts and summary are meant
        # for the screen, not for the output stream, where a caller would capture them as data.
        'PSAvoidUsingWriteHost'
    )
}
