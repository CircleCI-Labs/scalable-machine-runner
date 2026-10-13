<#
.SYNOPSIS
    Lints and unit-tests the Windows PowerShell code. Runs on Linux or Windows; needs no Docker.

.DESCRIPTION
    1. PSScriptAnalyzer over windows\ (severity Warning and Error). Uses PSScriptAnalyzerSettings.psd1
       at the repository root when there is one, and windows\tests\PSScriptAnalyzerSettings.psd1
       otherwise.
    2. Windows PowerShell 5.1 compatibility (syntax, commands and .NET types, against the bundled
       Server 2019 profile) for every script that is not a test.
    3. Every .ps1/.psm1/.psd1 under windows\ is ASCII, because Windows PowerShell 5.1 misreads UTF-8
       files that have no byte order mark.
    4. Pester 5.x on windows\tests\*.Tests.ps1, with NUnit XML results when -ResultsDirectory is given.

    Exits non-zero on any finding or failed test.

.EXAMPLE
    docker run --rm -v "$PWD:/src" -w /src mcr.microsoft.com/powershell:7.5-ubuntu-24.04 `
      pwsh -NoProfile -File windows/tests/Invoke-UnitTests.ps1 -InstallModules -ResultsDirectory test-results/windows
#>
[CmdletBinding()]
param(
    [string] $ResultsDirectory,
    [switch] $InstallModules,
    [string] $PesterVersion = '5.7.1',
    [string] $ScriptAnalyzerVersion = '1.25.0'
)

$ErrorActionPreference = 'Stop'
$windowsDir = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $windowsDir

if ($InstallModules) {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name Pester -RequiredVersion $PesterVersion -Scope CurrentUser -Force -SkipPublisherCheck
    Install-Module -Name PSScriptAnalyzer -RequiredVersion $ScriptAnalyzerVersion -Scope CurrentUser -Force
}
if (-not (Get-Module -Name Pester | Where-Object { $_.Version -ge [version]'5.0.0' })) {
    Import-Module Pester -MinimumVersion 5.0.0
}
if (-not (Get-Module -Name PSScriptAnalyzer)) { Import-Module PSScriptAnalyzer }

$failed = 0
$sources = @(Get-ChildItem -LiteralPath $windowsDir -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')

# 1. PSScriptAnalyzer
$settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
if (-not (Test-Path -LiteralPath $settings)) { $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1' }
$findings = @(Invoke-ScriptAnalyzer -Path $windowsDir -Recurse -Settings $settings)
if ($findings.Count -gt 0) {
    $findings | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 220 | Write-Output
    $failed++
}
Write-Output "PSScriptAnalyzer: $($findings.Count) finding(s) (settings: $settings)"

# 2. Windows PowerShell 5.1 compatibility. Test files are skipped: they use Pester 5 commands that
# the 5.1 built-in Pester 3.4 lacks, and they never run inside a container.
$ps51 = 'win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
$compatSettings = @{
    IncludeRules = @('PSUseCompatibleSyntax', 'PSUseCompatibleCommands', 'PSUseCompatibleTypes')
    Rules        = @{
        PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1') }
        PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @($ps51) }
        PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = @($ps51) }
    }
}
$compat = @($sources |
        Where-Object { $_.Name -notlike '*.Tests.ps1' -and $_.Name -ne 'Invoke-UnitTests.ps1' -and $_.Extension -ne '.psd1' } |
        ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings $compatSettings })
if ($compat.Count -gt 0) {
    $compat | Format-Table -AutoSize RuleName, ScriptName, Line, Message | Out-String -Width 220 | Write-Output
    $failed++
}
Write-Output "Windows PowerShell 5.1 compatibility: $($compat.Count) finding(s)"

# 3. ASCII
$nonAscii = @($sources | Where-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
    })
foreach ($f in $nonAscii) { Write-Output "Non-ASCII content: $($f.FullName)" }
if ($nonAscii.Count -gt 0) { $failed++ }
Write-Output "ASCII check: $($nonAscii.Count) file(s) with non-ASCII bytes"

# 4. Pester
$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.Exit = $false
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
if ($ResultsDirectory) {
    New-Item -ItemType Directory -Force -Path $ResultsDirectory | Out-Null
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = (Join-Path $ResultsDirectory 'pester-windows.xml')
}
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { $failed++ }

if ($failed -gt 0) { exit 1 }
exit 0
