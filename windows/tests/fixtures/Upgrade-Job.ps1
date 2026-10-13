<#
    Stand-in for a job in Test-Upgrade.ps1. Reports the version of the runner directory that is mounted at
    C:\machine-runner-swarm when the job starts and when it ends, with a pause between them.

    Output (two lines):
      UPGRADEJOB start version=<VERSION file>
      UPGRADEJOB end version=<VERSION file>
#>
$ErrorActionPreference = 'Continue'
$seconds = 25
if ($env:UPGRADE_JOB_SECONDS) { $seconds = [int] $env:UPGRADE_JOB_SECONDS }
$versionFile = 'C:\machine-runner-swarm\VERSION'
function Get-Version { if (Test-Path -LiteralPath $versionFile) { return ((Get-Content -LiteralPath $versionFile -TotalCount 1) + '').Trim() } return 'none' }
[Console]::Out.WriteLine("UPGRADEJOB start version=$(Get-Version)")
Start-Sleep -Seconds $seconds
[Console]::Out.WriteLine("UPGRADEJOB end version=$(Get-Version)")
