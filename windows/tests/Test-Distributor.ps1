<#
.SYNOPSIS
    Tests what the runner distributor (windows\stack\runner-distributor.ps1) does on a node, against a local mirror
    (a manifest.json and tarballs of fake releases, read through file:// URLs) and a throw-away volume. Windows host, Docker in
    Windows-container mode. Needs no Swarm, no runner token and no Git download: the script runs with -Once -NoGit in a stock
    Server Core container, as the service does, and a container with the stock mounts of the stack plays the runner.

.DESCRIPTION
    Prints "CHECK <name> PASS|FAIL <detail>" lines and a RESULT line; exits 0 only when every check passed.

      pin             an exact version is downloaded, verified and flipped to: current is a relative symbolic link to versions\<v>
      record          the binary SHA-256 is recorded next to the binary (sha256sum -c style), with the tarball hash and VERSION
      auto            version "current" resolves the version by the SHA-256 of the manifest's current entry, and follows it
      major           a current of another major version is not adopted: nothing is downloaded, current stays
      rollback        an installed version is switched to without the network (the mirror is gone)
      mismatch        a wrong SHA-256 installs nothing and flips nothing (exit 1); a list that holds the right one installs
      floating        3.1 follows the newest 3.1.x and 3 the newest 3.x.y of the manifest, and never another major version
      arm64           with -Architecture arm64 the arm64 tarball and the arm64 build of the manifest are used, and the record names the file
      prune           only the last 3 versions that were active stay, never the active one
      tamper          a changed binary is replaced by a verified copy at the next check
      running-job     a container that runs version A keeps A when current moves to B (it mounted the link when it started), the
                      next container gets B, and a version that a container still runs is not removed (Windows locks it): it goes at
                      a later check, when the container has ended
      proxy-*         the token proxy: installed from the release files of a mirror (SHA256SUMS next to the binary) with its record, a wrong line or
                      a hash that MACHINE_RUNNER_SWARM_PROXY_SHA256 does not allow installs nothing and the runner stays, only the last 2
                      active versions stay, a changed binary is replaced, "unreleased" installs the latest published release (the tag
                      of the latest-release URL), and with no release published it says so, installs none and keeps the runner
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
    Copy-Item -LiteralPath $tgz -Destination (Join-Path $dir 'circleci-runner_windows_arm64.tar.gz')   # the same bytes under the arm64 name: only the names are tested
    $published[$Version] = (Get-FileHash -LiteralPath $tgz -Algorithm SHA256).Hash.ToLowerInvariant()
}
$publishedProxy = @{}   # version -> SHA-256 of the fake proxy binary
function Publish-Proxy {
    # A fake release of the token proxy as GitHub has it: v<version>\machine-runner-swarm-proxy_windows_amd64 and v<version>\SHA256SUMS
    # (with the lines of other platforms around it). WrongLine writes a hash that is not the binary's.
    param([string] $Version, [switch] $WrongLine)
    $stage = Join-Path $work "proxy-stage-$Version"
    $null = Initialize-SwarmFakeRunner -OutputDirectory $stage -SourcePath (Join-Path $here 'fixtures\FakeRunner.cs') -Version $Version -ExeName 'machine-runner-swarm-proxy.exe'
    $dir = Join-Path $mirror "proxy\v$Version"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $asset = Join-Path $dir 'machine-runner-swarm-proxy_windows_amd64'
    Copy-Item -LiteralPath (Join-Path $stage 'machine-runner-swarm-proxy.exe') -Destination $asset
    Copy-Item -LiteralPath $asset -Destination (Join-Path $dir 'machine-runner-swarm-proxy_windows_arm64')   # the same bytes under the arm64 name
    $hash = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
    $line = $hash
    if ($WrongLine) { $line = '2' * 64 }
    [IO.File]::WriteAllText((Join-Path $dir 'SHA256SUMS'), "$zeros  machine-runner-swarm-proxy_linux_amd64`n$line  machine-runner-swarm-proxy_windows_amd64`n$line  machine-runner-swarm-proxy_windows_arm64`n")
    # what the latest-release URL of GitHub answers while this is the newest release (the test points at it with file://)
    [IO.File]::WriteAllText((Join-Path $dir 'latest.json'), "{ `"tag_name`": `"v$Version`", `"draft`": false, `"prerelease`": false }`n")
    $publishedProxy[$Version] = $hash
}
function Write-Manifest {
    # current (and edge) name the tarball of $Current, as CircleCI's manifest does: by the SHA-256 that a versioned entry has too
    param([string] $Current)
    $releases = [ordered]@{}
    foreach ($v in @($published.Keys | Sort-Object)) {
        $releases[$v] = @{ windows = @{
                amd64 = @{ sha256 = $published[$v]; url = "file:///C:/mirror/$v/circleci-runner_windows_amd64.tar.gz" }
                arm64 = @{ sha256 = $published[$v]; url = "file:///C:/mirror/$v/circleci-runner_windows_arm64.tar.gz" }
            } }
    }
    $releases['current'] = @{ windows = @{
            amd64 = @{ sha256 = $published[$Current]; url = "file:///C:/mirror/$Current/circleci-runner_windows_amd64.tar.gz" }
            arm64 = @{ sha256 = $published[$Current]; url = "file:///C:/mirror/$Current/circleci-runner_windows_arm64.tar.gz" }
        } }
    $releases['edge'] = $releases['current']
    [IO.File]::WriteAllText((Join-Path $mirror 'manifest.json'), (@{ releases = $releases } | ConvertTo-Json -Depth 8))
}

# --- one check of the distributor, in a container like the service's ----------------------------------------------------------
$script:log = ''
function Invoke-Distributor {
    param([string[]] $Environment = @(), [string] $BaseUrl = 'file:///C:/mirror', [string[]] $ScriptArgument = @())
    $envArgs = @('--env', "MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=$BaseUrl")
    foreach ($e in $Environment) { $envArgs += @('--env', $e) }
    $r = Invoke-Docker (@('run', '--rm') + $iso + @('--mount', "type=volume,source=$volume,target=C:\runner-bin",
            '--mount', "type=bind,source=$stackDir,target=C:\dist,readonly", '--mount', "type=bind,source=$mirror,target=C:\mirror,readonly") + $envArgs +
        @('--entrypoint', 'powershell.exe', $Image, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'C:\dist\runner-distributor.ps1', '-Once', '-NoGit') + $ScriptArgument)
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

    # --- floating: 3.1 and 3 follow their line of the manifest, and never another major version ------------------------------------
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1')
    $kv = Read-Volume
    Write-SwarmCheck 'floating-minor' ($rc -eq 0 -and $kv['version'] -eq '3.1.0' -and $kv['current'] -eq 'SymbolicLink versions\3.1.0') "3.1 is the newest 3.1.x: exit $rc; version: $($kv['version'])"
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3')
    $kv = Read-Volume
    Write-SwarmCheck 'floating-major' ($rc -eq 0 -and $kv['version'] -eq '3.4.0' -and $script:log -notmatch 'downloading circleci-runner 4\.0\.0') "3 is the newest 3.x.y and no 4.x: exit $rc; version: $($kv['version'])"
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=5')
    Write-SwarmCheck 'floating-none' ($rc -eq 1 -and $script:log -match 'no windows/amd64 release in 5\.x') "a line that the manifest does not have installs nothing: exit $rc"

    # --- arm64: the file names and the manifest entry of the other architecture --------------------------------------------------
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=4.0.0') -ScriptArgument @('-Architecture', 'arm64')
    $kv = Read-Volume
    Write-SwarmCheck 'arm64' ($rc -eq 0 -and $script:log -match 'downloading circleci-runner 4\.0\.0 windows/arm64' -and $kv['tarball'] -match '  circleci-runner_windows_arm64\.tar\.gz$' -and $kv['version'] -eq '4.0.0') "exit $rc; record of the tarball: $($kv['tarball'])"

    # --- the token proxy: installed next to the runner, from the release files of a mirror -----------------------------------------
    foreach ($v in '0.0.1', '0.0.2', '0.0.3') { Publish-Proxy -Version $v }
    Publish-Proxy -Version '0.0.4' -WrongLine
    function Invoke-ProxyDistributor {
        param([string] $Version, [string[]] $Extra = @())
        return (Invoke-Distributor (@('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.4.0', "MACHINE_RUNNER_SWARM_PROXY_VERSION=$Version", 'MACHINE_RUNNER_SWARM_PROXY_BASE_URL=file:///C:/mirror/proxy') + $Extra))
    }
    function Read-ProxyVolume {
        $cmd = @'
$r = 'C:\v\proxy'
"pcurrent=$(try { $i = Get-Item $r\current -Force -ErrorAction Stop; "$($i.LinkType) $(@($i.Target)[0])" } catch { 'none' })"
"pversions=$(@(Get-ChildItem $r\versions -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) -join ',')"
$cur = "$r\current"
if (Test-Path $cur\bin\machine-runner-swarm-proxy.exe) {
    "pversion=$((Get-Content $cur\VERSION -TotalCount 1).Trim())"
    "precord=$((Get-Content $cur\SHA256 -TotalCount 1).Trim())"
    "pexe=$((Get-FileHash $cur\bin\machine-runner-swarm-proxy.exe -Algorithm SHA256).Hash.ToLowerInvariant())"
}
"runner=$((Get-Content C:\v\current\VERSION -TotalCount 1 -ErrorAction SilentlyContinue))"
'@
        $r = Invoke-Docker (@('run', '--rm') + $iso + @('--mount', "type=volume,source=$volume,target=C:\v,readonly", '--entrypoint', 'powershell.exe', $Image, '-NoLogo', '-NoProfile', '-NonInteractive') + (Get-SwarmEncodedCommandArgument -Script $cmd))
        $kv = @{}
        foreach ($l in $r.Output) { if ($l -match '^([a-z]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] } }
        return $kv
    }
    $rc = Invoke-ProxyDistributor '0.0.1'
    $kv = Read-ProxyVolume
    Write-SwarmCheck 'proxy-install' ($rc -eq 0 -and $kv['pcurrent'] -eq 'SymbolicLink versions\0.0.1' -and $kv['pversion'] -eq '0.0.1' -and $kv['pexe'] -eq $publishedProxy['0.0.1'] -and $kv['precord'] -eq "$($publishedProxy['0.0.1'])  bin/machine-runner-swarm-proxy.exe" -and $script:log -match 'downloading the token proxy 0\.0\.1') "exit $rc; proxy current: $($kv['pcurrent']); binary $($kv['pexe']); record $($kv['precord'])"
    $rc = Invoke-ProxyDistributor '0.0.1'
    Write-SwarmCheck 'proxy-again' ($rc -eq 0 -and $script:log -notmatch 'downloading the token proxy' -and $script:log -match 'token proxy 0\.0\.1 is installed already') "a second check downloads nothing: exit $rc"
    $rc = Invoke-ProxyDistributor '0.0.4'
    $kv = Read-ProxyVolume
    Write-SwarmCheck 'proxy-mismatch' ($rc -eq 1 -and $script:log -match 'SHA-256 mismatch for machine-runner-swarm-proxy_windows_amd64' -and $kv['pversions'] -notmatch '0\.0\.4' -and $kv['pcurrent'] -eq 'SymbolicLink versions\0.0.1' -and $kv['runner'] -eq '3.4.0') "a SHA256SUMS line that is not the binary installs nothing, and the runner stays: exit $rc; proxy versions: $($kv['pversions']); runner: $($kv['runner'])"
    $rc = Invoke-ProxyDistributor '0.0.2' @("MACHINE_RUNNER_SWARM_PROXY_SHA256=$zeros")
    $kv = Read-ProxyVolume
    Write-SwarmCheck 'proxy-strict' ($rc -eq 1 -and $script:log -match 'does not allow' -and $kv['pversions'] -notmatch '0\.0\.2') "a hash that the list does not allow: exit $rc; proxy versions: $($kv['pversions'])"
    $rc = Invoke-ProxyDistributor '0.0.2' @("MACHINE_RUNNER_SWARM_PROXY_SHA256=$zeros,$($publishedProxy['0.0.2'].ToUpperInvariant())")
    $kv = Read-ProxyVolume
    Write-SwarmCheck 'proxy-strict-list' ($rc -eq 0 -and $kv['pcurrent'] -eq 'SymbolicLink versions\0.0.2') "a list with the right hash (in capitals) installs: exit $rc; proxy current: $($kv['pcurrent'])"
    $rc = Invoke-ProxyDistributor '0.0.3'
    $kv = Read-ProxyVolume
    Write-SwarmCheck 'proxy-prune' ($rc -eq 0 -and $kv['pversions'] -eq '0.0.2,0.0.3' -and $kv['pcurrent'] -eq 'SymbolicLink versions\0.0.3') "only the last 2 active versions stay: $($kv['pversions']); proxy current: $($kv['pcurrent'])"
    $null = Invoke-Docker (@('run', '--rm') + $iso + @('--mount', "type=volume,source=$volume,target=C:\v", '--entrypoint', 'powershell.exe', $Image, '-NoLogo', '-NoProfile', '-NonInteractive') +
        (Get-SwarmEncodedCommandArgument -Script "Add-Content -LiteralPath C:\v\proxy\versions\0.0.3\bin\machine-runner-swarm-proxy.exe -Value 'tampered' -Encoding ASCII"))
    $rc = Invoke-ProxyDistributor '0.0.3'
    $kv = Read-ProxyVolume
    Write-SwarmCheck 'proxy-tamper' ($rc -eq 0 -and $kv['pexe'] -eq $publishedProxy['0.0.3'] -and $kv['precord'] -match "^$($publishedProxy['0.0.3'])  bin/") "a changed binary is replaced by the verified one: exit $rc; binary $($kv['pexe'])"
    # "unreleased" (a checkout) is the latest published release: its tag comes from the latest-release URL
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.4.0', 'MACHINE_RUNNER_SWARM_PROXY_VERSION=unreleased', 'MACHINE_RUNNER_SWARM_PROXY_BASE_URL=file:///C:/mirror/proxy',
        'MACHINE_RUNNER_SWARM_PROXY_LATEST_URL=file:///C:/mirror/proxy/v0.0.3/latest.json')
    $kv = Read-ProxyVolume
    Write-SwarmCheck 'proxy-unreleased' ($rc -eq 0 -and $script:log -match 'token proxy 0\.0\.3 is installed already' -and $kv['pcurrent'] -eq 'SymbolicLink versions\0.0.3') "unreleased is the latest published release, 0.0.3: exit $rc; proxy current: $($kv['pcurrent'])"
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.4.0', 'MACHINE_RUNNER_SWARM_PROXY_VERSION=unreleased', 'MACHINE_RUNNER_SWARM_PROXY_BASE_URL=file:///C:/mirror/proxy',
        'MACHINE_RUNNER_SWARM_PROXY_LATEST_URL=file:///C:/nowhere/latest.json')
    $kv = Read-ProxyVolume
    Write-SwarmCheck 'proxy-unreleased-none' ($rc -eq 1 -and $script:log -match 'unreleased \(a checkout of this repository\), which means its latest published release' -and $script:log -match 'published no release yet' -and $kv['pcurrent'] -eq 'SymbolicLink versions\0.0.3' -and $kv['runner'] -eq '3.4.0') "no release published: the message says so, nothing is installed and the runner stays: exit $rc; proxy current: $($kv['pcurrent']); runner: $($kv['runner'])"
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.4.0', 'MACHINE_RUNNER_SWARM_PROXY_VERSION=unreleased', 'MACHINE_RUNNER_SWARM_PROXY_BASE_URL=file:///C:/mirror/proxy',
        'MACHINE_RUNNER_SWARM_PROXY_LATEST_URL=file:///C:/mirror/manifest.json')
    Write-SwarmCheck 'proxy-unreleased-bad-answer' ($rc -eq 1 -and $script:log -match 'names no release tag') "an answer without a release tag installs nothing: exit $rc"
    # the proxy of the arm64 build is its own asset, and a release that has it installs the same way
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.4.0', 'MACHINE_RUNNER_SWARM_PROXY_VERSION=0.0.1', 'MACHINE_RUNNER_SWARM_PROXY_BASE_URL=file:///C:/mirror/proxy') -ScriptArgument @('-Architecture', 'arm64')
    $kv = Read-ProxyVolume
    Write-SwarmCheck 'proxy-arm64' ($rc -eq 0 -and $script:log -match 'token proxy 0\.0\.1 windows/arm64' -and $kv['pversions'] -match '0\.0\.1') "the arm64 asset installs: exit $rc; proxy versions: $($kv['pversions'])"
    $rc = Invoke-ProxyDistributor 'latest'
    Write-SwarmCheck 'proxy-bad-setting' ($rc -eq 1 -and $script:log -match 'MACHINE_RUNNER_SWARM_PROXY_VERSION must be a release') "exit $rc"

    # --- bad-setting -----------------------------------------------------------------------------------------------------------
    $rc = Invoke-Distributor @('MACHINE_RUNNER_SWARM_RUNNER_VERSION=latest')
    Write-SwarmCheck 'bad-setting' ($rc -eq 1 -and $script:log -match 'must be an exact version such as 3\.1\.13, or 3\.1, 3 or current') "exit $rc"
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
