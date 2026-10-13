<#
.SYNOPSIS
    OPTIONAL helper for the Windows runner stack: checks the host, stages C:\smr, labels the node and
    creates the token secrets. The Windows docs list the same steps as plain commands.
    Windows PowerShell 5.1, in an elevated prompt on the container host. Safe to run again.

.DESCRIPTION
    1. Preflight, printed as "CHECK <name> PASS|FAIL": administrator, Windows Server build, Docker in
       Windows-container mode, Swarm manager (-InitSwarm -AdvertiseAddr <ip> creates one; the address is required, a plain "docker swarm init" fails on some hosts).
    2. Stages -InstallDir (default C:\smr): bin\circleci-runner.exe (SHA-256 from CircleCI's release
       manifest) and git\ (portable Git for Windows, pinned SHA-256, bash/tar/gzip included). Containers
       read it as themselves, so SYSTEM and Administrators get full control and Authenticated Users
       read and execute; a job cannot modify it. Skipped when the same versions are already there. Done BEFORE
       any swarm init, because the network drops for a few seconds after it.
    3. Labels the node windows.build=ltsc2022|ltsc2025 (the stack file's placement uses it).
    4. -Class <name>,...: asks for each class's runner token (hidden input) and creates the Swarm secret
       <name>-token. The secret is a minimal runner config file ("api: auth_token: ..."); everything
       else the runner needs is an environment variable in the stack file. Existing secrets are kept.
    5. -Deploy: docker stack deploy. -StackFile takes one or more files and replaces the default
       (windows\stack\runners.yaml, which deploys alone with just windows-default-token); list
       runners.yaml first, then each overlay such as custom-image.yaml.
    -StageOnly stops after step 2 and needs no Docker.

.EXAMPLE
    .\windows\Setup.ps1 -InitSwarm -AdvertiseAddr 10.0.0.5 -Class windows-default -Deploy

.EXAMPLE
    .\windows\Setup.ps1 -Class windows-default,windows-custom -Deploy `
        -StackFile .\windows\stack\runners.yaml,.\windows\stack\custom-image.yaml
#>
[CmdletBinding()]
param(
    [string] $InstallDir = 'C:\smr',
    [string] $RunnerVersion = '3.1.12',
    [switch] $StageOnly,
    [switch] $InitSwarm,
    [string] $AdvertiseAddr,
    [string[]] $Class = @(),
    [switch] $Deploy,
    [string[]] $StackFile = @((Join-Path $PSScriptRoot 'stack\runners.yaml')),
    [string] $StackName = 'smr',
    [switch] $Force
)

# Pinned. windows\images\servercore\Dockerfile pins the same Git and 7-Zip (a unit test checks they match).
$script:Pins = @{
    GitVersion      = '2.56.0.2'
    GitReleaseTag   = 'v2.56.0.windows.2'
    GitSha256       = '075e158ef8e1f0ab80b347e245405d3eca735c2dc88fd8e032e137d0ca61f61b'
    SevenZipVersion = '26.04'
    SevenZipSha256  = '256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282'
}
$script:ManifestUrl = 'https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/manifest.json'

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
    param([switch] $SkipDocker, [switch] $WillInitSwarm)
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $ok = @((Write-Check 'administrator' $admin 'run this in an elevated PowerShell'),
        (Write-Check 'windows-server' ($os.ProductType -eq 3 -and [bool](Get-BuildLabel -Build ([int]$os.BuildNumber))) "$($os.Caption) build $($os.BuildNumber); Server 2022 and 2025 are targeted"))
    if (-not $SkipDocker) {
        $d = Get-DockerInfo
        $ok += Write-Check 'windows-containers' ($d -and $d.OSType -eq 'windows') 'docker must run in Windows-container mode'
        $ok += Write-Check 'swarm-manager' ($d -and (($d.Swarm -eq 'active' -and $d.Manager) -or ($WillInitSwarm -and $d.Swarm -eq 'inactive'))) 'use -InitSwarm -AdvertiseAddr <ip> to create a swarm'
    }
    return (@($ok | Where-Object { -not $_ }).Count -eq 0)
}

function Invoke-Acl {
    & icacls.exe @args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls $args failed" }
}

function Protect-Directory {
    # ACL on the directory only (inheritance cut), then reset every child to inherit it: "/inheritance:r /T" in one
    # call leaves the children with an empty ACL.
    param([string] $Dir)
    Invoke-Acl $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-11:(OI)(CI)RX'
    Invoke-Acl ($Dir.TrimEnd('\') + '\*') /reset /T /C /Q
}

function Install-Stage {
    param([string] $Dir, [string] $Version, [switch] $Force)
    $versionFile = Join-Path $Dir 'VERSION'
    $want = @("runner=$Version", "git=$($script:Pins.GitVersion)")
    $have = @()
    if (Test-Path -LiteralPath $versionFile) { $have = @(Get-Content -LiteralPath $versionFile) }
    if (-not $Force -and ($have -join ',') -eq ($want -join ',') -and (Test-Path -LiteralPath (Join-Path $Dir 'git\usr\bin\tar.exe'))) {
        [Console]::Out.WriteLine("$Dir already has runner $Version and Git $($script:Pins.GitVersion)")
        return
    }
    $manifest = (Invoke-WebRequest -Uri $script:ManifestUrl -UseBasicParsing).Content | ConvertFrom-Json
    $entry = $manifest.releases.$Version.windows.amd64
    if (-not $entry) { throw "runner version '$Version' has no windows/amd64 build in the release manifest" }
    $installer = Join-Path $PSScriptRoot 'images\servercore\install-runner.ps1'
    & $installer -RunnerVersion $Version -RunnerSha256 $entry.sha256 -GitVersion $script:Pins.GitVersion -GitReleaseTag $script:Pins.GitReleaseTag `
        -GitSha256 $script:Pins.GitSha256 -SevenZipVersion $script:Pins.SevenZipVersion -SevenZipSha256 $script:Pins.SevenZipSha256 `
        -RunnerDir (Join-Path $Dir 'bin') -GitDir (Join-Path $Dir 'git')
    Set-Content -LiteralPath $versionFile -Value $want -Encoding ASCII
    Protect-Directory -Dir $Dir
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
    if (-not (Test-Preflight -SkipDocker:$StageOnly -WillInitSwarm:$InitSwarm)) { throw 'preflight failed, see the CHECK lines' }
    if ($InitSwarm -and -not $AdvertiseAddr -and -not $StageOnly) { throw '-InitSwarm needs -AdvertiseAddr <the IPv4 address of this host>' }
    # Stage first: the network drops for a few seconds after "docker swarm init", and the downloads need it.
    Install-Stage -Dir $InstallDir -Version $RunnerVersion -Force:$Force
    if ($StageOnly) { return }
    if ($InitSwarm -and (Get-DockerInfo).Swarm -eq 'inactive') {
        $r = Invoke-Docker @('swarm', 'init', '--advertise-addr', $AdvertiseAddr)
        if ($r.ExitCode -ne 0) { throw "docker swarm init failed: $($r.Output -join ' ')" }
        for ($i = 0; $i -lt 15 -and -not (Get-DockerInfo).Manager; $i++) { Start-Sleep -Seconds 2 }   # the network blips after init
    }
    $label = Get-BuildLabel -Build ([int](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber)
    $null = Invoke-Docker @('node', 'update', '--label-add', "windows.build=$label", (Get-DockerInfo).NodeId)
    foreach ($c in $Class) { Install-ClassSecret -Name $c }
    if ($Deploy) {
        $r = Invoke-Docker (@('stack', 'deploy') + @($StackFile | ForEach-Object { '-c'; $_ }) + @($StackName))
        $r.Output | ForEach-Object { [Console]::Out.WriteLine($_) }
        if ($r.ExitCode -ne 0) { throw 'docker stack deploy failed' }
    }
    [Console]::Out.WriteLine("Next: docker stack deploy -c $($StackFile -join ' -c ') $StackName ; docker stack ps $StackName --no-trunc. Keep the host clock synchronised, and enable BitLocker on the Docker root volume (Windows keeps secrets in clear text on the container disk).")
}
