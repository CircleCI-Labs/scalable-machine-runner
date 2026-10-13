<#
.SYNOPSIS
    Shared helpers for the Windows-only tests (Test-*.ps1). Windows PowerShell 5.1; ASCII only.

.DESCRIPTION
    The helpers keep the tests honest about three Windows PowerShell 5.1 facts:
      * a native command's stderr redirected with 2>&1 becomes an error record, and a terminating
        error under $ErrorActionPreference = 'Stop' (the runner writes warnings to stderr), so every
        docker call goes through Invoke-SmrDocker, which runs with Continue and returns plain strings;
      * the C: volume ID is the same in every container of one image, so a container is identified
        by COMPUTERNAME (the container ID, because no test sets --hostname);
      * process isolation needs the image build to match the host, so the tests pick the image by
        the host build and say so.
#>

Set-StrictMode -Off

$script:SmrChecks = 0
$script:SmrFailed = 0

function Invoke-SmrDocker {
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

function Write-SmrCheck {
    <#
    .SYNOPSIS
        Prints "CHECK <name> PASS|FAIL <detail>" and counts it.
    #>
    param([Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][bool] $Ok, [string] $Detail = '')
    $script:SmrChecks++
    if (-not $Ok) { $script:SmrFailed++ }
    $verdict = 'FAIL'
    if ($Ok) { $verdict = 'PASS' }
    [Console]::Out.WriteLine("CHECK $Name $verdict $Detail")
}

function Get-SmrCheckCount {
    return @{ Checks = $script:SmrChecks; Failed = $script:SmrFailed }
}

function Clear-SmrCheckCount {
    $script:SmrChecks = 0
    $script:SmrFailed = 0
}

function Get-SmrHostBuild {
    return [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
}

function Get-SmrWindowsTag {
    <#
    .SYNOPSIS
        The servercore tag that matches a host build: ltsc2022 for 20348, ltsc2025 for 26100.
    #>
    param([int] $Build = (Get-SmrHostBuild))
    if ($Build -eq 20348) { return 'ltsc2022' }
    if ($Build -eq 26100) { return 'ltsc2025' }
    throw "Windows build $Build is not Server 2022 (20348) or Server 2025 (26100); pass -Image explicitly"
}

function Get-SmrImageBuild {
    <#
    .SYNOPSIS
        The Windows build number of a local image (10.0.20348.1234 gives 20348), or 0.
    #>
    param([Parameter(Mandatory = $true)][string] $Image, [string] $DockerCommand = 'docker')
    $r = Invoke-SmrDocker -DockerCommand $DockerCommand -ArgumentList @('image', 'inspect', '--format', '{{.Os}} {{.OsVersion}}', $Image)
    if ($r.ExitCode -ne 0) { return 0 }
    $parts = ([string]($r.Output | Select-Object -Last 1)).Trim() -split ' '
    if ($parts.Count -lt 2 -or $parts[0] -ne 'windows') { return 0 }
    $v = $parts[1] -split '\.'
    if ($v.Count -lt 3) { return 0 }
    return [int]$v[2]
}

function Test-SmrProcessIsolation {
    <#
    .SYNOPSIS
        True when an image of build ImageBuild can run process-isolated on a host of build HostBuild
        (Microsoft's rules: the builds must match, and a Server 2025 host also runs 2022 images).
    #>
    param([int] $HostBuild, [int] $ImageBuild)
    if ($HostBuild -eq $ImageBuild) { return $true }
    return ($HostBuild -eq 26100 -and $ImageBuild -eq 20348)
}

function ConvertFrom-SmrServiceTaskLine {
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

function Get-SmrServiceTask {
    param([Parameter(Mandatory = $true)][string] $Service, [string] $DockerCommand = 'docker')
    $r = Invoke-SmrDocker -DockerCommand $DockerCommand -ArgumentList @('service', 'ps', '--no-trunc', '--format', '{{json .}}', $Service)
    return @(ConvertFrom-SmrServiceTaskLine -Line $r.Output)
}

function Wait-SmrCondition {
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

function Get-SmrAdvertiseAddress {
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

function Initialize-SmrSwarm {
    <#
    .SYNOPSIS
        Makes sure the engine is a swarm manager. Returns @{ Initialised } so the caller can leave the
        swarm again if (and only if) this call created it.
    #>
    param([string] $AdvertiseAddr, [string] $DockerCommand = 'docker')
    $state = Invoke-SmrDocker -DockerCommand $DockerCommand -ArgumentList @('info', '--format', '{{.Swarm.LocalNodeState}} {{.Swarm.ControlAvailable}}')
    $parts = ([string]($state.Output | Select-Object -First 1)).Trim() -split ' '
    if ($parts[0] -eq 'active' -and $parts[1] -eq 'true') { return @{ Initialised = $false } }
    if ($parts[0] -eq 'active') { throw 'this node is a swarm worker; run the test on a manager' }
    if (-not $AdvertiseAddr) { $AdvertiseAddr = Get-SmrAdvertiseAddress }
    $r = Invoke-SmrDocker -DockerCommand $DockerCommand -ArgumentList @('swarm', 'init', '--advertise-addr', $AdvertiseAddr)
    if ($r.ExitCode -ne 0) { throw "docker swarm init failed: $($r.Output -join ' ')" }
    return @{ Initialised = $true }
}

function Get-SmrNodeId {
    param([string] $DockerCommand = 'docker')
    $r = Invoke-SmrDocker -DockerCommand $DockerCommand -ArgumentList @('info', '--format', '{{.Swarm.NodeID}}')
    return ([string]($r.Output | Select-Object -First 1)).Trim()
}

function Grant-SmrAuthenticatedUserRead {
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

function Get-SmrStackEnvironment {
    <#
    .SYNOPSIS
        The environment the stack file gives every stock service: the x-runner-env and x-stock-env anchors of
        runners.yaml as a hashtable, without the entries that need Swarm to render a template. The tests run
        containers with exactly this, so a change to the stack file is what gets tested.
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
        if ($value -notmatch '\{\{') { $result[$name] = $value }
    }
    return $result
}

function ConvertTo-SmrEnvArgument {
    <#
    .SYNOPSIS
        A hashtable as "--env", "NAME=value" pairs for docker run.
    #>
    param([Parameter(Mandatory = $true)][hashtable] $Environment)
    $list = @()
    foreach ($k in ($Environment.Keys | Sort-Object)) { $list += @('--env', "$k=$($Environment[$k])") }
    return $list
}

function Get-SmrStockMountArgument {
    <#
    .SYNOPSIS
        The two read-only mounts of a stock-image service as docker run arguments: SmrRoot at C:\smr, and
        SmrRoot\git at C:\Program Files\Git (the path the task agent hard-codes for tar.exe).
    #>
    param([string] $SmrRoot = 'C:\smr')
    return @('--mount', "type=bind,source=$SmrRoot,target=C:\smr,readonly",
        '--mount', "type=bind,source=$SmrRoot\git,target=C:\Program Files\Git,readonly")
}

function Initialize-SmrFakeRunner {
    <#
    .SYNOPSIS
        Compiles fixtures\FakeRunner.cs with the csc.exe that ships with .NET Framework and returns the path of
        FakeRunner.exe in OutputDirectory. The directory is made readable for containers.
    #>
    param([Parameter(Mandatory = $true)][string] $OutputDirectory, [Parameter(Mandatory = $true)][string] $SourcePath)
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found at $csc (it ships with .NET Framework)" }
    $exe = Join-Path $OutputDirectory 'FakeRunner.exe'
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& $csc /nologo "/out:$exe" $SourcePath 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($code -ne 0) { throw "csc failed: $($output -join ' ')" }
    Grant-SmrAuthenticatedUserRead -Path $OutputDirectory
    return $exe
}

function Measure-SmrFakeJobLine {
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

Export-ModuleMember -Function Invoke-SmrDocker, Write-SmrCheck, Get-SmrCheckCount, Clear-SmrCheckCount, Get-SmrHostBuild, Get-SmrWindowsTag,
Get-SmrImageBuild, Test-SmrProcessIsolation, ConvertFrom-SmrServiceTaskLine, Get-SmrServiceTask, Wait-SmrCondition, Get-SmrAdvertiseAddress,
Initialize-SmrSwarm, Get-SmrNodeId, Grant-SmrAuthenticatedUserRead, Initialize-SmrFakeRunner, Get-SmrStackEnvironment, ConvertTo-SmrEnvArgument, Get-SmrStockMountArgument, Measure-SmrFakeJobLine
