<#
.SYNOPSIS
    Checks the persistent (continuous) mode of the stack: a long-lived runner container that keeps a named
    volume, and a replacement container that finds the volume's content. Windows host, Docker in
    Windows-container mode. Needs no runner token.

.DESCRIPTION
    A fake runner (fixtures\FakeRunner.cs) stands in for the runner as the container's main process, as
    the real runner is in the stack file. It never "finishes" within the test, and it leaves a marker file in
    the volume mounted at C:\cache. The service is the windows-persistent shape of windows\stack\persistent.yaml:
    CIRCLECI_RUNNER_MODE=continuous, no idle timeout, a named volume, restart_policy any.

      continuous-mode        the container runs in continuous mode with no idle timeout set
      stays-up               the container is still running (no job, no idle exit) after StayUpSeconds
      volume-survives        after the container is removed, Swarm starts a NEW container (different
                             COMPUTERNAME and MACHINE_RUNNER_SWARM_INSTANCE_ID) and it finds the first container's marker

    "The same container across jobs" itself needs real jobs: run the end-to-end with
    CIRCLECI_RUNNER_MODE=continuous in windows\tests\stack.e2e.yaml and expect the two probe jobs to report the
    SAME MACHINE_RUNNER_SWARM_INSTANCE_ID (and to find each other's residue). See docs/ci.md.

    Prints "CHECK ..." lines and "RESULT persistent ..."; exits 0 only if everything passed.

.EXAMPLE
    .\windows\tests\Test-Persistent.ps1
#>
[CmdletBinding()]
param(
    [string] $Image,
    [int] $StayUpSeconds = 30,
    [int] $TimeoutSeconds = 300,
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

function Get-ServiceContainer {
    # Running container IDs of the service, newest state first as Docker lists them.
    param([string] $Service)
    return @((Invoke-Docker @('ps', '--quiet', '--no-trunc', '--filter', "label=com.docker.swarm.service.name=$Service")).Output | Where-Object { $_ })
}

function Get-Identity {
    # computer= and instance= from the fake runner's identity line, and the markers it saw.
    param([string[]] $LogLine)
    $text = $LogLine -join "`n"
    $r = @{ Computer = ''; Instance = ''; Mode = ''; Idle = 'unset'; Markers = @() }
    if ($text -match 'FAKERUNNER identity computer=(\S*) instance=(\S*) mode=(\S*) idle_timeout=(\S*)') {
        $r.Computer = $Matches[1]
        $r.Instance = $Matches[2]
        $r.Mode = $Matches[3]
        $r.Idle = $Matches[4]
    }
    if ($text -match 'FAKERUNNER markers=(\S*)') { $r.Markers = @($Matches[1] -split ',' | Where-Object { $_ }) }
    return $r
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "swarm-persist-$PID"
$fixtures = Join-Path $work 'fixtures'
$null = Initialize-SwarmFakeRunner -OutputDirectory $fixtures -SourcePath (Join-Path $here 'fixtures\FakeRunner.cs')
$swarm = $null
$stack = "swarmpersist$PID"
$service = "${stack}_runner"
$volume = "swarm-persist-cache-$PID"
try {
    $swarm = Initialize-SwarmCluster -AdvertiseAddr $AdvertiseAddr -DockerCommand $DockerCommand
    $iso = ''
    if ($Isolation -ne 'default') { $iso = "    isolation: $Isolation" }
    $yaml = @(
        'services:', '  runner:', "    image: $Image", $iso,
        '    entrypoint: [''C:\swarm-test\FakeRunner.exe'', machine]',
        '    environment:', '      CIRCLECI_RUNNER_NAME: "{{.Node.Hostname}}-persistent-{{.Task.Slot}}"', '      MACHINE_RUNNER_SWARM_INSTANCE_ID: "{{.Task.ID}}"',
        '      CIRCLECI_RUNNER_MODE: continuous', '      FAKE_JOB_SECONDS: "3600"', '      FAKE_MARKER_DIR: ''C:\cache''',
        '    volumes:', '      - type: bind', "        source: '$fixtures'", "        target: 'C:\swarm-test'", '        read_only: true',
        '      - type: volume', "        source: $volume", "        target: 'C:\cache'",
        '    deploy:', '      replicas: 1', '      endpoint_mode: dnsrr', '      restart_policy:', '        condition: any', '        delay: 2s',
        'volumes:', "  ${volume}:", "    name: $volume") | Where-Object { $_ -ne '' }
    $file = Join-Path $work 'stack.yaml'
    Set-Content -LiteralPath $file -Value $yaml -Encoding ASCII
    $r = Invoke-Docker @('stack', 'deploy', '--resolve-image', 'never', '-c', $file, $stack)
    if ($r.ExitCode -ne 0) { throw "docker stack deploy failed: $($r.Output -join ' ')" }

    # --- the first container -----------------------------------------------------------------------
    $first = ''
    $null = Wait-SwarmCondition -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 3 -Condition {
        $ids = @(Get-ServiceContainer -Service $service)
        if ($ids.Count -gt 0 -and (((Invoke-Docker @('logs', $ids[0])).Output -join "`n") -match 'FAKERUNNER markers=')) { $script:first = $ids[0]; $true } else { $false }
    }
    $firstLog = @()
    if ($first) { $firstLog = (Invoke-Docker @('logs', $first)).Output }
    $a = Get-Identity -LogLine $firstLog
    Write-SwarmCheck 'continuous-mode' ($first -ne '' -and $a.Mode -eq 'continuous' -and $a.Idle -eq '') "container=$($first.Substring(0, [Math]::Min(12, $first.Length))) mode=$($a.Mode) idle_timeout='$($a.Idle)' markers_at_start=$($a.Markers.Count)"

    Start-Sleep -Seconds $StayUpSeconds
    $still = @(Get-ServiceContainer -Service $service)
    Write-SwarmCheck 'stays-up' ($first -ne '' -and $still -contains $first) "running_after_${StayUpSeconds}s=$($still -contains $first) containers=$($still.Count)"

    # --- remove it: Swarm must start a new container that finds the volume's content ------------------
    $null = Invoke-Docker @('rm', '--force', $first)
    $second = ''
    $null = Wait-SwarmCondition -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 3 -Condition {
        $ids = @(Get-ServiceContainer -Service $service | Where-Object { $_ -ne $first })
        if ($ids.Count -gt 0 -and (((Invoke-Docker @('logs', $ids[0])).Output -join "`n") -match 'FAKERUNNER markers=')) { $script:second = $ids[0]; $true } else { $false }
    }
    $secondLog = @()
    if ($second) { $secondLog = (Invoke-Docker @('logs', $second)).Output }
    $b = Get-Identity -LogLine $secondLog
    $different = ($b.Computer -ne '' -and $b.Computer -ne $a.Computer -and $b.Instance -ne '' -and $b.Instance -ne $a.Instance)
    Write-SwarmCheck 'volume-survives' ($second -ne '' -and $different -and $a.Markers.Count -eq 0 -and $b.Markers.Count -ge 1) `
        "new_container=$different markers_seen_by_second=$($b.Markers.Count) first_computer=$($a.Computer) second_computer=$($b.Computer)"
} finally {
    $null = Invoke-Docker @('stack', 'rm', $stack)
    $null = Wait-SwarmCondition -TimeoutSeconds 90 -IntervalSeconds 3 -Condition { @(Get-ServiceContainer -Service $service).Count -eq 0 }
    $null = Wait-SwarmCondition -TimeoutSeconds 60 -IntervalSeconds 3 -Condition { (Invoke-Docker @('volume', 'rm', $volume)).ExitCode -eq 0 }
    if ($swarm -and $swarm.Initialised) { $null = Invoke-Docker @('swarm', 'leave', '--force') }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$count = Get-SwarmCheckCount
$verdict = 'PASS'
if ($count.Failed -gt 0) { $verdict = 'FAIL' }
[Console]::Out.WriteLine("RESULT persistent checks=$($count.Checks) failed=$($count.Failed) verdict=$verdict")
if ($count.Failed -gt 0) { exit 1 }
exit 0
