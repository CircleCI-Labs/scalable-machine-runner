<#
.SYNOPSIS
    OPTIONAL helper for the Windows runner stack: checks the host, creates the swarm, labels the node and creates the token
    secrets. The runner is not installed here: the runner-distributor-windows service of the stack does that on every node. The
    Windows docs list the same steps as plain commands.
    Windows PowerShell 5.1, in an elevated prompt on the container host. Safe to run again.

.DESCRIPTION
    1. Preflight, printed as "CHECK <name> PASS|FAIL": administrator, Windows Server build, Docker in
       Windows-container mode, Swarm manager (-InitSwarm -AdvertiseAddr <ip> creates one; the address is required, a plain "docker swarm init" fails on some hosts).
       Pull the stock image BEFORE -InitSwarm: the network drops for a few seconds after it.
    2. -InitSwarm -AdvertiseAddr <ip>: docker swarm init, and the label machine-runner-swarm.proxy=true on this node, the node of the
       token proxy (it keeps its state there).
    3. Labels the node with the image tags it can run (the stack files' placement uses them): Server 2022
       gets machine-runner-swarm.windows-ltsc2022=true, Server 2025 gets machine-runner-swarm.windows-ltsc2022=true
       AND machine-runner-swarm.windows-ltsc2025=true, because a 2025 host also runs ltsc2022 images. Server 2019
       is untested and gets no label.
    4. -Class <name>,...: asks for each class's runner token (hidden input) and creates the Swarm secret
       <name>-token. The secret is a minimal runner config file ("api: auth_token: ..."); everything
       else the runner needs is an environment variable in the stack file. Existing secrets are kept. The class secrets belong
       to the token proxy; every runner reads runner-placeholder-token instead (a made-up token), which this step creates too.
    5. -Deploy: docker stack deploy. Without -StackFile it deploys the shipped windows\stack\runners.yaml as it is
       (a first run: it needs just windows-default-token). Once you keep your own copy of the stack files, pass them:
       -StackFile takes one or more files and replaces the default; list runners.yaml first, then each add-on file
       such as custom-image.yaml. The files that are deployed are printed.
    The distributor reads MACHINE_RUNNER_SWARM_RUNNER_VERSION, _RUNNER_MAJOR, _CHECK_INTERVAL, _DOWNLOAD_BASE_URL,
    _RUNNER_SHA256 and _TOOLS_BASE_URL, and for the token proxy _PROXY_VERSION, _PROXY_BASE_URL and _PROXY_SHA256, from the
    environment of -Deploy (docs\operations.md).

.EXAMPLE
    # A first run: the shipped runners.yaml, unchanged.
    .\windows\Setup.ps1 -InitSwarm -AdvertiseAddr 10.0.0.5 -Class windows-default -Deploy

.EXAMPLE
    # Your copies of the stack files (docs\install-windows.md).
    .\windows\Setup.ps1 -Class windows-default,windows-custom -Deploy `
        -StackFile .\deploy\runners.yaml,.\deploy\custom-image.yaml
#>
[CmdletBinding()]
param(
    [switch] $InitSwarm,
    [string] $AdvertiseAddr,
    [string[]] $Class = @(),
    [switch] $Deploy,
    [string[]] $StackFile = @((Join-Path $PSScriptRoot 'stack\runners.yaml')),
    [string] $StackName = 'runners'
)

function Write-Check {
    param([string] $Name, [bool] $Ok, [string] $Detail = '')
    $verdict = 'FAIL'
    if ($Ok) { $verdict = 'PASS' }
    [Console]::Out.WriteLine("CHECK $Name $verdict $Detail")
    return $Ok
}

function Get-BuildLabel {
    # Server 2022 is build 20348, Server 2025 is build 26100: the tag of the matching Server Core image.
    param([int] $Build)
    if ($Build -eq 20348) { return 'ltsc2022' }
    if ($Build -eq 26100) { return 'ltsc2025' }
    return $null
}

function Get-CapabilityLabel {
    # The image tags a host can run, as node label names: process isolation needs the image build to be the host's or an older
    # one, so a Server 2025 host runs ltsc2022 images too, and a Server 2022 host cannot run ltsc2025 images (0xc0370101).
    param([int] $Build)
    if ($Build -eq 20348) { return @('windows-ltsc2022') }
    if ($Build -eq 26100) { return @('windows-ltsc2022', 'windows-ltsc2025') }
    return @()
}

function Install-CapabilityLabel {
    # docker node update --label-add machine-runner-swarm.<name>=true for every capability of the host. A failure stops the
    # script: without the label every replica stays Pending and nothing says why.
    param([string] $NodeId, [int] $Build)
    foreach ($name in @(Get-CapabilityLabel -Build $Build)) {
        $r = Invoke-Docker @('node', 'update', '--label-add', "machine-runner-swarm.$name=true", $NodeId)
        if ($r.ExitCode -ne 0) { throw "docker node update --label-add machine-runner-swarm.$name=true failed: $($r.Output -join ' ')" }
        [Console]::Out.WriteLine("node $NodeId labelled machine-runner-swarm.$name=true")
    }
}

function Invoke-Docker {
    # Windows PowerShell 5.1 turns native stderr into a terminating error under 'Stop': run with Continue.
    param([string[]] $ArgumentList, [string] $StdIn)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($PSBoundParameters.ContainsKey('StdIn')) { $out = @($StdIn | & docker @ArgumentList 2>&1) } else { $out = @(& docker @ArgumentList 2>&1) }
        $code = $LASTEXITCODE
    } catch { $out = @($_.Exception.Message); $code = 127 } finally { $ErrorActionPreference = $saved }
    return @{ ExitCode = $code; Output = @($out | ForEach-Object { "$_" }) }
}

function Get-DockerInfo {
    # OSType, swarm state, whether this node is a manager, and the node ID; $null without a working docker.
    $r = Invoke-Docker @('info', '--format', '{{.OSType}}|{{.Swarm.LocalNodeState}}|{{.Swarm.ControlAvailable}}|{{.Swarm.NodeID}}')
    if ($r.ExitCode -ne 0) { return $null }
    $f = ([string]($r.Output | Select-Object -First 1)) -split '\|'
    return @{ OSType = $f[0]; Swarm = $f[1]; Manager = ($f[2] -eq 'true'); NodeId = $f[3] }
}

function Test-Preflight {
    # Returns $true when nothing failed.
    param([switch] $WillInitSwarm)
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $d = Get-DockerInfo
    $ok = @((Write-Check 'administrator' $admin 'run this in an elevated PowerShell'),
        (Write-Check 'windows-server' ($os.ProductType -eq 3 -and [bool](Get-BuildLabel -Build ([int]$os.BuildNumber))) "$($os.Caption) build $($os.BuildNumber); Server 2022 and 2025 are targeted"),
        (Write-Check 'windows-containers' ($d -and $d.OSType -eq 'windows') 'docker must run in Windows-container mode'),
        (Write-Check 'swarm-manager' ($d -and (($d.Swarm -eq 'active' -and $d.Manager) -or ($WillInitSwarm -and $d.Swarm -eq 'inactive'))) 'use -InitSwarm -AdvertiseAddr <ip> to create a swarm'))
    return (@($ok | Where-Object { -not $_ }).Count -eq 0)
}

function Install-PlaceholderSecret {
    # The Swarm secret runner-placeholder-token is the config that every runner reads: a made-up token. The class tokens are the
    # secrets of the token proxy only. It holds nothing secret, so it is created without a prompt.
    if ((Invoke-Docker @('secret', 'inspect', 'runner-placeholder-token')).ExitCode -eq 0) { return }
    $r = Invoke-Docker @('secret', 'create', 'runner-placeholder-token', '-') -StdIn "api:`n  auth_token: machine-runner-swarm-placeholder`n"
    if ($r.ExitCode -ne 0) { throw "docker secret create runner-placeholder-token failed: $($r.Output -join ' ')" }
    [Console]::Out.WriteLine('created secret runner-placeholder-token')
}

function Install-ClassSecret {
    # The Swarm secret <class>-token holds a minimal runner config with the token, from a hidden prompt.
    param([string] $Name)
    if ((Invoke-Docker @('secret', 'inspect', "$Name-token")).ExitCode -eq 0) { [Console]::Out.WriteLine("secret $Name-token exists; leaving it"); return }
    $secure = Read-Host -Prompt "Runner token for class $Name (input hidden)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $token) { throw "no token entered for $Name" }
    $r = Invoke-Docker @('secret', 'create', "$Name-token", '-') -StdIn "api:`n  auth_token: $token`n"
    if ($r.ExitCode -ne 0) { throw "docker secret create $Name-token failed: $($r.Output -join ' ')" }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if (-not (Test-Preflight -WillInitSwarm:$InitSwarm)) { throw 'preflight failed, see the CHECK lines' }
    if ($InitSwarm -and -not $AdvertiseAddr) { throw '-InitSwarm needs -AdvertiseAddr <the IPv4 address of this host>' }
    if ($InitSwarm -and (Get-DockerInfo).Swarm -eq 'inactive') {
        $r = Invoke-Docker @('swarm', 'init', '--advertise-addr', $AdvertiseAddr)
        if ($r.ExitCode -ne 0) { throw "docker swarm init failed: $($r.Output -join ' ')" }
        for ($i = 0; $i -lt 15 -and -not (Get-DockerInfo).Manager; $i++) { Start-Sleep -Seconds 2 }   # the network blips after init
        # the node of the token proxy, which keeps its state there (windows\stack\runners.yaml)
        $r = Invoke-Docker @('node', 'update', '--label-add', 'machine-runner-swarm.proxy=true', (Get-DockerInfo).NodeId)
        if ($r.ExitCode -ne 0) { throw "docker node update --label-add machine-runner-swarm.proxy=true failed: $($r.Output -join ' ')" }
    }
    Install-CapabilityLabel -NodeId (Get-DockerInfo).NodeId -Build ([int](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber)
    if ($Class.Count -gt 0 -or $Deploy) { Install-PlaceholderSecret }
    foreach ($c in $Class) { Install-ClassSecret -Name $c }
    if ($Deploy) {
        [Console]::Out.WriteLine("deploying $($StackFile -join ', ') as stack $StackName")
        $r = Invoke-Docker (@('stack', 'deploy') + @($StackFile | ForEach-Object { '-c'; $_ }) + @($StackName))
        $r.Output | ForEach-Object { [Console]::Out.WriteLine($_) }
        if ($r.ExitCode -ne 0) { throw 'docker stack deploy failed' }
    }
    [Console]::Out.WriteLine("Next: docker stack deploy -c $($StackFile -join ' -c ') $StackName ; docker service logs ${StackName}_runner-distributor-windows ; docker stack ps $StackName --no-trunc. Keep the host clock synchronised, and enable BitLocker on the Docker root volume (Windows keeps secrets in clear text on the container disk).")
}
