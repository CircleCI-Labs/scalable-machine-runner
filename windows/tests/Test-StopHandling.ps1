<#
.SYNOPSIS
    Measures what stopping a busy runner container does on the STOCK Server Core image, and checks that a runner
    under Swarm can read its config secret. Windows host, Docker in Windows-container mode. Needs no runner token.

.DESCRIPTION
    circleci-runner.exe is the container's main process. The runner is a Go program: its runtime (checked in
    Go 1.26.7, the version the runner is built with, runtime\os_windows.go ctrlHandler) turns a console
    CLOSE, LOGOFF or SHUTDOWN event into SIGTERM and blocks the handler, and the runner (service.go,
    ex/termination) drains on SIGTERM: the job it is running finishes (up to max_run_time), then it exits.

    Windows is the limit, not the runner. "docker stop" and "docker service update" shut a Windows container
    down with HCS; on Server Core that sends CTRL_SHUTDOWN_EVENT and waits only WaitToKillServiceTimeout, five
    seconds by default, before it kills the processes, whatever "docker stop -t" or stop_grace_period say. A job
    running in a stock Server Core container dies about five seconds after an outside stop, with exit code
    3221225786 (0xC000013A). The normal flow is not affected: a finished job ends the runner, and the container
    ends by itself. The documented way around the rule is optional (docs/operations.md, "Windows drain").

      control            (informational, a NOTE) fixtures\FakeRunner.cs, compiled here with csc.exe, is the main
                         process of a container of the stock image and "runs a job" for FAKE_JOB_SECONDS. After
                         docker stop the job is expected to be killed: this is the measurement behind the docs
      stop-real-runner   (-Online) the REAL runner with a bogus token and nothing to drain, stopped with docker
                         stop: it must log "terminated" and exit 0 well inside the timeout
      swarm-secret       a stack like windows\stack\runners.yaml with a real Swarm secret: the process can read
                         C:\ProgramData\Docker\secrets\circleci_runner_config.yaml and finds the token

    Prints "CHECK ..." lines and "RESULT stop ...".

.EXAMPLE
    .\windows\tests\Test-StopHandling.ps1 -Online
#>
[CmdletBinding()]
param(
    [string] $Image,
    [string] $SwarmRoot = 'C:\machine-runner-swarm',
    [switch] $Online,
    [ValidateSet('all', 'docker', 'swarm')][string] $Mode = 'all',
    [int] $JobSeconds = 40,
    [int] $StopTimeoutSeconds = 300,
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

$work = Join-Path ([System.IO.Path]::GetTempPath()) "swarm-stop-$PID"
$fixtures = Join-Path $work 'fixtures'
$null = Initialize-SwarmFakeRunner -OutputDirectory $fixtures -SourcePath (Join-Path $here 'fixtures\FakeRunner.cs')
$iso = @()
if ($Isolation -ne 'default') { $iso = @("--isolation=$Isolation") }
$fixtureMount = @('--mount', "type=bind,source=$fixtures,target=C:\swarm-test,readonly")
$secretPath = 'C:\ProgramData\Docker\secrets\circleci_runner_config.yaml'

function Wait-Log {
    param([string] $Container, [string] $Pattern, [int] $TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (((Invoke-Docker @('logs', $Container)).Output -join "`n") -match $Pattern) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-ExitCode {
    param([string] $Container)
    $r = Invoke-Docker @('inspect', '--format', '{{.State.ExitCode}}', $Container)
    return ([string]($r.Output | Select-Object -First 1)).Trim()
}


function Invoke-FakeStop {
    # Runs the fake runner as the main process of a container of ImageName, stops it, and reports what happened.
    param([string] $ImageName, [string] $Suffix, [int] $StopTimeout)
    $name = "swarm-stop-$Suffix-$PID"
    $run = @('run', '--detach', '--name', $name) + $iso + $fixtureMount + @('--env', "FAKE_JOB_SECONDS=$JobSeconds",
        '--entrypoint', 'C:\swarm-test\FakeRunner.exe', $ImageName, 'machine')
    $r = Invoke-Docker $run
    if ($r.ExitCode -ne 0) { throw "docker run failed: $($r.Output -join ' ')" }
    $up = Wait-Log -Container $name -Pattern 'FAKERUNNER started'
    Start-Sleep -Seconds 5
    $t0 = Get-Date
    $stop = Invoke-Docker @('stop', '-t', "$StopTimeout", $name)
    $elapsed = [int]((Get-Date) - $t0).TotalSeconds
    $log = (Invoke-Docker @('logs', $name)).Output
    $text = $log -join "`n"
    $code = Get-ExitCode -Container $name
    $null = Invoke-Docker @('rm', '--force', $name)
    $consoleEvent = 'none'
    if ($text -match 'FAKERUNNER event=(\d+)') { $consoleEvent = $Matches[1] }
    return @{ Up = $up; StopExit = $stop.ExitCode; Elapsed = $elapsed; Code = $code; Event = $consoleEvent; Log = $log
        Finished = [bool]($text -match 'FAKERUNNER job-finished') }
}

$swarm = $null
$swarmStack = $null
$secretName = $null
try {
    if ($Mode -in @('all', 'docker')) {
        # --- control: a busy stock container is killed by an outside stop ---------------------------------
        $c = Invoke-FakeStop -ImageName $Image -Suffix 'control' -StopTimeout $StopTimeoutSeconds
        $verdict = 'the job survived the stop, so this host does not apply the 5 second rule'
        if (-not $c.Finished) { $verdict = 'the job was KILLED by the stop, as expected on stock Server Core (WaitToKillServiceTimeout is 5 s)' }
        [Console]::Out.WriteLine("NOTE control, stock $Image : console_event=$($c.Event) stop_took=$($c.Elapsed)s container_exit=$($c.Code) job_finished=$($c.Finished): $verdict")

        if ($Online) {
            # --- stop-real-runner: the real runner, a bogus token, nothing to drain -------------------------
            $name = "swarm-stop-real-$PID"
            $mounts = Get-SwarmStockMountArgument -SwarmRoot $SwarmRoot
            $stackEnv = Get-SwarmStackEnvironment
            $run = @('run', '--detach', '--name', $name) + $iso + $mounts + (ConvertTo-SwarmEnvArgument -Environment $stackEnv) + @(
                '--env', 'CIRCLECI_RUNNER_NAME=swarm-stop-real', '--env', 'CIRCLECI_RUNNER_API_AUTH_TOKEN=swarm-stop-not-a-real-token',
                '--env', 'CIRCLECI_RUNNER_IDLE_TIMEOUT=10m', '--entrypoint', 'C:\machine-runner-swarm\bin\circleci-runner.exe', $Image, 'machine')
            $null = Invoke-Docker $run
            $up = Wait-Log -Container $name -Pattern '401|Unauthorized|starting agent' -TimeoutSeconds 300
            Start-Sleep -Seconds 5
            $t0 = Get-Date
            $null = Invoke-Docker @('stop', '-t', '120', $name)
            $elapsed = [int]((Get-Date) - $t0).TotalSeconds
            $realLog = (Invoke-Docker @('logs', $name)).Output
            $realCode = Get-ExitCode -Container $name
            $null = Invoke-Docker @('rm', '--force', $name)
            $realLog | Select-Object -Last 8 | ForEach-Object { [Console]::Out.WriteLine("  log: $_") }
            $drained = ($realLog -join "`n") -match 'terminated'
            Write-SwarmCheck 'stop-real-runner' ($up -and $drained -and $realCode -eq '0' -and $elapsed -lt 100) "runner_up=$up drained_on_stop=$drained container_exit=$realCode stop_took=${elapsed}s"
        }
    }

    if ($Mode -in @('all', 'swarm')) {
        # --- swarm: a Swarm secret as the runner config --------------------------------------------------
        $swarm = Initialize-SwarmCluster -AdvertiseAddr $AdvertiseAddr -DockerCommand $DockerCommand
        $swarmStack = "swarmstop$PID"
        $service = "${swarmStack}_runner"
        $secretName = "swarm-stop-token-$PID"
        $secretFile = Join-Path $work 'secret.yaml'
        [System.IO.File]::WriteAllText($secretFile, "api:`n  auth_token: swarm-stop-secret-not-a-real-token`n")
        $r = Invoke-Docker @('secret', 'create', $secretName, $secretFile)
        Remove-Item -LiteralPath $secretFile -Force
        if ($r.ExitCode -ne 0) { throw "docker secret create failed: $($r.Output -join ' ')" }
        $iso1 = ''
        if ($Isolation -ne 'default') { $iso1 = "    isolation: $Isolation" }
        $yaml = @(
            'services:', '  runner:', "    image: $Image", $iso1,
            '    entrypoint: [''C:\swarm-test\FakeRunner.exe'', machine, ''--config'', ''C:\ProgramData\Docker\secrets\circleci_runner_config.yaml'']',
            '    environment:', '      CIRCLECI_RUNNER_NAME: "{{.Node.Hostname}}-stop-{{.Task.Slot}}"', '      MACHINE_RUNNER_SWARM_INSTANCE_ID: "{{.Task.ID}}"',
            "      FAKE_JOB_SECONDS: ""$JobSeconds""",
            '    secrets:', '      - source: stop-token', '        target: circleci_runner_config.yaml',
            '    stop_grace_period: 3m', '    volumes:', '      - type: bind', "        source: '$fixtures'", "        target: 'C:\swarm-test'", '        read_only: true',
            '    deploy:', '      replicas: 1', '      endpoint_mode: dnsrr', '      restart_policy:', '        condition: any', '        delay: 2s',
            '      update_config:', '        order: stop-first', '        parallelism: 1',
            'secrets:', '  stop-token:', '    external: true', "    name: $secretName") | Where-Object { $_ -ne '' }
        $file = Join-Path $work 'stack.yaml'
        Set-Content -LiteralPath $file -Value $yaml -Encoding ASCII
        $r = Invoke-Docker @('stack', 'deploy', '--resolve-image', 'never', '-c', $file, $swarmStack)
        if ($r.ExitCode -ne 0) { throw "docker stack deploy failed: $($r.Output -join ' ')" }
        $oldId = ''
        $null = Wait-SwarmCondition -TimeoutSeconds 300 -IntervalSeconds 3 -Condition {
            $ids = @((Invoke-Docker @('ps', '--quiet', '--no-trunc', '--filter', "label=com.docker.swarm.service.name=$service")).Output | Where-Object { $_ })
            if ($ids.Count -gt 0 -and (((Invoke-Docker @('logs', $ids[0])).Output -join "`n") -match 'FAKERUNNER config=')) { $script:oldId = $ids[0]; $true } else { $false }
        }
        $startLog = ''
        if ($oldId) { $startLog = (Invoke-Docker @('logs', $oldId)).Output -join "`n" }
        $readable = $startLog -match ('FAKERUNNER config=' + [regex]::Escape($secretPath) + ' config_has_token=True')
        $inEnv = $startLog -match 'token_in_env=True'
        Write-SwarmCheck 'swarm-secret' ($readable -and -not $inEnv) "config_secret_readable_with_token=$readable token_in_runner_environment=$inEnv (the token is in the file only)"
    }
} finally {
    if ($swarmStack) { $null = Invoke-Docker @('stack', 'rm', $swarmStack) }
    if ($secretName) {
        $null = Wait-SwarmCondition -TimeoutSeconds 60 -IntervalSeconds 3 -Condition { (Invoke-Docker @('secret', 'rm', $secretName)).ExitCode -eq 0 }
    }
    if ($swarm -and $swarm.Initialised) { $null = Invoke-Docker @('swarm', 'leave', '--force') }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$count = Get-SwarmCheckCount
$verdict = 'PASS'
if ($count.Failed -gt 0) { $verdict = 'FAIL' }
[Console]::Out.WriteLine("RESULT stop checks=$($count.Checks) failed=$($count.Failed) job_seconds=$JobSeconds verdict=$verdict")
if ($count.Failed -gt 0) { exit 1 }
exit 0
