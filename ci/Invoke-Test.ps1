<#
.SYNOPSIS
    Runs one PowerShell test script in a child Windows PowerShell and keeps its complete output
    (standard output, standard error and anything written straight to the console) in a report
    file, as plain ASCII, while echoing it to the job log. Exits with the script's exit code.

.DESCRIPTION
    `Tee-Object` writes UTF-16 in Windows PowerShell 5.1, and does not see what a script writes
    with [Console]::Out. A child process shows everything.

.EXAMPLE
    .\ci\Invoke-Test.ps1 -Script windows\tests\Test-Injection.ps1 -Report reports\injection.txt -ScriptArguments '-Online'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Script,
    [Parameter(Mandatory = $true)][string] $Report,
    [string[]] $ScriptArguments = @()
)

$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $Report
if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Set-Content -LiteralPath $Report -Value "# $Script $($ScriptArguments -join ' ')" -Encoding ASCII
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @ScriptArguments 2>&1 | ForEach-Object {
    $line = "$_"
    Write-Host $line
    Add-Content -LiteralPath $Report -Value $line -Encoding ASCII
}
$code = $LASTEXITCODE
Add-Content -LiteralPath $Report -Value "# exit code $code" -Encoding ASCII
exit $code
