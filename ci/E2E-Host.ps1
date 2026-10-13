<#
.SYNOPSIS
    Job A of the Windows e2e (see docs/ci.md): hosts the runner as a Docker Swarm service.

.DESCRIPTION
    -Mode Prepare  Stage C:\machine-runner-swarm with windows\Setup.ps1 -StageOnly, pull the stock image, then
                   `Setup.ps1 -InitSwarm -AdvertiseAddr` (docker swarm init and the machine-runner-swarm.windows-build
                   node label). The order matters: the network is down for a few seconds after
                   the swarm is created.
    -Mode Run      Deploy the stack on the stock Server Core image and host three single-task jobs:
                   the first container must claim probe b1, the second (Swarm replaces a
                   finished task with a new container) probe b2, the third probe b3. Every probe
                   must report no residue, the containers must differ, and every container must
                   exit 0 after its job. The workspace and the cache must round-trip. A stop of
                   a busy container is not tested: a stock container is killed about 5 seconds
                   after one (docs/operations.md). Prints the verdict.
    -Mode Cleanup  Remove the stack and its secrets, leave the swarm. Always runs.
    -Mode Sweep    After a failure: start one throwaway runner so that a probe still queued on
                   the e2e class is claimed and fails fast (it finds no C:\e2e-evidence\host)
                   instead of waiting for days.

    The stack is the shipped one (-StackFile) with the image tag of the host's Windows build
    (-WindowsTag, default ltsc2022; the shipped stack names ltsc2022) and an override layered on
    top: the e2e service runs one replica, every other service none. The runner and Git come
    from the host through the read-only C:\machine-runner-swarm mount the shipped stack already declares.

    The token comes from E2E_RUNNER_TOKEN_WINDOWS (scalable-machine-runner-e2e context). The
    Swarm secret windows-default-token holds the runner config (api.auth_token). It is written to
    a file outside the artifacts directory only for the instant `docker secret create` needs it,
    and never printed.

.EXAMPLE
    .\ci\E2E-Host.ps1 -Mode Run
#>
[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Run', 'Cleanup', 'Sweep')][string] $Mode = 'Run',
    [string] $StackFile = '',
    [string] $Service = 'windows-default',
    [string] $Image = '',
    [string] $WindowsTag = '',
    [string] $Stack = 'runners',
    [string] $Root = 'C:\e2e',
    [string] $IdleTimeout = '5m',
    [string] $MaxRunTime = '15m',
    [int] $DeadlineSeconds = 2400
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
if (-not $StackFile) { $StackFile = Join-Path $repo 'windows\stack\runners.yaml' }
$wf = $env:CIRCLE_WORKFLOW_ID
if (-not $wf) { throw 'CIRCLE_WORKFLOW_ID is not set' }
$build = if ($env:CIRCLE_BUILD_NUM) { $env:CIRCLE_BUILD_NUM } else { 'local' }
$secrets = 'C:\e2e-secrets'          # never under $Root: $Root is uploaded as artifacts
$fullService = "${Stack}_${Service}"
# The image of the service under test: the stock Server Core image of the shipped stack, unless -Image names another.
$stockImage = if ($Image) { $Image } else { $null }
$tag = if ($WindowsTag) { $WindowsTag } elseif ($env:E2E_WINDOWS_TAG) { $env:E2E_WINDOWS_TAG } else { 'ltsc2022' }
$runnerIdle = $IdleTimeout
$runnerMaxRun = $MaxRunTime
$deadline = $DeadlineSeconds
$probes = @('b1', 'b2', 'b3')
$evidenceDir = Join-Path $Root 'evidence'
$logDir = Join-Path $Root 'logs'
$renderedStack = Join-Path $logDir 'stack.rendered.yaml'
$eventsLog = Join-Path $logDir 'events.jsonl'
$serviceLog = Join-Path $logDir 'service.log'
$override = Join-Path $logDir 'stack.e2e.yaml'
$script:eventsProc = $null
$script:logsProc = $null

function Write-E2ELog([string] $Message) { Write-Host ("[e2e-host {0}] {1}" -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss'), $Message) }
function Invoke-Docker {
    # Windows PowerShell 5.1 turns a native command's redirected stderr into a terminating
    # NativeCommandError under ErrorActionPreference Stop, and docker writes progress to
    # stderr. Run docker with Continue and hand back plain strings; $LASTEXITCODE is kept.
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $ArgumentList)
    $ErrorActionPreference = 'Continue'
    & docker @ArgumentList 2>&1 | ForEach-Object { "$_" }
}
function Invoke-TreeKill($Process) {
    # Children started with -NoNewWindow keep the step's console open; a survivor would make
    # the step hang instead of fail.
    if ($Process -and -not $Process.HasExited) {
        $ErrorActionPreference = 'Continue'
        & taskkill.exe /T /F /PID $Process.Id 2>&1 | Out-Null
    }
}
function Get-EvidencePath([string] $Probe) { Join-Path $evidenceDir "$Probe.$wf" }
function Get-EvidenceField([string] $Path, [string] $Name) {
    $line = Get-Content -Path $Path -ErrorAction SilentlyContinue | Where-Object { $_ -like "$Name=*" } | Select-Object -First 1
    if ($line) { return $line.Substring($Name.Length + 1) }
    return ''
}
function Grant-AuthenticatedUser([string] $Path, [string] $Rights) {
    # Process-isolated containers open bind mounts with their own identity; Microsoft
    # recommends granting Authenticated Users (S-1-5-11).
    & icacls.exe $Path /grant "*S-1-5-11:$Rights" /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Path" }
}
function Get-AdvertiseAddress {
    # `docker swarm init` fails on the CircleCI Windows images with "could not find the
    # system's IP address - specify one with --advertise-addr".
    $addr = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1
    if (-not $addr) { throw 'no IPv4 address to advertise for the swarm' }
    return $addr.IPAddress
}
function Get-StackText {
    # The stack as docker renders it (interpolated, anchors expanded), to list its services and secrets.
    $text = Invoke-Docker stack config -c $StackFile
    if ($LASTEXITCODE -ne 0) { throw "docker stack config failed for ${StackFile}: $($text -join ' ')" }
    return @($text | ForEach-Object { $_ -replace 'ltsc2022', $tag })
}
function Get-RenderedSection([string[]] $Text, [string] $Section, [string] $Pattern, [int] $Indent) {
    $inside = $false
    $found = @()
    foreach ($line in $Text) {
        if ($line -match '^[^ ]') { $inside = ($line -eq "${Section}:"); continue }
        if ($inside -and $line -match $Pattern) { $found += $Matches[1] }
    }
    return $found
}
function Get-ContainerEvent {
    if (-not (Test-Path $eventsLog)) { return @() }
    $events = @()
    foreach ($line in Get-Content -Path $eventsLog) {
        if (-not $line.StartsWith('{')) { continue }
        $e = $line | ConvertFrom-Json
        $code = ''
        if ($e.Actor.Attributes.PSObject.Properties.Name -contains 'exitCode') { $code = [string] $e.Actor.Attributes.exitCode }
        $task = ''
        if ($e.Actor.Attributes.PSObject.Properties.Name -contains 'com.docker.swarm.task.id') { $task = [string] $e.Actor.Attributes.'com.docker.swarm.task.id' }
        $events += [pscustomobject]@{ Action = [string] $e.Action; Id = [string] $e.Actor.ID; ExitCode = $code; TaskId = $task; Time = ([double] $e.timeNano) / 1e9 }
    }
    return $events
}
function Get-DieCount { return @(Get-ContainerEvent | Where-Object { $_.Action -eq 'die' }).Count }
function Test-TokenRejected {
    if (-not (Test-Path $serviceLog)) { return $false }
    return [bool] (Select-String -LiteralPath $serviceLog -Quiet -Pattern '401 \(Unauthorized\)|status code: 401|401 Unauthorized')
}
function Invoke-StackRemoval {
    $null = Invoke-Docker stack rm $Stack
    for ($i = 0; $i -lt 60; $i++) {
        $left = @(Invoke-Docker ps -aq --filter "label=com.docker.stack.namespace=$Stack") | Where-Object { $_ -match '^[0-9a-f]+$' }
        if (-not $left) { return }
        Start-Sleep -Seconds 1
    }
    Write-E2ELog "stack $Stack still has containers after 60s; removing them"
    $ids = @(Invoke-Docker ps -aq --filter "label=com.docker.stack.namespace=$Stack") | Where-Object { $_ -match '^[0-9a-f]+$' }
    if ($ids) { $null = Invoke-Docker rm -f -v @ids }
}
function Invoke-Cleanup {
    Invoke-TreeKill $script:logsProc
    Invoke-TreeKill $script:eventsProc
    Write-E2ELog "cleanup: removing stack $Stack, its secrets, and leaving the swarm"
    Invoke-StackRemoval
    foreach ($s in @(Invoke-Docker secret ls -q) | Where-Object { $_ -match '^[0-9a-z]+$' }) { $null = Invoke-Docker secret rm $s }
    $null = Invoke-Docker swarm leave --force
    Remove-Item -LiteralPath $secrets -Recurse -Force -ErrorAction SilentlyContinue
    Write-E2ELog "cleanup: swarm state is now $((Invoke-Docker info --format '{{.Swarm.LocalNodeState}}') -join '')"
}
function Exit-WithFailure([string] $Message) {
    Write-E2ELog "FAIL: $Message"
    # docker events and docker service logs run with -NoNewWindow and would keep the step's console
    # open (the step then hangs until its no_output_timeout instead of failing).
    Invoke-TreeKill $script:logsProc
    Invoke-TreeKill $script:eventsProc
    exit 1
}

function Invoke-Prepare {
    Invoke-Docker version | ForEach-Object { Write-Host $_ }
    Install-Layout
    # Pull before the swarm exists: on a fresh VM the base layer takes about 10 minutes,
    # which must not count against the probes' deadline, and for a few seconds after
    # `docker swarm init` DNS lookups fail ("lookup mcr.microsoft.com: no such host").
    $base = "mcr.microsoft.com/windows/servercore:$tag"
    Write-E2ELog "docker pull $base"
    Invoke-Docker pull $base | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { Exit-WithFailure "docker pull $base failed" }
    # The shipped helper: docker swarm init and the machine-runner-swarm.windows-build node label (it stages first and
    # finds C:\machine-runner-swarm staged).
    $ip = Get-AdvertiseAddress
    Write-E2ELog "windows\Setup.ps1 -InitSwarm -AdvertiseAddr $ip"
    & (Join-Path $repo 'windows\Setup.ps1') -InitSwarm -AdvertiseAddr $ip
    if ($LASTEXITCODE -ne 0) { Exit-WithFailure "windows\Setup.ps1 -InitSwarm exited $LASTEXITCODE" }
    Invoke-Docker node ls | ForEach-Object { Write-Host $_ }
    Invoke-Docker node inspect self --format '{{json .Spec.Labels}}' | ForEach-Object { Write-Host "node labels: $_" }
    Get-ChildItem C:\machine-runner-swarm -Recurse -Depth 2 | Select-Object -First 40 | ForEach-Object { Write-Host $_.FullName }
    & C:\machine-runner-swarm\bin\circleci-runner.exe --version
}
function Install-Layout {
    # Stage C:\machine-runner-swarm with the shipped helper (runner, portable Git, ACLs). Stage first: the downloads
    # must not run right after `docker swarm init`, which rebuilds the host's virtual network.
    $setup = Join-Path $repo 'windows\Setup.ps1'
    if (-not (Test-Path $setup)) { throw "$setup is missing" }
    Write-E2ELog 'windows\Setup.ps1 -StageOnly'
    & $setup -StageOnly
    if ($LASTEXITCODE -ne 0) { Exit-WithFailure "windows\Setup.ps1 -StageOnly exited $LASTEXITCODE" }
}

function Write-Override {
    $text = Get-StackText
    $lines = @(
        "# Generated by ci/E2E-Host.ps1: e2e settings layered on $($StackFile.Replace($repo + '\', '')).",
        'services:'
    )
    foreach ($s in (Get-RenderedSection $text 'services' '^  ([^ ][^:]*):$' 2)) {
        if ($s -eq $Service) {
            $lines += "  ${s}:"
            if ($stockImage) { $lines += "    image: '$stockImage'" }
            $lines += @(
                '    environment:',
                "      CIRCLECI_RUNNER_IDLE_TIMEOUT: '$runnerIdle'",
                "      CIRCLECI_RUNNER_MAX_RUN_TIME: '$runnerMaxRun'",
                '    volumes:',
                '      - type: bind',
                "        source: '$evidenceDir'",
                "        target: 'C:\e2e-evidence'",
                '    deploy:',
                '      replicas: 1'
            )
        } else {
            $lines += @("  ${s}:", '    deploy:', '      replicas: 0')
        }
    }
    $lines | Set-Content -LiteralPath $override -Encoding ASCII
}

function Wait-Probe([string] $Probe, [int] $DiesBefore, [datetime] $Start) {
    $ev = Get-EvidencePath $Probe
    Write-E2ELog "waiting for probe $Probe"
    $printed = 0
    $lastNote = Get-Date
    while ($true) {
        Start-Sleep -Seconds 3
        if (Test-Path $serviceLog) {
            $lines = @(Get-Content -LiteralPath $serviceLog -ErrorAction SilentlyContinue)
            if ($lines.Count -gt $printed) {
                # The full runner log is an artifact; print what explains a failure.
                $lines[$printed..($lines.Count - 1)] | Where-Object { $_ -match 'rror|denied|401|could not|failed|Unauthorized' } |
                    Select-Object -Last 8 | ForEach-Object { Write-Host ("  runner: " + $_.Substring(0, [Math]::Min(260, $_.Length))) }
                $printed = $lines.Count
            }
        }
        if (Test-TokenRejected) { Exit-WithFailure 'the runner token was rejected (401). Rotate E2E_RUNNER_TOKEN_WINDOWS in the context.' }
        if ((Test-Path $ev) -and (Test-Path "$ev.status")) {
            $st = (Get-Content -LiteralPath "$ev.status" -TotalCount 1).Trim()
            Write-E2ELog "probe ${Probe}: result=$(Get-EvidenceField $ev 'result') residue=$(Get-EvidenceField $ev 'residue') status=$st"
            if ((Get-EvidenceField $ev 'result') -ne 'pass') { Exit-WithFailure "probe $Probe reported a failure (see its job log)" }
            if ($st -ne 'passed') { Exit-WithFailure "probe job $Probe did not pass (status: $st); see its job log" }
            break
        }
        $dies = Get-DieCount
        if ($dies -gt $DiesBefore -and -not (Test-Path $ev)) {
            Exit-WithFailure "the container for probe $Probe exited without evidence: the runner idled out ($runnerIdle) without claiming it, or claimed a job that is not ours"
        }
        $elapsed = [int] ((Get-Date) - $Start).TotalSeconds
        if ($elapsed -ge $deadline) { Exit-WithFailure "deadline of ${DeadlineSeconds}s reached while waiting for probe $Probe" }
        if (((Get-Date) - $lastNote).TotalSeconds -ge 60) {
            Write-E2ELog "still waiting for probe $Probe (containers exited: $dies, elapsed ${elapsed}s)"
            $lastNote = Get-Date
        }
    }
    # Single-task: the runner exits when the job is done, and Swarm starts the next container.
    for ($i = 0; $i -lt 120; $i++) {
        if ((Get-DieCount) -gt $DiesBefore) { return }
        Start-Sleep -Seconds 1
    }
    Exit-WithFailure "the container for probe $Probe did not exit after its job (single-task runner)"
}

function Invoke-Run {
    if (-not $env:E2E_RUNNER_TOKEN_WINDOWS) {
        Exit-WithFailure 'E2E_RUNNER_TOKEN_WINDOWS is empty. The setup gate only schedules this job when the scalable-machine-runner-e2e context provides it, so the context or its restrictions changed.'
    }
    if (-not (Test-Path $StackFile)) { Exit-WithFailure "$StackFile is missing" }
    if (((Invoke-Docker info --format '{{.Swarm.LocalNodeState}}') -join '') -ne 'active') { Exit-WithFailure 'this node is not a swarm manager (run: ci\E2E-Host.ps1 -Mode Prepare)' }
    $text = Get-StackText
    $services = @(Get-RenderedSection $text 'services' '^  ([^ ][^:]*):$' 2)
    $secretNames = @(Get-RenderedSection $text 'secrets' '^    name: (.+)$' 4)
    if ($services -notcontains $Service) { Exit-WithFailure "$StackFile has no service $Service" }
    if ($secretNames -notcontains "$Service-token") { Exit-WithFailure "$StackFile has no external secret $Service-token" }

    New-Item -ItemType Directory -Force -Path $evidenceDir, $logDir, $secrets | Out-Null
    Grant-AuthenticatedUser $evidenceDir '(OI)(CI)M'
    @(
        "workflow=$wf",
        "host_build=$build",
        "stack_file=$($StackFile.Replace($repo + '\', ''))",
        "started=$((Get-Date).ToUniversalTime().ToString('s'))Z"
    ) | Set-Content -LiteralPath (Join-Path $evidenceDir 'host') -Encoding ASCII

    # Secrets. On Windows the secret is the runner's config file, not the bare token:
    #   api:
    #     auth_token: <token>
    # It exists on disk only while `docker secret create` reads it, and is never printed.
    foreach ($name in $secretNames) {
        $f = Join-Path $secrets 'secret.yaml'
        $value = 'unused'
        if ($name -eq "$Service-token") { $value = "api:`n  auth_token: $env:E2E_RUNNER_TOKEN_WINDOWS`n" }
        [IO.File]::WriteAllText($f, $value, (New-Object Text.UTF8Encoding($false)))
        $null = Invoke-Docker secret create $name $f
        $rc = $LASTEXITCODE
        Remove-Item -LiteralPath $f -Force
        if ($rc -ne 0) { Exit-WithFailure "docker secret create $name failed" }
    }

    # Container lifecycle and runner output, independent of anything the probes write.
    $script:eventsProc = Start-Process -FilePath docker.exe -NoNewWindow -PassThru `
        -RedirectStandardOutput $eventsLog -RedirectStandardError (Join-Path $logDir 'events.err') `
        -ArgumentList "events --filter type=container --filter `"label=com.docker.swarm.service.name=$fullService`" --filter event=start --filter event=die --format `"{{json .}}`""

    # The stack as shipped, with the host's Windows build in the image tags and the placement constraint.
    # (Not the output of `docker stack config`, which rewrites the file.)
    (Get-Content -LiteralPath $StackFile) -replace 'ltsc2022', $tag | Set-Content -LiteralPath $renderedStack -Encoding ASCII
    Write-Override
    Write-E2ELog "deploying $fullService from $($StackFile.Replace($repo + '\', '')) + override: idle_timeout=$runnerIdle max_run_time=$runnerMaxRun"
    Invoke-Docker stack deploy --detach=true --resolve-image never -c $renderedStack -c $override $Stack | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { Exit-WithFailure 'docker stack deploy failed' }
    $script:logsProc = Start-Process -FilePath docker.exe -NoNewWindow -PassThru `
        -RedirectStandardOutput $serviceLog -RedirectStandardError (Join-Path $logDir 'service.err') `
        -ArgumentList "service logs --follow --raw --no-task-ids --timestamps $fullService"

    $start = Get-Date
    Wait-Probe 'b1' 0 $start
    Wait-Probe 'b2' 1 $start
    Wait-Probe 'b3' 2 $start
    Invoke-StackRemoval
    Start-Sleep -Seconds 3                 # let docker events flush the last die event
    $ok = Test-Evidence
    # Stop the log followers before leaving: a child with -NoNewWindow keeps the step's console open
    # and the step would hang until its no_output_timeout, also after a pass.
    Invoke-TreeKill $script:logsProc
    Invoke-TreeKill $script:eventsProc
    if (-not $ok) { exit 1 }
    exit 0
}

function Test-Evidence {
    $ok = $true
    $events = @(Get-ContainerEvent)
    $starts = @($events | Where-Object { $_.Action -eq 'start' })
    $dies = @($events | Where-Object { $_.Action -eq 'die' })
    # The first three containers ran the probes; a fourth, idle one starts when the third one is replaced.
    $ids = @($starts | Select-Object -First 3 | Select-Object -ExpandProperty Id -Unique)
    $codes = @($dies | Select-Object -First 3 | Select-Object -ExpandProperty ExitCode -Unique)
    Write-E2ELog "containers: started=$($starts.Count) exited=$($dies.Count) distinct(first three)=$($ids.Count) exit_codes(first three)=[$($codes -join ' ')]"
    if ($starts.Count -lt 3 -or $dies.Count -lt 3) { Write-E2ELog 'expected at least 3 containers'; $ok = $false }
    if ($ids.Count -ne 3) { Write-E2ELog 'expected 3 distinct container IDs'; $ok = $false }
    if (($codes -join ' ') -ne '0') { Write-E2ELog 'expected every runner container to exit 0 after its job'; $ok = $false }

    foreach ($p in $probes) {
        $ev = Get-EvidencePath $p
        if (-not (Test-Path $ev)) { Write-E2ELog "no evidence from $p"; $ok = $false; continue }
        Write-Host "--- evidence $p"; Get-Content -LiteralPath $ev | ForEach-Object { Write-Host $_ }
        if ((Get-EvidenceField $ev 'workflow') -ne $wf) { Write-E2ELog "${p}: evidence is from another workflow"; $ok = $false }
        if ((Get-EvidenceField $ev 'result') -ne 'pass') { Write-E2ELog "${p}: result is not pass"; $ok = $false }
        if ((Get-EvidenceField $ev 'residue') -ne '[]') { Write-E2ELog "${p}: found residue"; $ok = $false }
    }
    $startList = @($starts)
    $names = @{}
    $instances = @{}
    for ($n = 0; $n -lt $probes.Count; $n++) {
        $p = $probes[$n]
        $ev = Get-EvidencePath $p
        $names[$p] = Get-EvidenceField $ev 'hostname'
        $instances[$p] = Get-EvidenceField $ev 'swarm_instance_id'
        # The stack sets MACHINE_RUNNER_SWARM_INSTANCE_ID to the Swarm task ID: each probe ran in the task Swarm started for it.
        if ($startList.Count -gt $n) {
            if (-not $instances[$p] -or $instances[$p] -ne $startList[$n].TaskId) { Write-E2ELog "$p did not run in task $($n + 1) of Swarm (MACHINE_RUNNER_SWARM_INSTANCE_ID '$($instances[$p])', task '$($startList[$n].TaskId)')"; $ok = $false }
            # The computer name is the container ID's first 12 characters, in upper case.
            if (-not $names[$p] -or -not $startList[$n].Id.StartsWith($names[$p], [StringComparison]::OrdinalIgnoreCase)) { Write-E2ELog "computer name '$($names[$p])' of $p is not container $($n + 1) of Swarm"; $ok = $false }
        }
    }
    if (@($names.Values | Select-Object -Unique).Count -ne $probes.Count) { Write-E2ELog "the probes must run in different containers (computer names: $($names.Values -join ' '))"; $ok = $false }
    if (@($instances.Values | Select-Object -Unique).Count -ne $probes.Count) { Write-E2ELog 'MACHINE_RUNNER_SWARM_INSTANCE_ID must differ between the probes'; $ok = $false }

    # Workspaces and caches (probes b1 and b2 of the CircleCI jobs, written by ci\E2E-Storage.ps1).
    $storage = Join-Path $evidenceDir "storage.$wf"
    $ws = Get-EvidenceField $storage 'workspace'
    $cache = Get-EvidenceField $storage 'cache'
    $link = Get-EvidenceField $storage 'symlink'
    if (Test-Path $storage) { Write-Host '--- storage'; Get-Content -LiteralPath $storage | ForEach-Object { Write-Host $_ } }
    if ($ws -ne 'ok' -or $cache -ne 'ok') { Write-E2ELog "workspace and cache must round-trip (workspace=$ws cache=$cache)"; $ok = $false }
    # The Windows task agent does not write its feature flags to the runner's log (the Linux one does).
    $goTar = 'not-logged'
    if (Test-Path $serviceLog) {
        $m = Select-String -LiteralPath $serviceLog -Pattern '"use-go-tar":(true|false)' | Select-Object -First 1
        if ($m) { $goTar = $m.Matches[0].Groups[1].Value }
    }

    $verdict = if ($ok) { 'PASS' } else { 'FAIL' }
    $line = "RESULT e2e=windows probes=3 distinct_containers=$($ids.Count) b2_residue=$(Get-EvidenceField (Get-EvidencePath 'b2') 'residue') token_read=$(Get-EvidenceField (Get-EvidencePath 'b1') 'token_read') workspace=$ws cache=$cache symlink=$link use_go_tar=$goTar verdict=$verdict"
    Write-Host $line
    Set-Content -LiteralPath (Join-Path $Root 'result.txt') -Value $line -Encoding ASCII
    return $ok
}

function Invoke-Sweep {
    $b1 = Get-EvidencePath 'b1'
    $b2 = Get-EvidencePath 'b2'
    if (Test-Path $b2) { Write-E2ELog 'sweep: b2 already ran; nothing can be queued'; return }
    if ((Test-Path $b1) -and ((Get-EvidenceField $b1 'result') -ne 'pass')) { Write-E2ELog 'sweep: b1 failed, so b2 was never queued'; return }
    if (-not $env:E2E_RUNNER_TOKEN_WINDOWS) { Write-E2ELog "sweep: no token; cancel workflow $wf in the UI if a probe is still queued"; return }

    # The sweeper is the plain runner binary on this VM, not the stack under test, so it
    # works even when the stack failed. A probe it claims finds no C:\e2e-evidence\host and
    # fails at once.
    $sweepDir = 'C:\e2e-sweeper'
    New-Item -ItemType Directory -Force -Path $logDir, "$sweepDir\work" | Out-Null
    $url = 'https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/3.1.12/circleci-runner_windows_amd64.tar.gz'
    $sha256 = '6036674551b510f031a797e7c20a6e09dfa4aef4667532fc64b0194ec4036659'
    $tgz = Join-Path $sweepDir 'runner.tar.gz'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tgz -UseBasicParsing
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $tgz).Hash -ne $sha256) { throw 'checksum mismatch' }
        & tar.exe -xzf $tgz -C $sweepDir
        if ($LASTEXITCODE -ne 0) { throw 'tar failed' }
    } catch {
        Write-E2ELog "sweep: cannot fetch the runner binary ($($_.Exception.Message)); cancel workflow $wf in the UI if a probe is still queued"
        return
    }
    Write-E2ELog 'sweep: starting a throwaway runner (idle_timeout 2m) so a queued probe is claimed and fails fast'
    $env:CIRCLECI_RUNNER_API_AUTH_TOKEN = $env:E2E_RUNNER_TOKEN_WINDOWS
    $env:CIRCLECI_RUNNER_NAME = "e2e-sweeper-$build"
    $env:CIRCLECI_RUNNER_MODE = 'single-task'
    $env:CIRCLECI_RUNNER_IDLE_TIMEOUT = '2m'
    $env:CIRCLECI_RUNNER_MAX_RUN_TIME = '5m'
    $env:CIRCLECI_RUNNER_WORK_DIR = "$sweepDir\work"
    $env:CIRCLECI_RUNNER_CLEANUP_WORK_DIR = 'true'
    $p = Start-Process -FilePath (Join-Path $sweepDir 'circleci-runner.exe') -ArgumentList 'machine' -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $logDir 'sweeper.log') -RedirectStandardError (Join-Path $logDir 'sweeper.err.log')
    if (-not $p.WaitForExit(420000)) { Invoke-TreeKill $p }
    Remove-Item Env:\CIRCLECI_RUNNER_API_AUTH_TOKEN -ErrorAction SilentlyContinue
    Get-Content -LiteralPath (Join-Path $logDir 'sweeper.err.log') -Tail 6 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_.Substring(0, [Math]::Min(200, $_.Length)) }
    Write-E2ELog "sweep: done. If a probe is still queued, cancel workflow $wf in the UI."
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
try {
    switch ($Mode) {
        'Prepare' { Invoke-Prepare }
        'Run' { Invoke-Run }
        'Cleanup' { Invoke-Cleanup }
        'Sweep' { Invoke-Sweep }
    }
} catch {
    Write-E2ELog "FAIL: unexpected error: $($_.Exception.Message)"
    Write-Host ($_.ScriptStackTrace)
    exit 1
}
