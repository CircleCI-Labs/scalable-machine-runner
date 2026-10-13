<#
.SYNOPSIS
    Checks that a runner configuration error exits 80 and does not hot-loop under Docker Swarm. Windows
    host, Docker in Windows-container mode. Needs no runner token.

.DESCRIPTION
    There is no entrypoint script: circleci-runner.exe is the container's main process, so exit 80 is the
    runner's own (kong) configuration check. Verified on the runner source and binary: a missing or invalid
    runner name, a missing token and an invalid mode exit 80; a missing or unparsable --config FILE exits 1.

    direct   the runner exits 80 and says why: no name, no token, invalid name
    swarm    a service whose runner exits 80 (no token anywhere) is restarted by restart_policy condition
             any, delay <DelaySeconds>. Over <ObserveSeconds> the number of container exits must stay near
             ObserveSeconds / DelaySeconds (no hot loop), and every exit code must be 80. With -Baked the
             service runs the image's own ENTRYPOINT, whose config file is missing, so the code is 1.

    About Swarm: "condition: any" with no max_attempts retries FOREVER, once per delay (plus the time a
    Windows container takes to start). Nothing stops the loop; watch "docker service ps <service>" for
    "task: non-zero exit (80)" and fix the configuration, or set restart_policy.max_attempts.

    Prints "CHECK ..." lines and "RESULT exit80 ..."; exits 0 only if everything passed.

.EXAMPLE
    .\windows\tests\Test-Exit80.ps1
#>
[CmdletBinding()]
param(
    [string] $Image,
    [string] $SmrRoot = 'C:\smr',
    [switch] $Baked,
    [int] $DelaySeconds = 10,
    [int] $ObserveSeconds = 60,
    [ValidateSet('process', 'hyperv', 'default')][string] $Isolation = 'process',
    [string] $AdvertiseAddr,
    [string] $DockerCommand = 'docker'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'SmrTestHelpers.psm1') -Force
if (-not $Image) { $Image = 'mcr.microsoft.com/windows/servercore:' + (Get-SmrWindowsTag) }

function Invoke-Docker {
    param([string[]] $ArgumentList)
    return (Invoke-SmrDocker -DockerCommand $DockerCommand -ArgumentList $ArgumentList)
}

$iso = @()
if ($Isolation -ne 'default') { $iso = @("--isolation=$Isolation") }
$mounts = @()
if (-not $Baked) { $mounts = Get-SmrStockMountArgument -SmrRoot $SmrRoot }
$runner = 'C:\smr\bin\circleci-runner.exe'
$tok = 'smr-exit80-not-a-real-token-0000'

# --- direct ---------------------------------------------------------------------------------------
$cases = @(
    @{ Name = 'no-name'; Env = @('--env', "CIRCLECI_RUNNER_API_AUTH_TOKEN=$tok"); Expect = 'runner.name must be set' }
    @{ Name = 'no-token'; Env = @('--env', 'CIRCLECI_RUNNER_NAME=smr-exit80-test'); Expect = 'auth_token must be set' }
    @{ Name = 'invalid-name'; Env = @('--env', 'CIRCLECI_RUNNER_NAME=bad/name', '--env', "CIRCLECI_RUNNER_API_AUTH_TOKEN=$tok"); Expect = 'must contain only' }
)
foreach ($c in $cases) {
    $r = Invoke-Docker (@('run', '--rm') + $iso + $mounts + $c.Env + @('--entrypoint', $runner, $Image, 'machine'))
    $text = $r.Output -join ' '
    Write-SmrCheck "exit80-$($c.Name)" ($r.ExitCode -eq 80 -and $text -match [regex]::Escape($c.Expect) -and $text -notmatch [regex]::Escape($tok)) "exit=$($r.ExitCode) $($r.Output | Select-Object -Last 1)"
}

# --- swarm: no hot loop ---------------------------------------------------------------------------
$swarm = $null
$service = "smr-exit80-$PID"
$dieCodes = @()
$expected = '80'
if ($Baked) { $expected = '1' }
try {
    $swarm = Initialize-SmrSwarm -AdvertiseAddr $AdvertiseAddr -DockerCommand $DockerCommand
    $create = @('service', 'create', '--detach', '--name', $service, '--restart-condition', 'any', '--restart-delay', "${DelaySeconds}s",
        '--endpoint-mode', 'dnsrr', '--env', 'CIRCLECI_RUNNER_NAME=smr-exit80-swarm')
    if ($Isolation -ne 'default') { $create += "--isolation=$Isolation" }
    if (-not $Baked) { $create += $mounts }
    # "docker service create ... IMAGE COMMAND" replaces the stock image's default command; a baked image
    # already has the runner as its ENTRYPOINT.
    $create += $Image
    if (-not $Baked) { $create += @($runner, 'machine') }
    $r = Invoke-Docker $create
    if ($r.ExitCode -ne 0) { throw "docker service create failed: $($r.Output -join ' ')" }
    $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Start-Sleep -Seconds $ObserveSeconds
    $until = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $ev = Invoke-Docker @('events', '--since', "$since", '--until', "$until", '--filter', 'type=container', '--filter', 'event=die',
        '--filter', "label=com.docker.swarm.service.name=$service", '--format', '{{.Actor.Attributes.exitCode}}')
    $dieCodes = @($ev.Output | Where-Object { $_ -match '^\d+$' })
    $tasks = @(Get-SmrServiceTask -Service $service -DockerCommand $DockerCommand)
    $errors = @($tasks | Where-Object { $_.Error } | ForEach-Object { $_.Error } | Select-Object -Unique)
    $max = [int][math]::Floor($ObserveSeconds / $DelaySeconds) + 2
    $allExpected = ($dieCodes.Count -gt 0) -and (@($dieCodes | Where-Object { $_ -ne $expected }).Count -eq 0)
    Write-SmrCheck 'swarm-restarts' ($dieCodes.Count -ge 2) "container exits in ${ObserveSeconds}s: $($dieCodes.Count) (Swarm restarts it every ${DelaySeconds}s plus start time)"
    Write-SmrCheck 'swarm-no-hot-loop' ($dieCodes.Count -le $max) "exits=$($dieCodes.Count) allowed<=$max"
    Write-SmrCheck "swarm-exit-code-$expected" $allExpected "codes=[$($dieCodes -join ' ')] task errors=[$($errors -join ' | ')]"
} finally {
    $null = Invoke-Docker @('service', 'rm', $service)
    if ($swarm -and $swarm.Initialised) { $null = Invoke-Docker @('swarm', 'leave', '--force') }
}

$count = Get-SmrCheckCount
$verdict = 'PASS'
if ($count.Failed -gt 0) { $verdict = 'FAIL' }
[Console]::Out.WriteLine("RESULT exit80 checks=$($count.Checks) failed=$($count.Failed) swarm_exits=$($dieCodes.Count) window=${ObserveSeconds}s delay=${DelaySeconds}s verdict=$verdict")
if ($count.Failed -gt 0) { exit 1 }
exit 0
