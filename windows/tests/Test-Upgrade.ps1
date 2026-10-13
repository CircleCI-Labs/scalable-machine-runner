<#
.SYNOPSIS
    Checks that a link as the bind source lets a runner upgrade reach the next container only. Windows host, Docker in
    Windows-container mode, Swarm manager (or it creates one). Needs no runner token and no runner binary.

.DESCRIPTION
    The stack files mount C:\machine-runner-swarm\current, a link to C:\machine-runner-swarm\<version>. This test shows
    what Docker does with such a link, for each -LinkType (a junction, and a directory symbolic link):

      <type>-first       a service whose container mounts the link starts on version 1.0.0
      <type>-running     the flip of the link to 2.0.0 while that container runs does not change what it sees: its job
                         ends on 1.0.0
      <type>-next        the container that Swarm starts next sees 2.0.0: Docker resolves the link when it creates
                         a container

    If a type fails, the stack cannot use it. The detail shows why (the task error of the service). Prints "CHECK ..."
    lines and "RESULT upgrade ...".

.EXAMPLE
    .\windows\tests\Test-Upgrade.ps1
#>
[CmdletBinding()]
param(
    [string] $Image,
    [ValidateSet('Junction', 'SymbolicLink')][string[]] $LinkType = @('Junction', 'SymbolicLink'),
    [int] $JobSeconds = 25,
    [int] $TimeoutSeconds = 240,
    [ValidateSet('process', 'hyperv', 'default')][string] $Isolation = 'process',
    [string] $AdvertiseAddr,
    [string] $DockerCommand = 'docker'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'SwarmTestHelpers.psm1') -Force
if (-not $Image) { $Image = 'mcr.microsoft.com/windows/servercore:' + (Get-SwarmWindowsTag) }

function Invoke-Docker {
    param([string[]] $ArgumentList)
    return (Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList $ArgumentList)
}

function Switch-Link {
    # Replaces the link by a new one to Target. A link cannot be replaced in one step: the old one is removed first.
    param([string] $Link, [string] $Target, [string] $Type)
    if (Test-Path -LiteralPath $Link) {
        & cmd.exe /c rmdir "`"$Link`""   # removes the link only, never the directory behind it
        if ($LASTEXITCODE -ne 0) { throw "cannot remove the link $Link" }
    }
    $null = New-Item -ItemType $Type -Path $Link -Target $Target
}

function Get-ServiceLog {
    param([string] $Service)
    return ((Invoke-Docker @('service', 'logs', '--raw', $Service)).Output -join "`n")
}

function Test-LinkType {
    param([string] $Type, [int] $Seconds, [int] $Timeout, [string] $IsolationMode)
    $tag = $Type.ToLowerInvariant()
    $root = "C:\swarm-upgrade-$tag-$PID"
    $service = "swarm-upgrade-$tag-$PID"
    $script:currentService = $service   # the wait conditions below read it
    $link = Join-Path $root 'current'
    New-Item -ItemType Directory -Force -Path (Join-Path $root '1.0.0'), (Join-Path $root '2.0.0'), (Join-Path $root 'job') | Out-Null
    foreach ($v in '1.0.0', '2.0.0') { Set-Content -LiteralPath (Join-Path $root "$v\VERSION") -Value $v -Encoding ASCII }
    Copy-Item -LiteralPath (Join-Path $here 'fixtures\Upgrade-Job.ps1') -Destination (Join-Path $root 'job\Upgrade-Job.ps1')
    Grant-SwarmAuthenticatedUserRead -Path $root
    Switch-Link -Link $link -Target (Join-Path $root '1.0.0') -Type $Type
    try {
        $create = @('service', 'create', '--detach', '--name', $service, '--restart-condition', 'any', '--restart-delay', '5s',
            '--endpoint-mode', 'dnsrr', '--env', "UPGRADE_JOB_SECONDS=$Seconds")
        if ($IsolationMode -ne 'default') { $create += "--isolation=$IsolationMode" }
        $create += @('--mount', "type=bind,source=$link,target=C:\machine-runner-swarm,readonly",
            '--mount', "type=bind,source=$(Join-Path $root 'job'),target=C:\swarm-test,readonly", $Image,
            'powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'C:\swarm-test\Upgrade-Job.ps1')
        $r = Invoke-Docker $create
        if ($r.ExitCode -ne 0) { throw "docker service create failed: $($r.Output -join ' ')" }

        $started = Wait-SwarmCondition -TimeoutSeconds $Timeout -IntervalSeconds 3 -Condition { (Get-ServiceLog $script:currentService) -match 'UPGRADEJOB start version=1\.0\.0' }
        $taskError = ''
        if (-not $started) {
            $ps = Invoke-Docker @('service', 'ps', '--no-trunc', '--format', '{{.CurrentState}} {{.Error}}', $service)
            $taskError = ($ps.Output | Select-Object -First 3) -join ' | '
        }
        Write-SwarmCheck "$tag-first" $started "a container that mounts the $Type starts on 1.0.0. $taskError"
        if (-not $started) { return }

        Switch-Link -Link $link -Target (Join-Path $root '2.0.0') -Type $Type
        [Console]::Out.WriteLine("flipped the $Type to 2.0.0 while the first container runs")
        $ended = Wait-SwarmCondition -TimeoutSeconds $Timeout -IntervalSeconds 3 -Condition { (Get-ServiceLog $script:currentService) -match 'UPGRADEJOB end version=' }
        $log = Get-ServiceLog $script:currentService
        Write-SwarmCheck "$tag-running" ($ended -and $log -match 'UPGRADEJOB end version=1\.0\.0') "the job that was running at the flip ends on 1.0.0 (ended=$ended)"

        $next = Wait-SwarmCondition -TimeoutSeconds $Timeout -IntervalSeconds 3 -Condition { (Get-ServiceLog $script:currentService) -match 'UPGRADEJOB start version=2\.0\.0' }
        $log = Get-ServiceLog $script:currentService
        $oldStarts = @([regex]::Matches($log, 'UPGRADEJOB start version=1\.0\.0')).Count
        Write-SwarmCheck "$tag-next" ($next -and $oldStarts -eq 1) "the container after the flip starts on 2.0.0 (next=$next, containers that started on 1.0.0=$oldStarts)"
    } finally {
        $null = Invoke-Docker @('service', 'rm', $service)
        Start-Sleep -Seconds 5
        & cmd.exe /c rmdir "`"$link`"" 2>$null
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$swarm = $null
try {
    $swarm = Initialize-SwarmCluster -AdvertiseAddr $AdvertiseAddr -DockerCommand $DockerCommand
    foreach ($t in $LinkType) { Test-LinkType -Type $t -Seconds $JobSeconds -Timeout $TimeoutSeconds -IsolationMode $Isolation }
} finally {
    if ($swarm -and $swarm.Initialised) { $null = Invoke-Docker @('swarm', 'leave', '--force') }
}

$count = Get-SwarmCheckCount
$verdict = 'PASS'
if ($count.Failed -gt 0) { $verdict = 'FAIL' }
[Console]::Out.WriteLine("RESULT upgrade checks=$($count.Checks) failed=$($count.Failed) link_types=$($LinkType -join ',') verdict=$verdict")
if ($count.Failed -gt 0) { exit 1 }
exit 0
