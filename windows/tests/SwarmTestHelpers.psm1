<#
.SYNOPSIS
    Shared helpers for the Windows-only tests (Test-*.ps1). Windows PowerShell 5.1; ASCII only.

.DESCRIPTION
    The helpers keep the tests honest about three Windows PowerShell 5.1 facts:
      * a native command's stderr redirected with 2>&1 becomes an error record, and a terminating
        error under $ErrorActionPreference = 'Stop' (the runner writes warnings to stderr), so every
        docker call goes through Invoke-SwarmDocker, which runs with Continue and returns plain strings;
      * the C: volume ID is the same in every container of one image, so a container is identified
        by COMPUTERNAME (the container ID, because no test sets --hostname);
      * process isolation needs the image build to match the host, so the tests pick the image by
        the host build and say so.
#>

Set-StrictMode -Off

$script:SwarmChecks = 0
$script:SwarmFailed = 0

function Invoke-SwarmDocker {
    <#
    .SYNOPSIS
        Runs docker and returns @{ ExitCode; Output } with Output as an array of strings.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]] $ArgumentList,
        [string] $DockerCommand = 'docker'
    )
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $DockerCommand @ArgumentList 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    return @{ ExitCode = $code; Output = $lines }
}

function Write-SwarmCheck {
    <#
    .SYNOPSIS
        Prints "CHECK <name> PASS|FAIL <detail>" and counts it.
    #>
    param([Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][bool] $Ok, [string] $Detail = '')
    $script:SwarmChecks++
    if (-not $Ok) { $script:SwarmFailed++ }
    $verdict = 'FAIL'
    if ($Ok) { $verdict = 'PASS' }
    [Console]::Out.WriteLine("CHECK $Name $verdict $Detail")
}

function Get-SwarmCheckCount {
    return @{ Checks = $script:SwarmChecks; Failed = $script:SwarmFailed }
}

function Clear-SwarmCheckCount {
    $script:SwarmChecks = 0
    $script:SwarmFailed = 0
}

function Get-SwarmHostBuild {
    return [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
}

function Get-SwarmWindowsTag {
    <#
    .SYNOPSIS
        The servercore tag that matches a host build: ltsc2022 for 20348, ltsc2025 for 26100.
    #>
    param([int] $Build = (Get-SwarmHostBuild))
    if ($Build -eq 20348) { return 'ltsc2022' }
    if ($Build -eq 26100) { return 'ltsc2025' }
    throw "Windows build $Build is not Server 2022 (20348) or Server 2025 (26100); pass -Image explicitly"
}

function Get-SwarmImageBuild {
    <#
    .SYNOPSIS
        The Windows build number of a local image (10.0.20348.1234 gives 20348), or 0.
    #>
    param([Parameter(Mandatory = $true)][string] $Image, [string] $DockerCommand = 'docker')
    $r = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('image', 'inspect', '--format', '{{.Os}} {{.OsVersion}}', $Image)
    if ($r.ExitCode -ne 0) { return 0 }
    $parts = ([string]($r.Output | Select-Object -Last 1)).Trim() -split ' '
    if ($parts.Count -lt 2 -or $parts[0] -ne 'windows') { return 0 }
    $v = $parts[1] -split '\.'
    if ($v.Count -lt 3) { return 0 }
    return [int]$v[2]
}

function Test-SwarmProcessIsolation {
    <#
    .SYNOPSIS
        True when an image of build ImageBuild can run process-isolated on a host of build HostBuild
        (Microsoft's rules: the builds must match, and a Server 2025 host also runs 2022 images).
    #>
    param([int] $HostBuild, [int] $ImageBuild)
    if ($HostBuild -eq $ImageBuild) { return $true }
    return ($HostBuild -eq 26100 -and $ImageBuild -eq 20348)
}

function ConvertFrom-SwarmServiceTaskLine {
    <#
    .SYNOPSIS
        Parses "docker service ps --no-trunc --format '{{json .}}'" lines into objects with
        Id, Name, Node, DesiredState, CurrentState and Error.
    #>
    param([string[]] $Line)
    $tasks = @()
    foreach ($l in @($Line)) {
        if (-not $l -or -not $l.StartsWith('{')) { continue }
        $j = $l | ConvertFrom-Json
        $tasks += [pscustomobject]@{
            Id           = [string]$j.ID
            Name         = [string]$j.Name
            Node         = [string]$j.Node
            DesiredState = [string]$j.DesiredState
            CurrentState = [string]$j.CurrentState
            Error        = [string]$j.Error
        }
    }
    return $tasks
}

function Get-SwarmServiceTask {
    param([Parameter(Mandatory = $true)][string] $Service, [string] $DockerCommand = 'docker')
    $r = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('service', 'ps', '--no-trunc', '--format', '{{json .}}', $Service)
    return @(ConvertFrom-SwarmServiceTaskLine -Line $r.Output)
}

function Wait-SwarmCondition {
    <#
    .SYNOPSIS
        Polls a script block until it returns $true or the timeout passes. Returns the last result.
    #>
    param([Parameter(Mandatory = $true)][scriptblock] $Condition, [int] $TimeoutSeconds = 120, [int] $IntervalSeconds = 2)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        $ok = [bool](& $Condition)
        if ($ok) { return $true }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $ok
}

function Get-SwarmAdvertiseAddress {
    <#
    .SYNOPSIS
        An IPv4 address of this host that is not loopback or link-local, for "docker swarm init".
    #>
    $addr = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not $_.ToString().StartsWith('127.') -and -not $_.ToString().StartsWith('169.254.') } |
        Select-Object -First 1
    if (-not $addr) { throw 'no usable IPv4 address for docker swarm init; pass -AdvertiseAddr' }
    return $addr.ToString()
}

function Initialize-SwarmCluster {
    <#
    .SYNOPSIS
        Makes sure the engine is a swarm manager. Returns @{ Initialised } so the caller can leave the
        swarm again if (and only if) this call created it.
    #>
    param([string] $AdvertiseAddr, [string] $DockerCommand = 'docker')
    $state = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('info', '--format', '{{.Swarm.LocalNodeState}} {{.Swarm.ControlAvailable}}')
    $parts = ([string]($state.Output | Select-Object -First 1)).Trim() -split ' '
    if ($parts[0] -eq 'active' -and $parts[1] -eq 'true') { return @{ Initialised = $false } }
    if ($parts[0] -eq 'active') { throw 'this node is a swarm worker; run the test on a manager' }
    if (-not $AdvertiseAddr) { $AdvertiseAddr = Get-SwarmAdvertiseAddress }
    $r = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('swarm', 'init', '--advertise-addr', $AdvertiseAddr)
    if ($r.ExitCode -ne 0) { throw "docker swarm init failed: $($r.Output -join ' ')" }
    return @{ Initialised = $true }
}

function Get-SwarmNodeId {
    param([string] $DockerCommand = 'docker')
    $r = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('info', '--format', '{{.Swarm.NodeID}}')
    return ([string]($r.Output | Select-Object -First 1)).Trim()
}

function Grant-SwarmAuthenticatedUserRead {
    <#
    .SYNOPSIS
        Grants Authenticated Users read and execute on a directory tree. Process-isolated containers open
        bind mounts with their own identity, which exists only inside the container, so Microsoft
        recommends this well-known group.
    #>
    param([Parameter(Mandatory = $true)][string] $Path, [string] $Rights = '(OI)(CI)RX')
    $null = & icacls.exe $Path /grant "*S-1-5-11:$Rights" /T /C /Q
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Path" }
}

function Get-SwarmStackEnvironment {
    <#
    .SYNOPSIS
        The environment the stack file gives every stock service: the x-runner-env and x-stock-env anchors of
        runners.yaml as a hashtable, without the entries that need Swarm to render a template, and without
        CIRCLECI_RUNNER_API_URL: that points at the service token-proxy-windows, which exists only inside the stack,
        and the tests run a standalone runner that talks to CircleCI itself. The tests run containers with exactly
        this, so a change to the stack file is what gets tested.
    #>
    param([string] $StackFile = (Join-Path $PSScriptRoot '..\stack\runners.yaml'))
    $result = @{}
    $inside = $false
    foreach ($line in Get-Content -LiteralPath $StackFile) {
        if ($line -match '^x-(runner|stock)-env: &') { $inside = $true; continue }
        if ($inside -and $line -match '^\S') { $inside = $false }
        if (-not $inside -or $line -match '^\s*#' -or $line -notmatch '^  ([A-Za-z_][A-Za-z0-9_]*): (.+)$') { continue }
        $name = $Matches[1]
        $value = ($Matches[2] -replace '\s+#.*$', '').Trim()
        if ($value -match "^'(.*)'$" -or $value -match '^"(.*)"$') { $value = $Matches[1] }
        if ($value -notmatch '\{\{' -and $name -ne 'CIRCLECI_RUNNER_API_URL') { $result[$name] = $value }
    }
    return $result
}

function ConvertTo-SwarmEnvArgument {
    <#
    .SYNOPSIS
        A hashtable as "--env", "NAME=value" pairs for docker run.
    #>
    param([Parameter(Mandatory = $true)][hashtable] $Environment)
    $list = @()
    foreach ($k in ($Environment.Keys | Sort-Object)) { $list += @('--env', "$k=$($Environment[$k])") }
    return $list
}

function Get-SwarmEncodedCommandArgument {
    <#
    .SYNOPSIS
        "-EncodedCommand", "<base64>" for powershell.exe: a script with quotes and line breaks reaches a native command
        unchanged, which Windows PowerShell 5.1 does not guarantee for a plain argument.
    #>
    param([Parameter(Mandatory = $true)][string] $Script)
    return @('-EncodedCommand', [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script)))
}

function Get-SwarmStockMountArgument {
    <#
    .SYNOPSIS
        The two read-only mounts of a stock-image service as docker run arguments, as in the stack files: the volume
        runner-bin of the node (filled by the distributor) with the subpath current at C:\machine-runner-swarm, and with the
        subpath git\current at C:\Program Files\Git (the path the task agent hard-codes for tar.exe). Docker resolves the
        two links when it creates the container.
    #>
    param([string] $Volume = 'runners_runner-bin')
    return @('--mount', "type=volume,source=$Volume,target=C:\machine-runner-swarm,readonly,volume-subpath=current",
        '--mount', "type=volume,source=$Volume,target=C:\Program Files\Git,readonly,volume-subpath=git\current")
}

function Install-SwarmDistributor {
    <#
    .SYNOPSIS
        Deploys the shipped windows\stack\runners.yaml with no runner replicas, so that its distributor service installs the
        runner and portable Git into the volume <Stack>_runner-bin, and waits until it has flipped both links. Returns
        @{ Ok; Detail; Log }. The Swarm secrets of the class and of the runners' placeholder are made-up ones, created here when they are missing. The token proxy gets no replica here: the tests that need it deploy it themselves. ExtraOverride is one more compose file for the deploy.
    #>
    param(
        [string] $Stack = 'runners',
        [string] $StackFile = (Join-Path $PSScriptRoot '..\stack\runners.yaml'),
        [int] $TimeoutSeconds = 1500,
        [string] $DockerCommand = 'docker',
        [string] $ExtraOverride = ''
    )
    # the class token (the token proxy's secret) and the placeholder that the runners read: both made up
    foreach ($secret in 'windows-default-token', 'runner-placeholder-token') {
        if ((Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('secret', 'inspect', $secret)).ExitCode -ne 0) {
            $file = Join-Path ([IO.Path]::GetTempPath()) "swarm-secret-$PID.yaml"
            [IO.File]::WriteAllText($file, "api:`n  auth_token: swarm-test-not-a-real-token`n")
            $r = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('secret', 'create', $secret, $file)
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            if ($r.ExitCode -ne 0) { return @{ Ok = $false; Detail = "docker secret create failed: $($r.Output -join ' ')"; Log = '' } }
        }
    }
    $override = Join-Path ([IO.Path]::GetTempPath()) "swarm-distributor-override-$PID.yaml"
    [IO.File]::WriteAllText($override, "services:`n  windows-default:`n    deploy:`n      replicas: 0`n  token-proxy-windows:`n    deploy:`n      replicas: 0`n")
    $deploy = @('stack', 'deploy', '--resolve-image', 'never', '-c', $StackFile, '-c', $override)
    if ($ExtraOverride) { $deploy += @('-c', $ExtraOverride) }
    $r = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList ($deploy + @($Stack))
    Remove-Item -LiteralPath $override -Force -ErrorAction SilentlyContinue
    if ($r.ExitCode -ne 0) { return @{ Ok = $false; Detail = "docker stack deploy failed: $($r.Output -join ' ')"; Log = '' } }
    $service = "${Stack}_runner-distributor-windows"
    $log = ''
    $ok = Wait-SwarmCondition -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 10 -Condition {
        $script:distLog = ((Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('service', 'logs', '--raw', $service)).Output -join "`n")
        ($script:distLog -match '\[ ok \] current -> versions') -and ($script:distLog -match '\[ ok \] git\\current -> git')
    }
    $log = $script:distLog
    $detail = "the distributor did not install the runner and Git within ${TimeoutSeconds}s"
    if (-not $ok) {
        $stockRef = 'mcr.microsoft.com/windows/servercore'
        $sections = @()
        if ($log) { $sections += '--- distributor logs (last poll) ---'; $sections += $log }
        $ps = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('service', 'ps', '--no-trunc', $service)
        $sections += '--- docker service ps --no-trunc ---'
        $sections += $ps.Output
        $raw = @(Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('service', 'logs', '--raw', $service)).Output
        $tail = @($raw | Select-Object -Last 50)
        $sections += '--- docker service logs (last 50 lines) ---'
        $sections += $tail
        $imgs = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('image', 'ls', '--filter', "reference=$stockRef")
        $sections += "--- docker image ls (reference=$stockRef) ---"
        $sections += $imgs.Output
        $log = ($sections | ForEach-Object { if ($_ -is [string]) { $_ } else { "$_" } }) -join "`n"
        $detail = "$detail`n$log"
    }
    return @{ Ok = $ok; Detail = $detail; Log = $log }
}

function Initialize-SwarmFakeRunner {
    <#
    .SYNOPSIS
        Compiles fixtures\FakeRunner.cs with the csc.exe that ships with .NET Framework and returns the path of
        FakeRunner.exe in OutputDirectory. The directory is made readable for containers.
    #>
    param([Parameter(Mandatory = $true)][string] $OutputDirectory, [Parameter(Mandatory = $true)][string] $SourcePath,
        [string] $Version, [string] $ExeName = 'FakeRunner.exe')
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    if ($Version) {
        # A fake release: the binary reports this version (the marker @VERSION@ of the source).
        $patched = Join-Path ([IO.Path]::GetTempPath()) "FakeRunner-$PID-$([guid]::NewGuid().ToString('N')).cs"
        [IO.File]::WriteAllText($patched, ([IO.File]::ReadAllText($SourcePath)).Replace('@VERSION@', $Version))
        $SourcePath = $patched
    }
    $csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found at $csc (it ships with .NET Framework)" }
    $exe = Join-Path $OutputDirectory $ExeName
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& $csc /nologo "/out:$exe" $SourcePath 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($code -ne 0) { throw "csc failed: $($output -join ' ')" }
    Grant-SwarmAuthenticatedUserRead -Path $OutputDirectory
    return $exe
}

function Measure-SwarmFakeJobLine {
    <#
    .SYNOPSIS
        Prints the FAKEJOB lines and a RESULT line and returns the counts (jobs, distinct containers,
        jobs that saw residue). Containers are told apart by the host= field (COMPUTERNAME).
    #>
    param([Parameter(Mandatory = $true)][string] $ModeName, [string[]] $Line)
    $jobs = @($Line | Where-Object { $_ -match '^FAKEJOB ' })
    foreach ($l in $jobs) { [Console]::Out.WriteLine($l) }
    $hosts = @($jobs | ForEach-Object { if ($_ -match 'host=(\S+)') { $Matches[1] } } | Sort-Object -Unique)
    $dirty = @($jobs | Where-Object { $_ -notmatch 'residue=\[\]$' })
    [Console]::Out.WriteLine(('RESULT mode={0} jobs={1} distinct_containers={2} jobs_with_residue={3}' -f $ModeName, $jobs.Count, $hosts.Count, $dirty.Count))
    return @{ Jobs = $jobs.Count; Distinct = $hosts.Count; Dirty = $dirty.Count }
}

Export-ModuleMember -Function Invoke-SwarmDocker, Write-SwarmCheck, Get-SwarmCheckCount, Clear-SwarmCheckCount, Get-SwarmHostBuild, Get-SwarmWindowsTag,
Get-SwarmImageBuild, Test-SwarmProcessIsolation, ConvertFrom-SwarmServiceTaskLine, Get-SwarmServiceTask, Wait-SwarmCondition, Get-SwarmAdvertiseAddress,
Initialize-SwarmCluster, Get-SwarmNodeId, Grant-SwarmAuthenticatedUserRead, Initialize-SwarmFakeRunner, Get-SwarmStackEnvironment, ConvertTo-SwarmEnvArgument, Get-SwarmStockMountArgument, Get-SwarmEncodedCommandArgument, Install-SwarmDistributor, Measure-SwarmFakeJobLine
