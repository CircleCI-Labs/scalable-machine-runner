# PSScriptAnalyzer settings for everything under windows/ (and examples/, ci/ if you point it there).
# windows/tests/Invoke-UnitTests.ps1 uses a PSScriptAnalyzerSettings.psd1 at the repository root
# when there is one, and this file otherwise.
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Console and CI tools: Write-Host writes to the information stream on PowerShell 5+,
        # so the output can still be captured.
        'PSAvoidUsingWriteHost'
    )

    Rules        = @{
        # The host-side scripts run on Windows PowerShell 5.1 (Server's own) or on PowerShell 7, and the
        # scripts that run inside containers use 5.1, because the stock Server Core image has no pwsh.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
