# PSScriptAnalyzer settings for every *.ps1/*.psm1/*.psd1 in this repository.
# CI runs: Invoke-ScriptAnalyzer -Path <dir> -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
# and fails on any Error or Warning.
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # These scripts are console/CI tools: supervisors, tests and e2e helpers
        # print progress for a human or a CI log. Write-Host writes to the
        # information stream on PowerShell 5+, so it can be captured.
        'PSAvoidUsingWriteHost'
    )

    Rules        = @{
        # Code that runs inside the Server Core container runs on Windows
        # PowerShell 5.1 (no pwsh in the image), while host-side scripts may
        # run on either. Flag syntax that 5.1 cannot parse.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
