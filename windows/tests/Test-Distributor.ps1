<#
.SYNOPSIS
    Tests what the runner distributor (windows\stack\runner-distributor.ps1) does on a node, against a local mirror
    (a manifest.json and tarballs of fake releases, read through file:// URLs) and a throw-away volume. Windows host, Docker in
    Windows-container mode. Needs no Swarm, no runner token and no Git download: the script runs with -Once -NoGit in a stock
    Server Core container, as the service does, and a container with the stock mounts of the stack plays the runner.

.DESCRIPTION
    Prints "CHECK <name> PASS|FAIL <detail>" lines and a RESULT line; exits 0 only when every check passed.

      pin             a pinned version is downloaded, verified and flipped to: current is a relative symbolic link to versions\<v>
      record          the binary SHA-256 is recorded next to the binary (sha256sum -c style), with the tarball hash and VERSION
      auto            version "current" resolves the version by the SHA-256 of the manifest's current entry, and follows it
      major           a current of another major version is not adopted: nothing is downloaded, current stays
      rollback        an installed version is switched to without the network (the mirror is gone)
      mismatch        a wrong SHA-256 installs nothing and flips nothing (exit 1); a list that holds the right one installs
      prune           only the last 3 versions that were active stay, never the active one
      tamper          a changed binary is replaced by a verified copy at the next check
      running-job     a container that runs version A keeps A when current moves to B (it mounted the link when it started), the
                      next container gets B, and a version that a container still runs is not removed (Windows locks it): it goes at
                      a later check, when the container has ended
      bad-setting     an invalid MACHINE_RUNNER_SWARM_RUNNER_VERSION exits 1 at once

.EXAMPLE
    .\windows\tests\Test-Distributor.ps1
#>
[CmdletBinding()]
param(
    [string] $Image,
    [ValidateSet('process', 'hyperv', 'default')][string] $Isolation = 'process',
    [string] $DockerCommand = 'docker'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'SwarmTestHelpers.psm1') -Force
if (-not $Image) { $Image = 'mcr.microsoft.com/windows/servercore:' + (Get-SwarmWindowsTag) }
$stackDir = (Resolve-Path (Join-Path $here '..\stack')).Path
$work = Join-Path ([IO.Path]::GetTempPath()) "swarm-dist-$PID"
$mirror = Join-Path $work 'mirror'
$volume = "swarm-dist-$PID"
$zeros = '0' * 64
$iso = @()
if ($Isolation -ne 'default') { $iso = @("--isolation=$Isolation") }
New-Item -ItemType Directory -Force -Path $mirror | Out-Null

$script:docker = $DockerCommand
function Invoke-Docker {
    param([string[]] $ArgumentList)
    return (Invoke-SwarmDocker -DockerCommand $script:docker -ArgumentList $ArgumentList)
}

# --- the mirror: fake releases whose binary reports its own version -------------------------------------------------------------
$published = @{}   # version -> tarball SHA-256
function Publish-Release {
    param([string] $Version)
    $stage = Join-Path $work "stage-$Version"
    $null = Initialize-SwarmFakeRunner -OutputDirectory $stage -SourcePath (Join-Path $here 'fixtures\FakeRunner.cs') -Version $Version -ExeName 'circleci-runner.exe'
    $dir = Join-Path $mirror $Version
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tgz = Join-Path $dir 'circleci-runner_windows_amd64.tar.gz'
    $null = & "$env:SystemRoot\System32\tar.exe" -czf $tgz -C $stage 'circleci-runner.exe'
    if ($LASTEXITCODE -ne 0) { throw "tar failed for $Version" }
    $published[$Version] = (Get-FileHash -LiteralPath $tgz -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Write-Manifest {
    # current (and edge) name the tarball of $Current, as CircleCI's manifest does: by the SHA-256 that a versioned entry has too
    param([string] $Current)
    $releases = [ordered]@{}
    foreach ($v in @($published.Keys | Sort-Object)) { $releases[$v] = @{ windows = @{ amd64 = @{ sha256 = $published[$v]; url = "file:///C:/mirror/$v/circleci-runner_windows_amd64.tar.gz" } } } }
    $releases['current'] = @{ windows = @{ amd64 = @{ sha256 = $published[$Current]; url = "file:///C:/mirror/$Current/circleci-runner_windows_amd64.tar.gz" } } }
    $releases['edge'] = $releases['current']
    [IO.File]::WriteAllText((Join-Path $mirror 'manifest.json'), (@{ releases = $releases } | ConvertTo-Json -Depth 8))
}

# --- one check of the distributor, in a container like the service's ----------------------------------------------------------
$script:log = ''
function Invoke-Distributor {
    param([string[]] $Environment = @(), [string] $BaseUrl = 'file:///C:/mirror')
    $envArgs = @('--env', "MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=$BaseUrl")
    foreach ($e in $Environment) { $envArgs += @('--env', $e) }
    $r = Invoke-Docker (@('run', '--rm') + $iso + @('--mount', "type=volume,source=$volume,target=C:\runner-bin",
            '--mount', "type=bind,source=$stackDir,target=C:\dist,readonly", '--mount', "type=bind,source=$mirror,target=C:\mirror,readonly") + $envArgs +
        @('--entrypoint', 'powershell.exe', $Image, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'C:\dist\runner-distributor.ps1', '-Once', '-NoGit'))
    $script:log = $r.Output -join "`n"
    [Console]::Out.WriteLine(($r.Output | ForEach-Object { "    | $_" }) -join "`n")
    return $r.ExitCode
}

function Read-Volume {
    # key=value lines about the volume, read in a stock container that mounts it read-only
    $cmd = @'
$r = 'C:\v'
"current=$(try { $i = Get-Item $r\current -Force -ErrorAction Stop; "$($i.LinkType) $(@($i.Target)[0])" } catch { 'none' })"
"versions=$(@(Get-ChildItem $r\versions -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) -join ',')"
$cur = "$r\current"
if (Test-Path $cur\bin\circleci-runner.exe) {
    "version=$((Get-Content $cur\VERSION -TotalCount 1).Trim())"
    "record=$((Get-Content $cur\SHA256 -TotalCount 1).Trim())"
    "exe=$((Get-FileHash $cur\bin\circleci-runner.exe -Algorithm SHA256).Hash.ToLowerInvariant())"
    "tarball=$((Get-Content $cur\TARBALL -TotalCount 1).Trim())"
}
"history=$(@(Get-Content $r\history -ErrorAction SilentlyContinue | ForEach-Object { ($_ -split ' ')[-1] }) -join ',')"
'@
    $r = Invoke-Docker (@('run', '--rm') + $iso + @('--mount', "type=volume,source=$volume,target=C:\v,readonly", '--entrypoint', 'powershell.exe', $Image, '-NoLogo', '-NoProfile', '-NonInteractive') + (Get-SwarmEncodedCommandArgument -Script $cmd))
    $kv = @{}
    foreach ($l in $r.Output) { if ($l -match '^([a-z]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] } }
    return $kv
}
function Get-DownloadCount([string] $Version) { return @([regex]::Matches($script:log, "downloading circleci-runner $([regex]::Escape($Version)) windows")).Count }

try {
    $null = Invoke-Docker @('volume', 'create', $volume)
    foreach ($v in '3.0.0', '3.1.0', '3.2.0', '3.3.0', '3.4.0', '4.0.0') { Publish-Release -Version $v }
    Write-Manifest -Current '3.0.0'

    # --- pin, record ---------------------------------------------------------------------------------------------------------
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.0.0')
    $kv = Read-Volume
    Write-SwarmCheck 'pin' ($rc -eq 0 -and $kv['current'] -eq 'SymbolicLink versions\3.0.0' -and $kv['version'] -eq '3.0.0' -and (Get-DownloadCount '3.0.0') -eq 1) "exit $rc; current: $($kv['current']); version: $($kv['version'])"
    $recordSha = ($kv['record'] -split ' ')[0]
    Write-SwarmCheck 'record' ($kv['exe'] -and $kv['exe'] -eq $recordSha -and $kv['record'] -match '  bin/circleci-runner\.exe$' -and ($kv['tarball'] -split ' ')[0] -eq $published['3.0.0']) "binary $($kv['exe']), record $recordSha, tarball $(($kv['tarball'] -split ' ')[0])"

    # --- auto: current names 3.1.0 by its SHA-256 ----------------------------------------------------------------------------
    Write-Manifest -Current '3.1.0'
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=current')
    $kv = Read-Volume
    Write-SwarmCheck 'auto' ($rc -eq 0 -and $kv['current'] -eq 'SymbolicLink versions\3.1.0' -and (Get-DownloadCount '3.1.0') -eq 1) "exit $rc; current: $($kv['current'])"

    # --- major: current moves to a version of another major ------------------------------------------------------------------
    Write-Manifest -Current '4.0.0'
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=current')
    $kv = Read-Volume
    Write-SwarmCheck 'major' ($rc -eq 0 -and $kv['current'] -eq 'SymbolicLink versions\3.1.0' -and $script:log -match 'not adopting it' -and (Get-DownloadCount '4.0.0') -eq 0 -and $kv['versions'] -notmatch '4\.0\.0') "exit $rc; current: $($kv['current']); versions: $($kv['versions'])"
    Write-Manifest -Current '3.1.0'

    # --- rollback: installed, so no network ----------------------------------------------------------------------------------
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.0.0') -BaseUrl 'file:///C:/nowhere'
    $kv = Read-Volume
    Write-SwarmCheck 'rollback' ($rc -eq 0 -and $kv['current'] -eq 'SymbolicLink versions\3.0.0' -and (Get-DownloadCount '3.0.0') -eq 0) "exit $rc; current: $($kv['current']); the mirror was unreachable"

    # --- mismatch ------------------------------------------------------------------------------------------------------------
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.2.0', "MACHINE_RUNNER_SWARM_RUNNER_SHA256=$zeros")
    $kv = Read-Volume
    Write-SwarmCheck 'mismatch' ($rc -eq 1 -and $script:log -match 'SHA-256 mismatch' -and $kv['versions'] -notmatch '3\.2\.0' -and $kv['current'] -eq 'SymbolicLink versions\3.0.0') "exit $rc; versions: $($kv['versions']); current: $($kv['current'])"
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.2.0', "MACHINE_RUNNER_SWARM_RUNNER_SHA256=$zeros,$($published['3.2.0'].ToUpperInvariant())")
    $kv = Read-Volume
    Write-SwarmCheck 'mismatch-list' ($rc -eq 0 -and $kv['current'] -eq 'SymbolicLink versions\3.2.0') "a list with the right hash (in capitals) installs: exit $rc; current: $($kv['current'])"

    # --- prune: 3.1.0, 3.0.0, 3.2.0 were active; two more ---------------------------------------------------------------------
    foreach ($v in '3.3.0', '3.4.0') { $null = Invoke-Distributor @("MACHINE_RUNNER_SWARM_RUNNER_VERSION=$v") }
    $kv = Read-Volume
    Write-SwarmCheck 'prune' ($kv['versions'] -eq '3.2.0,3.3.0,3.4.0' -and $kv['current'] -eq 'SymbolicLink versions\3.4.0') "versions: $($kv['versions']); current: $($kv['current'])"

    # --- tamper: the active binary is changed; the next check replaces it ---------------------------------------------------------
    $null = Invoke-Docker (@('run', '--rm') + $iso + @('--mount', "type=volume,source=$volume,target=C:\v", '--entrypoint', 'powershell.exe', $Image, '-NoLogo', '-NoProfile', '-NonInteractive') +
        (Get-SwarmEncodedCommandArgument -Script "Add-Content -LiteralPath C:\v\versions\3.4.0\bin\circleci-runner.exe -Value 'tampered' -Encoding ASCII"))
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.4.0')
    $kv = Read-Volume
    Write-SwarmCheck 'tamper' ($rc -eq 0 -and $kv['exe'] -eq ($kv['record'] -split ' ')[0] -and (Get-DownloadCount '3.4.0') -eq 1 -and $kv['current'] -eq 'SymbolicLink versions\3.4.0') "exit $rc; downloads of 3.4.0: $(Get-DownloadCount '3.4.0'); versions: $($kv['versions'])"

    # --- running-job: a container that runs 3.2.0 while current moves on ---------------------------------------------------------
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.2.0')   # back to 3.2.0: the container below mounts it
    # the runner mount of the stack only: this volume has no Git
    $mounts = @('--mount', "type=volume,source=$volume,target=C:\machine-runner-swarm,readonly,volume-subpath=current")
    $job = "swarm-dist-job-$PID"
    $r = Invoke-Docker (@('run', '--detach', '--name', $job) + $iso + $mounts + @('--env', 'FAKE_JOB_SECONDS=240', '--entrypoint', 'C:\machine-runner-swarm\bin\circleci-runner.exe', $Image, 'machine'))
    $started = Wait-SwarmCondition -TimeoutSeconds 90 -IntervalSeconds 3 -Condition { ((Invoke-Docker @('logs', $job)).Output -join ' ') -match 'FAKERUNNER started' }
    Write-SwarmCheck 'running-job-started' ($r.ExitCode -eq 0 -and $started) "a container runs version 3.2.0 from the link current"
    foreach ($v in '3.3.0', '3.1.0') { $null = Invoke-Distributor @("MACHINE_RUNNER_SWARM_RUNNER_VERSION=$v") }   # current moves on; 3.2.0 leaves the last three
    $null = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.0.0')
    $null = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.4.0')
    $kv = Read-Volume
    $still = (Invoke-Docker @('inspect', '--format', '{{.State.Running}}', $job)).Output -join ''
    $seen = (Invoke-Docker @('exec', $job, 'powershell.exe', '-NoProfile', '-Command', 'Get-Content C:\machine-runner-swarm\VERSION -TotalCount 1')).Output -join ''
    $next = (Invoke-Docker (@('run', '--rm') + $iso + $mounts + @('--entrypoint', 'powershell.exe', $Image, '-NoProfile', '-Command', 'Get-Content C:\machine-runner-swarm\VERSION -TotalCount 1'))).Output -join ''
    Write-SwarmCheck 'running-job-keeps-its-version' ($still -match 'true' -and $seen.Trim() -eq '3.2.0' -and $next.Trim() -eq '3.4.0') "the running container sees $($seen.Trim()), the next one sees $($next.Trim()); running: $still"
    Write-SwarmCheck 'running-job-in-use' ($kv['versions'] -match '3\.2\.0' -and $script:log -match 'is in use|removing it at a later check') "versions: $($kv['versions']); the distributor leaves a version in use for a later check"
    $null = Invoke-Docker @('rm', '--force', $job)
    $null = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.4.0')
    $kv = Read-Volume
    Write-SwarmCheck 'running-job-removed-later' ($kv['versions'] -notmatch '3\.2\.0') "after the container ended: $($kv['versions'])"

    # --- bad-setting -----------------------------------------------------------------------------------------------------------
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=latest')
    Write-SwarmCheck 'bad-setting' ($rc -eq 1 -and $script:log -match 'must be current or a version') "exit $rc"
} finally {
    $null = Invoke-Docker @('rm', '--force', "swarm-dist-job-$PID")
    $null = Invoke-Docker @('volume', 'rm', '--force', $volume)
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$count = Get-SwarmCheckCount
$verdict = 'PASS'
if ($count.Failed -gt 0) { $verdict = 'FAIL' }
[Console]::Out.WriteLine("RESULT distributor checks=$($count.Checks) failed=$($count.Failed) verdict=$verdict")
if ($count.Failed -gt 0) { exit 1 }
exit 0
