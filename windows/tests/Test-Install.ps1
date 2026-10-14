<#
.SYNOPSIS
    Proves the install path on a Windows host: the shipped windows\stack\runners.yaml is deployed with no runner replicas, and
    its service runner-distributor-windows installs CircleCI's current runner release and portable Git from CircleCI's real
    manifest and the pinned GitHub downloads. Windows host, Docker in Windows-container mode, Swarm manager. Needs no runner token.

.DESCRIPTION
    Leaves the stack (default name "runners") deployed, so the volume runners_runner-bin stays filled for the tests that follow
    (Test-Injection, Test-Exit80, Test-StopHandling mount it). Prints "CHECK <name> PASS|FAIL <detail>" lines and a RESULT line;
    exits 0 only when every check passed.

      distributor        the service installs both and flips current and git\current (the first download takes minutes)
      version            the version directory is the release that the manifest names as current (by SHA-256), within major 3
      record             the SHA-256 recorded for circleci-runner.exe is the file's, and TARBALL is the manifest's hash
      links              current and git\current are relative directory symbolic links to versions\<v> and git\<git version>
      runner             circleci-runner.exe --version runs through the read-only mount of a stock container
      git                git, bash and GNU tar run from C:\Program Files\Git, and a job cannot write to either mount
      no-host-install    C:\machine-runner-swarm does not exist on the host

.EXAMPLE
    .\windows\tests\Test-Install.ps1
#>
[CmdletBinding()]
param(
    [string] $Image,
    [string] $Stack = 'runners',
    [int] $TimeoutSeconds = 1500,
    [ValidateSet('process', 'hyperv', 'default')][string] $Isolation = 'process',
    [string] $AdvertiseAddr,
    [string] $DockerCommand = 'docker'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'SwarmTestHelpers.psm1') -Force
if (-not $Image) { $Image = 'mcr.microsoft.com/windows/servercore:' + (Get-SwarmWindowsTag) }
$volume = "${Stack}_runner-bin"
$iso = @()
if ($Isolation -ne 'default') { $iso = @("--isolation=$Isolation") }

function Invoke-Docker {
    param([string[]] $ArgumentList)
    return (Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList $ArgumentList)
}

function Invoke-Probe {
    # A stock container with extra mounts runs one PowerShell command; returns the output lines.
    param([string[]] $Mount, [string] $Command)
    $r = Invoke-Docker (@('run', '--rm') + $iso + $Mount + @('--entrypoint', 'powershell.exe', $Image, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass') + (Get-SwarmEncodedCommandArgument -Script $Command))
    return @($r.Output)
}

$null = Initialize-SwarmCluster -AdvertiseAddr $AdvertiseAddr -DockerCommand $DockerCommand
$started = Install-SwarmDistributor -Stack $Stack -TimeoutSeconds $TimeoutSeconds -DockerCommand $DockerCommand
[Console]::Out.WriteLine($started.Log)
Write-SwarmCheck 'distributor' $started.Ok $(if ($started.Ok) { 'the distributor installed the runner and Git' } else { $started.Detail })

if ($started.Ok) {
    $all = @('--mount', "type=volume,source=$volume,target=C:\v,readonly")
    $info = @(Invoke-Probe -Mount $all -Command @'
$cur = (Get-Item C:\v\current -Force)
$git = (Get-Item C:\v\git\current -Force)
"curlink=$($cur.LinkType) $(@($cur.Target)[0])"
"gitlink=$($git.LinkType) $(@($git.Target)[0])"
$v = (Get-Content C:\v\current\VERSION -TotalCount 1).Trim()
"version=$v"
"record=$((Get-Content C:\v\current\SHA256 -TotalCount 1).Trim())"
"exe=$((Get-FileHash C:\v\current\bin\circleci-runner.exe -Algorithm SHA256).Hash.ToLowerInvariant())"
"tarball=$((Get-Content C:\v\current\TARBALL -TotalCount 1).Trim())"
"portablegit=$((Get-Content C:\v\git\current\PORTABLEGIT -TotalCount 1).Trim())"
'@)
    $kv = @{}
    foreach ($l in $info) { if ($l -match '^([a-z]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] } }
    [Console]::Out.WriteLine(($info -join "`n"))

    $manifest = (Invoke-WebRequest -Uri 'https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/manifest.json' -UseBasicParsing).Content | ConvertFrom-Json
    $curSha = ([string]$manifest.releases.current.windows.amd64.sha256).ToLowerInvariant()
    $version = $kv['version']
    $listed = ''
    if ($version -and $manifest.releases.$version) { $listed = ([string]$manifest.releases.$version.windows.amd64.sha256).ToLowerInvariant() }
    $major3 = $version -match '^3\.'
    Write-SwarmCheck 'version' ($major3 -and $listed -and $listed -eq $curSha) "installed $version; the manifest's current has SHA-256 $curSha, that version's entry has $listed"
    $exeSha = $kv['exe']
    $recordSha = ($kv['record'] -split ' ')[0]
    $tarSha = ($kv['tarball'] -split ' ')[0]
    Write-SwarmCheck 'record' ($exeSha -and $exeSha -eq $recordSha -and $kv['record'] -match '  bin/circleci-runner\.exe$' -and $tarSha -eq $curSha) "binary $exeSha, record $recordSha, tarball $tarSha"
    Write-SwarmCheck 'links' ($kv['curlink'] -eq "SymbolicLink versions\$version" -and $kv['gitlink'] -match '^SymbolicLink [0-9.]+$') "current: $($kv['curlink']); git\current: $($kv['gitlink'])"

    $stock = Get-SwarmStockMountArgument -Volume $volume
    $run = @(Invoke-Probe -Mount $stock -Command @'
& 'C:\machine-runner-swarm\bin\circleci-runner.exe' --version 2>&1 | Select-Object -First 1 | ForEach-Object { "runner=$_" }
"git=$((& 'C:\Program Files\Git\cmd\git.exe' --version 2>&1) -join ' ')"
"bash=$((& 'C:\Program Files\Git\usr\bin\bash.exe' -c 'echo bash-ok' 2>&1) -join ' ')"
"tar=$((& 'C:\Program Files\Git\usr\bin\tar.exe' --version 2>&1 | Select-Object -First 1) -join ' ')"
foreach ($p in 'C:\machine-runner-swarm\job-wrote-this', 'C:\Program Files\Git\job-wrote-this') {
    try { Set-Content -LiteralPath $p -Value x -ErrorAction Stop; "write=WRITABLE" } catch { "write=READONLY" }
}
'@)
    [Console]::Out.WriteLine(($run -join "`n"))
    $text = $run -join "`n"
    Write-SwarmCheck 'runner' ($text -match "runner=.*version $([regex]::Escape($version))") "circleci-runner.exe --version through the mount"
    Write-SwarmCheck 'git' ($text -match 'git=git version' -and $text -match 'bash=bash-ok' -and $text -match 'tar=tar \(GNU tar\)' -and @([regex]::Matches($text, 'write=READONLY')).Count -eq 2 -and $text -notmatch 'write=WRITABLE') 'git, bash and GNU tar run; both mounts are read-only'
}
Write-SwarmCheck 'no-host-install' (-not (Test-Path -LiteralPath 'C:\machine-runner-swarm')) 'nothing was staged on the host'

$count = Get-SwarmCheckCount
$verdict = 'PASS'
if ($count.Failed -gt 0) { $verdict = 'FAIL' }
[Console]::Out.WriteLine("RESULT install checks=$($count.Checks) failed=$($count.Failed) stack=$Stack verdict=$verdict")
if ($count.Failed -gt 0) { exit 1 }
exit 0
