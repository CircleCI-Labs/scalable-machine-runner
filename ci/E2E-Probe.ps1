<#
.SYNOPSIS
    Job B of the Windows e2e (see docs/ci.md). Runs inside a Windows runner
    container (a Swarm task) that claimed this job from
    cci-labs/scalable-machine-runner-e2e-windows.

.DESCRIPTION
    1. Report residue that an earlier job left outside the working directory:
       files in %USERPROFILE%, %TEMP%, C:\ProgramData and C:\Users\Public, the
       registry key HKLM:\SOFTWARE\SmrE2E and the machine environment variable SMR_E2E.
    2. If -Previous is given, read that probe's evidence and require a different
       container: the computer name must differ. Swarm does not set a hostname for a
       Windows task, so the computer name is the container ID. (The C: volume serial
       is not usable: every container from one image has the same one.)
    3. Leave residue in the same places for the next job.
    4. Try to read the runner token (the Swarm secret, the runner's config file) as the job user and
       record who the job runs as. Only a byte count is kept, never the content.
    5. With -Drain: tell the host that the long job has started (<Probe>.<workflow id>.started),
       then run a 45 second step. The host stops the container 10 seconds in (docker service
       update --force); a graceful stop lets this step finish.
    6. Write evidence for the host job to C:\e2e-evidence\<Probe>.<workflow id>.

    Exits 0 only when no residue was found, residue was planted and (with -Previous)
    the container differs from the previous probe's. Evidence is written in every case.

    Never print the environment here.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File ci\E2E-Probe.ps1 -Probe b2 -Previous b1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Probe,
    [string] $Previous = '',
    [switch] $Drain,
    [string] $EvidenceDir = 'C:\e2e-evidence',
    [string] $TokenFile = 'C:\ProgramData\Docker\secrets\circleci_runner_config.yaml'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$wf = $env:CIRCLE_WORKFLOW_ID
if (-not $wf) { throw 'CIRCLE_WORKFLOW_ID is not set (run this as a CircleCI job)' }
$failures = New-Object System.Collections.Generic.List[string]
function Add-Failure([string] $Message) {
    Write-Host "E2E PROBE ${Probe}: FAIL: $Message"
    $failures.Add($Message)
}
function Get-EvidenceField([string] $Path, [string] $Name) {
    $line = Get-Content -Path $Path -ErrorAction SilentlyContinue | Where-Object { $_ -like "$Name=*" } | Select-Object -First 1
    if ($line) { return $line.Substring($Name.Length + 1) }
    return ''
}

# Identity: the host job writes $EvidenceDir\host before it deploys the service.
$hostFile = Join-Path $EvidenceDir 'host'
if (-not (Test-Path $hostFile) -or ((Get-EvidenceField $hostFile 'workflow') -ne $wf)) {
    Write-Host "E2E PROBE ${Probe}: FAIL: not running on the e2e host of workflow $wf."
    Write-Host 'Either a runner outside this workflow holds the e2e token, or the host job failed and its sweeper claimed this job to end it.'
    exit 1
}

# Container identity: the computer name is the container ID.
$container = [string] $env:COMPUTERNAME
$instance = [string] $env:SMR_INSTANCE_ID
$principal = [Security.Principal.WindowsIdentity]::GetCurrent()
$identity = $principal.Name
$elevated = ([Security.Principal.WindowsPrincipal] $principal).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "probe=$Probe user=$identity administrator=$elevated computername=$container"
Write-Host "smr_instance_id=$instance workdir=$((Get-Location).Path)"
# The stack sets SMR_INSTANCE_ID to the Swarm task ID, and the runner passes it on to jobs.
if (-not $instance) { Add-Failure 'SMR_INSTANCE_ID is not set in the job environment (the stack file sets it to the task ID)' }

# 1. Residue from an earlier job.
$markerName = '.smr-e2e-marker'
$candidates = @(
    (Join-Path $env:USERPROFILE $markerName),
    (Join-Path $env:TEMP $markerName),
    'C:\ProgramData\smr-e2e-marker',
    'C:\Users\Public\smr-e2e-marker'
)
$residue = @()
foreach ($m in $candidates) {
    if (Test-Path -LiteralPath $m) {
        $residue += $m
        Write-Host "STALE STATE: $m exists (written by: $(Get-Content -LiteralPath $m -TotalCount 1))"
    }
}
$regKey = 'HKLM:\SOFTWARE\SmrE2E'
if (Test-Path -LiteralPath $regKey) {
    $residue += $regKey
    Write-Host "STALE STATE: registry key $regKey exists"
}
$machineVar = [Environment]::GetEnvironmentVariable('SMR_E2E', 'Machine')
if ($machineVar) {
    $residue += 'env:SMR_E2E(Machine)'
    Write-Host "STALE STATE: machine environment variable SMR_E2E=$machineVar"
}
if ($residue.Count -gt 0) { Add-Failure "residue from an earlier job: $($residue -join ' ')" }

# 2. A different container from the previous probe.
if ($Previous) {
    $prevFile = Join-Path $EvidenceDir "$Previous.$wf"
    if (-not (Test-Path $prevFile)) {
        Add-Failure "no evidence from previous probe $Previous ($prevFile)"
    } else {
        $prevContainer = Get-EvidenceField $prevFile 'hostname'
        $prevInstance = Get-EvidenceField $prevFile 'smr_instance_id'
        Write-Host "previous probe ${Previous}: computername=$prevContainer smr_instance_id=$prevInstance"
        if ($instance -and ($prevInstance -eq $instance)) { Add-Failure "same SMR_INSTANCE_ID as ${Previous}: the container was reused" }
        if ($prevContainer -eq $container) { Add-Failure "same computer name (container ID) as ${Previous}: the container was reused" }
    }
}

# 3. Leave residue for the next job.
$planted = @()
foreach ($m in $candidates) {
    try {
        Set-Content -LiteralPath $m -Value "$Probe $wf" -ErrorAction Stop
        $planted += $m
    } catch {
        Write-Host "note: cannot write ${m}: $($_.Exception.Message)"
    }
}
try {
    New-Item -Path $regKey -Force | Out-Null
    New-ItemProperty -Path $regKey -Name 'Probe' -Value "$Probe $wf" -PropertyType String -Force | Out-Null
    $planted += $regKey
} catch {
    Write-Host "note: cannot write ${regKey}: $($_.Exception.Message)"
}
try {
    [Environment]::SetEnvironmentVariable('SMR_E2E', "$Probe $wf", 'Machine')
    $planted += 'env:SMR_E2E(Machine)'
} catch {
    Write-Host "note: cannot set the machine variable SMR_E2E: $($_.Exception.Message)"
}
if ($planted.Count -lt 2) { Add-Failure "could not plant residue (planted: $($planted -join ' '))" }
Write-Host "planted residue: $($planted -join ' ')"

# 4. Token readability as the job user. A byte count only, never the content.
$tokenRead = 'absent'
if (Test-Path -LiteralPath $TokenFile) {
    try {
        $bytes = [IO.File]::ReadAllBytes($TokenFile)
        $tokenRead = if ($bytes.Length -gt 0) { 'readable' } else { 'empty' }
    } catch {
        $tokenRead = 'denied'
    }
}
# Variable names only, never values.
$tokenEnv = if (Get-ChildItem Env: | Where-Object { $_.Name -eq 'CIRCLECI_RUNNER_API_AUTH_TOKEN' }) { 'present' } else { 'absent' }
Write-Host "token: file as $identity=$tokenRead; token in job env=$tokenEnv"
if ($tokenRead -eq 'absent') { Add-Failure "the token file $TokenFile does not exist in this container" }
# Windows jobs run as ContainerAdministrator with no step-down, so a readable token is the
# documented outcome here: it is recorded, not asserted.

# 5. A long step for the graceful-stop check: the host stops this container while it runs.
$drainResult = 'none'
if ($Drain) {
    Set-Content -LiteralPath (Join-Path $EvidenceDir "$Probe.$wf.started") -Value (Get-Date).ToUniversalTime().ToString('s') -Encoding ASCII
    Write-Host 'long step: 45 seconds; the host stops this container while it runs'
    for ($i = 1; $i -le 9; $i++) { Start-Sleep -Seconds 5; Write-Host "long step: $($i * 5) s" }
    $drainResult = 'ok'
}
$finishedEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# 6. Evidence for the host job, written atomically.
$result = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
$osText = try {
    $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    "$($k.ProductName) build $($k.CurrentBuild)"
} catch { 'unknown' }
$tmp = Join-Path $EvidenceDir ".$Probe.$wf.tmp"
@(
    "probe=$Probe",
    "workflow=$wf",
    "job=$env:CIRCLE_JOB build=$env:CIRCLE_BUILD_NUM",
    "hostname=$container",
    "smr_instance_id=$instance",
    "user=$identity",
    "administrator=$elevated",
    "os=$osText",
    "token_read=$tokenRead",
    "token_env=$tokenEnv",
    "drain=$drainResult",
    "finished_epoch=$finishedEpoch",
    "residue=[$($residue -join ' ')]",
    "planted=[$($planted -join ' ')]",
    "result=$result"
) | Set-Content -LiteralPath $tmp -Encoding ASCII
Move-Item -LiteralPath $tmp -Destination (Join-Path $EvidenceDir "$Probe.$wf") -Force

Write-Host "RESULT probe=$Probe residue=$($residue.Count) planted=$($planted.Count) token_read=$tokenRead result=$result"
if ($result -ne 'pass') { exit 1 }
exit 0
