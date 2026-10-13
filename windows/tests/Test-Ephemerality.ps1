<#
.SYNOPSIS
    Proves (or disproves) a fresh container per job under Docker Swarm on a Windows container host.
    Needs no runner token.

.DESCRIPTION
    A fake job (fixtures\Fake-Job.ps1) runs instead of the runner. It reports residue left by any earlier
    job in the same container, then leaves residue everywhere a real job could: user profile, TEMP, the
    working directory, ProgramData, HKCU, HKLM and a machine environment variable.

      restart-policy  NEGATIVE CONTROL. "docker run --restart unless-stopped" (what plain Docker or
                      Compose does) restarts the SAME container, so later jobs must see residue.
                      PASS means this test can detect leakage.
      swarm           A stack deployed like windows\stack\runners.yaml: process isolation, a read-only
                      bind mount, restart_policy condition any. Every job must run in a DIFFERENT
                      container (a different COMPUTERNAME) and see NO residue.

    Containers are told apart by COMPUTERNAME, not the C: volume ID: every container of one image has
    the same volume ID. Nothing here sets a hostname, so COMPUTERNAME is the container ID.

    Prints one "RESULT mode=... jobs=N distinct_containers=M jobs_with_residue=K" line per mode and exits
    0 only if every selected mode passes. If the engine is not in Swarm mode, the test makes it one and
    leaves the swarm again afterwards (it never leaves a swarm that existed before).

.EXAMPLE
    .\windows\tests\Test-Ephemerality.ps1
#>
[CmdletBinding()]
param(
    [string] $Image,
    [ValidateRange(2, 10)][int] $Jobs = 3,
    [ValidateSet('all', 'restart-policy', 'swarm')][string] $Mode = 'all',
    [string] $WorkDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) "smr-eph-$PID"),
    [ValidateSet('process', 'hyperv', 'default')][string] $Isolation = 'process',
    [int] $TimeoutSeconds = 600,
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

$fixtures = Join-Path $WorkDirectory 'fixtures'
New-Item -ItemType Directory -Force -Path $fixtures | Out-Null
Copy-Item -LiteralPath (Join-Path $here 'fixtures\Fake-Job.ps1') -Destination $fixtures -Force
Grant-SmrAuthenticatedUserRead -Path $fixtures

$job = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'C:\smr-test\Fake-Job.ps1')
$failures = 0
$swarm = $null

try {
    if ($Mode -in @('all', 'restart-policy')) {
        Write-Output '===== restart-policy (negative control: plain Docker restarts the same container)'
        $name = "smr-eph-restart-$PID"
        $null = Invoke-Docker @('rm', '--force', $name)
        $run = @('run', '--detach', '--name', $name, '--restart', 'unless-stopped')
        if ($Isolation -ne 'default') { $run += "--isolation=$Isolation" }
        $run += @('--mount', "type=bind,source=$fixtures,target=C:\smr-test,readonly", '--entrypoint', 'powershell.exe', $Image) + $job
        $r = Invoke-Docker $run
        if ($r.ExitCode -ne 0) { throw "docker run failed: $($r.Output -join ' ')" }
        $lines = @()
        $null = Wait-SmrCondition -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 2 -Condition {
            $script:lines = @((Invoke-Docker @('logs', $name)).Output | Where-Object { $_ -match '^FAKEJOB ' })
            $script:lines.Count -ge $Jobs
        }
        $lines = @($script:lines)
        $null = Invoke-Docker @('rm', '--force', $name)
        $m = Measure-SmrFakeJobLine -ModeName 'restart-policy' -Line @($lines | Select-Object -First $Jobs)
        if ($m.Jobs -lt $Jobs) { Write-Output "FAIL: expected $Jobs jobs, saw $($m.Jobs)"; $failures++ }
        elseif ($m.Dirty -gt 0 -and $m.Distinct -eq 1) { Write-Output 'PASS (the control restarted one container and saw its residue)' }
        else { Write-Output 'FAIL: the control saw no leakage, so this test is blind'; $failures++ }
    }

    if ($Mode -in @('all', 'swarm')) {
        Write-Output '===== swarm (restart_policy any: a new container per job)'
        $swarm = Initialize-SmrSwarm -AdvertiseAddr $AdvertiseAddr -DockerCommand $DockerCommand
        $stack = "smreph$PID"
        $service = "${stack}_job"
        $iso = ''
        if ($Isolation -ne 'default') { $iso = "    isolation: $Isolation" }
        $yaml = @(
            'services:',
            '  job:',
            "    image: $Image",
            $iso,
            '    entrypoint: ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ''C:\smr-test\Fake-Job.ps1'']',
            '    volumes:',
            '      - type: bind',
            "        source: '$fixtures'",
            "        target: 'C:\smr-test'",
            '        read_only: true',
            '    deploy:',
            '      replicas: 1',
            '      endpoint_mode: dnsrr',
            '      restart_policy:',
            '        condition: any',
            '        delay: 2s'
        ) | Where-Object { $_ -ne '' }
        $file = Join-Path $WorkDirectory 'stack.yaml'
        Set-Content -LiteralPath $file -Value $yaml -Encoding ASCII
        $r = Invoke-Docker @('stack', 'deploy', '--resolve-image', 'never', '-c', $file, $stack)
        $r.Output | ForEach-Object { Write-Output $_ }
        if ($r.ExitCode -ne 0) { throw 'docker stack deploy failed' }

        $seen = @{}
        $null = Wait-SmrCondition -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 2 -Condition {
            $ids = @((Invoke-Docker @('ps', '--all', '--quiet', '--no-trunc', '--filter', "label=com.docker.swarm.service.name=$service")).Output | Where-Object { $_ })
            foreach ($id in $ids) {
                if ($seen.ContainsKey($id)) { continue }
                $l = @((Invoke-Docker @('logs', $id)).Output | Where-Object { $_ -match '^FAKEJOB ' })
                if ($l.Count -gt 0) { $seen[$id] = $l[0] }
            }
            $seen.Count -ge $Jobs
        }
        $tasks = @(Get-SmrServiceTask -Service $service -DockerCommand $DockerCommand)
        $null = Invoke-Docker @('stack', 'rm', $stack)
        $null = Wait-SmrCondition -TimeoutSeconds 120 -IntervalSeconds 3 -Condition {
            @((Invoke-Docker @('ps', '--all', '--quiet', '--filter', "label=com.docker.swarm.service.name=$service")).Output | Where-Object { $_ }).Count -eq 0
        }
        Write-Output ("tasks seen by Swarm: {0}; distinct container IDs with a job: {1}" -f $tasks.Count, $seen.Count)
        $m = Measure-SmrFakeJobLine -ModeName 'swarm' -Line @($seen.Values | Select-Object -First $Jobs)
        if ($m.Jobs -lt $Jobs) { Write-Output "FAIL: expected $Jobs jobs, saw $($m.Jobs)"; $failures++ }
        elseif ($m.Dirty -eq 0 -and $m.Distinct -eq $m.Jobs) { Write-Output 'PASS (a new container per job, no residue)' }
        else { Write-Output 'FAIL: state leaked between jobs, or a container was reused'; $failures++ }
    }
} finally {
    if ($swarm -and $swarm.Initialised) { $null = Invoke-Docker @('swarm', 'leave', '--force') }
    Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { exit 1 }
exit 0
