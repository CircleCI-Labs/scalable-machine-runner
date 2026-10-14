<#
.SYNOPSIS
    runner-distributor.ps1: keeps circleci-runner.exe and portable Git for Windows on this node. It is the command of the
    runner-distributor-windows service (windows\stack\runners.yaml), a global service on the stock Server Core image, and
    arrives as a Swarm config. Windows PowerShell 5.1; ASCII only.

.DESCRIPTION
    The service mounts the per-node volume runner-bin read-write at C:\runner-bin. Every runner class mounts the same volume
    read-only, twice, with a subpath: current at C:\machine-runner-swarm and git\current at C:\Program Files\Git (the path that
    the task agent hard-codes for tar.exe). Docker resolves the two links when it creates a container, so a container keeps the
    runner and the Git it started with, and a flip reaches the next container, which is the next job.

      versions\<version>\bin\circleci-runner.exe
      versions\<version>\SHA256      "<sha256>  bin/circleci-runner.exe" (sha256sum -c), computed after the extraction
      versions\<version>\TARBALL     "<sha256>  circleci-runner_windows_<arch>.tar.gz", the verified download
      versions\<version>\VERSION
      current                        a relative directory symbolic link to versions\<version>
      history                        "<UTC time> <directory>" for every flip of current
      git\<git version>\             portable Git, pinned below, its post-install done; PORTABLEGIT records the download
      git\current                    a relative directory symbolic link to git\<git version>
      proxy\versions\<version>\bin\machine-runner-swarm-proxy.exe   the token proxy of the release, with SHA256 (its record) and VERSION
      proxy\current                 a relative directory symbolic link to versions\<version>, mounted by the token-proxy-windows service;
                                    the last 2 versions that were active stay

    <arch> is amd64 or arm64, from PROCESSOR_ARCHITECTURE (AMD64 or ARM64): the architectures of CircleCI's manifest for Windows.

    The service sets (and the runner services carry none of it, so an upgrade restarts this service only):
      MACHINE_RUNNER_SWARM_RUNNER_VERSION     what to run. An exact version such as 3.1.13 is a pin and never changes by itself (the default of
                                              the stack file: the newest version that this repository's CI tests). A floating value is
                                              resolved from CircleCI's manifest and looked at again every check interval: 3.1 (the newest
                                              3.1.x), 3 (the newest 3.x.y) or current (CircleCI's current)
      MACHINE_RUNNER_SWARM_RUNNER_MAJOR       the major version that current may adopt (default 3)
      MACHINE_RUNNER_SWARM_CHECK_INTERVAL     how often to look again (default 24h; seconds, or a number with s, m, h or d). A floating version
                                              asks the manifest again; an exact pin only verifies its installed copy
      MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL  where manifest.json and <version>/circleci-runner_windows_<arch>.tar.gz live
      MACHINE_RUNNER_SWARM_RUNNER_SHA256      optional: the tarball SHA-256 values that may be installed, separated by commas,
                                              instead of the hash of the manifest
      MACHINE_RUNNER_SWARM_TOOLS_BASE_URL     optional: a directory with PortableGit-<version>-64-bit.7z.exe (arm64: -arm64.7z.exe) and 7zr.exe
                                              (default: their GitHub release downloads)
      MACHINE_RUNNER_SWARM_PROXY_VERSION      the token proxy of the release v<version> of this repository. unreleased (the default of a
                                              checkout; ci/release.sh pins the default of a release bundle) means the latest published release
                                              of this repository, looked at again every check interval. Empty: no proxy is installed
      MACHINE_RUNNER_SWARM_PROXY_BASE_URL     where v<version>/machine-runner-swarm-proxy_windows_<arch> and v<version>/SHA256SUMS live
                                              (default: the GitHub releases of this repository)
      MACHINE_RUNNER_SWARM_PROXY_LATEST_URL   what unreleased asks for the latest release: JSON with its "tag_name" (default: the GitHub
                                              API of this repository, releases/latest)
      MACHINE_RUNNER_SWARM_PROXY_SHA256       optional: the proxy binary SHA-256 values that may be installed, separated by commas
      HTTPS_PROXY                             optional: a proxy for every download

    Each check resolves the version, verifies the active binary against its record, downloads and verifies what is missing,
    and flips the link. Windows locks a file that a process runs, so nothing in use is overwritten: a version is installed next
    to the others, and a copy that fails its record and cannot be moved away is replaced by a new directory <version>_<n>. The
    last 3 versions that were active stay, so a rollback is a flip; an older one is moved away first and deleted, and one that
    a process still runs (a container, for example) is left for a later check. A failed check is retried after 5 minutes
    (or the interval, when that is shorter), and the active version stays. Without any active version the script exits 1, and
    the restart policy tries again.

.PARAMETER Root
    The volume. The service uses the default; tests point it elsewhere.

.PARAMETER Once
    One check, then exit: 0 when it passed, 1 when it failed. Tests use it.

.PARAMETER NoGit
    Leave portable Git alone (a check of the runner only). Tests use it; the service never does.

.PARAMETER Architecture
    amd64 or arm64: the architecture to install for. The service never sets it: it comes from PROCESSOR_ARCHITECTURE. Tests use it,
    to check the arm64 file names on an amd64 host.
#>
[CmdletBinding()]
param(
    [string] $Root = 'C:\runner-bin',
    [switch] $Once,
    [switch] $NoGit,
    [ValidateSet('', 'amd64', 'arm64')] [string] $Architecture = ''
)

# Pinned here, so a change is a new Swarm config and restarts this service only. 7zr.exe unpacks the self-extracting archive
# without a GUI. PortableGit has bash, sh, tar, gzip and ssh; MinGit has no tar, gzip or bash.exe.
$script:GitByArch = @{
    amd64 = @{ Asset = 'PortableGit-2.56.0.2-64-bit.7z.exe'; Sha256 = '075e158ef8e1f0ab80b347e245405d3eca735c2dc88fd8e032e137d0ca61f61b' }
    arm64 = @{ Asset = 'PortableGit-2.56.0.2-arm64.7z.exe'; Sha256 = '0f21e681bd33e006e0348dfa1a2be6769efd77e3bfdb247320314facde23a46c' }
}
$script:Git = @{
    Version         = '2.56.0.2'
    ReleaseTag      = 'v2.56.0.windows.2'
    SevenZipVersion = '26.04'
    SevenZipSha256  = '256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282'
}
$script:ProxyExe = 'machine-runner-swarm-proxy.exe'
$script:ProxyKeep = 2   # proxy versions to keep: the last ones that were active
$script:Keep = 3        # runner versions to keep: the last ones that were active
$script:RetrySeconds = 300

function Write-DistributorLog([string] $Message) { [Console]::Out.WriteLine("runner-distributor: $Message") }

function Get-RunnerArchitecture {
    # The architecture of CircleCI's manifest for this host: amd64 or arm64 (a 32-bit PowerShell on 64-bit Windows reports the host in
    # PROCESSOR_ARCHITEW6432).
    $arch = "$env:PROCESSOR_ARCHITEW6432"
    if (-not $arch) { $arch = "$env:PROCESSOR_ARCHITECTURE" }
    switch ($arch) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { throw "unsupported architecture '$arch': AMD64 and ARM64 only" }
    }
}

function Initialize-Architecture {
    # The file names that depend on the architecture: the runner tarball, the proxy binary of the release, portable Git.
    param([ValidateSet('amd64', 'arm64')] [string] $Arch)
    $script:Arch = $Arch
    $script:Tarball = "circleci-runner_windows_$Arch.tar.gz"
    $script:ProxyAsset = "machine-runner-swarm-proxy_windows_$Arch"
    $script:GitAsset = $script:GitByArch[$Arch].Asset
    $script:GitSha256 = $script:GitByArch[$Arch].Sha256
}
Initialize-Architecture 'amd64'

function ConvertTo-Second {
    # "86400", "90s", "30m", "24h", "1d" -> seconds
    param([string] $Value)
    if ($Value -notmatch '^([0-9]+)([smhd]?)$') {
        throw "MACHINE_RUNNER_SWARM_CHECK_INTERVAL must be a number of seconds or a number with s, m, h or d, got '$Value'"
    }
    $n = [long]$Matches[1]
    switch ($Matches[2]) { 'm' { $n *= 60 } 'h' { $n *= 3600 } 'd' { $n *= 86400 } }
    if ($n -lt 1) { throw 'MACHINE_RUNNER_SWARM_CHECK_INTERVAL must be at least 1 second' }
    return $n
}

function Get-DistributorSetting {
    # The environment of the service, checked. Throws on a value that cannot work, so the service fails visibly.
    # exact (a pin), minor (3.1: the newest 3.1.x), major (3: the newest 3.x.y) or current
    $want = "$env:MACHINE_RUNNER_SWARM_RUNNER_VERSION"
    if (-not $want) { throw 'MACHINE_RUNNER_SWARM_RUNNER_VERSION is empty: set an exact version such as 3.1.13, or a floating one (3.1, 3, current)' }
    if ($want -eq 'current') { $kind = 'current' }
    elseif ($want -match '^[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z._-]*$') { $kind = 'exact' }
    elseif ($want -match '^[0-9]+\.[0-9]+$') { $kind = 'minor' }
    elseif ($want -match '^[0-9]+$') { $kind = 'major' }
    else { throw "MACHINE_RUNNER_SWARM_RUNNER_VERSION must be an exact version such as 3.1.13, or 3.1, 3 or current, got '$want'" }
    $major = "$env:MACHINE_RUNNER_SWARM_RUNNER_MAJOR"
    if (-not $major) { $major = '3' }
    if ($major -notmatch '^[0-9]+$') { throw "MACHINE_RUNNER_SWARM_RUNNER_MAJOR must be a number, got '$major'" }
    $interval = "$env:MACHINE_RUNNER_SWARM_CHECK_INTERVAL"
    if (-not $interval) { $interval = '24h' }
    $seconds = ConvertTo-Second $interval
    $base = "$env:MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL"
    if (-not $base) { $base = 'https://circleci-binary-releases.s3.amazonaws.com/circleci-runner' }
    $hashes = @("$env:MACHINE_RUNNER_SWARM_RUNNER_SHA256" -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    foreach ($h in $hashes) {
        if ($h -notmatch '^[0-9a-f]{64}$') { throw "MACHINE_RUNNER_SWARM_RUNNER_SHA256 holds a value that is not a SHA-256: $h" }
    }
    $tools = "$env:MACHINE_RUNNER_SWARM_TOOLS_BASE_URL"
    $proxyVersion = "$env:MACHINE_RUNNER_SWARM_PROXY_VERSION"
    if ($proxyVersion -and $proxyVersion -ne 'unreleased' -and $proxyVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z._-]*$') {
        throw "MACHINE_RUNNER_SWARM_PROXY_VERSION must be a release such as 0.3.0, got '$proxyVersion'"
    }
    $proxyBase = "$env:MACHINE_RUNNER_SWARM_PROXY_BASE_URL"
    if (-not $proxyBase) { $proxyBase = 'https://github.com/CircleCI-Labs/scalable-machine-runner/releases/download' }
    $proxyLatest = "$env:MACHINE_RUNNER_SWARM_PROXY_LATEST_URL"
    if (-not $proxyLatest) { $proxyLatest = 'https://api.github.com/repos/CircleCI-Labs/scalable-machine-runner/releases/latest' }
    $proxyHashes = @("$env:MACHINE_RUNNER_SWARM_PROXY_SHA256" -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    foreach ($h in $proxyHashes) {
        if ($h -notmatch '^[0-9a-f]{64}$') { throw "MACHINE_RUNNER_SWARM_PROXY_SHA256 holds a value that is not a SHA-256: $h" }
    }
    return @{
        Want     = $want
        Kind     = $kind
        Major    = $major
        Interval = $seconds
        Retry    = [Math]::Min($script:RetrySeconds, $seconds)
        Base     = $base.TrimEnd('/')
        Hashes   = $hashes
        Tools    = $tools.TrimEnd('/')
        ProxyVersion = $proxyVersion
        ProxyBase    = $proxyBase.TrimEnd('/')
        ProxyLatest  = $proxyLatest
        ProxyHashes  = $proxyHashes
    }
}

function Invoke-Native {
    # Windows PowerShell 5.1 turns a native command's stderr into error records: run with Continue, return the exit code.
    param([string] $FilePath, [string[]] $ArgumentList)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    return @{ ExitCode = $code; Output = $out }
}

function Save-Url {
    # Downloads Uri to OutFile, three tries. Returns $true on success.
    param([string] $Uri, [string] $OutFile)
    $request = @{ Uri = $Uri; OutFile = $OutFile; UseBasicParsing = $true; TimeoutSec = 600 }
    if ($env:HTTPS_PROXY) { $request.Proxy = $env:HTTPS_PROXY }
    $err = ''
    for ($try = 1; $try -le 3; $try++) {
        try { Invoke-WebRequest @request; return $true } catch { $err = $_.Exception.Message }
        if ($try -lt 3) { Start-Sleep -Seconds $try }
    }
    Write-DistributorLog "cannot download ${Uri}: $err"
    return $false
}

function Get-Sha256([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Write-Ascii([string] $Path, [string[]] $Line) {
    # LF line endings, no byte order mark: the SHA256 record reads like the output of sha256sum.
    [IO.File]::WriteAllText($Path, (($Line -join "`n") + "`n"), (New-Object Text.ASCIIEncoding))
}

function Test-Entry([string] $Path) {
    # True for a file, a directory or a link, also a link whose target is missing (Test-Path follows links).
    try { $null = [IO.File]::GetAttributes($Path); return $true } catch { return $false }
}

function Get-LinkTarget([string] $Path) {
    # The stored target of a symbolic link (relative, as written), or $null.
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne 'SymbolicLink') { return $null }
    return [string]@($item.Target)[0]
}

function Invoke-TreeRemoval([string] $Path) {
    # rmdir /s removes a link without following it (Remove-Item -Recurse in Windows PowerShell 5.1 follows directory links).
    if (-not (Test-Entry $Path)) { return }
    $null = Invoke-Native $env:ComSpec @('/c', 'rmdir', '/s', '/q', $Path)
}

function Test-InUse {
    # True when a process runs a program or library of the directory: Windows maps a running image and refuses write access to it,
    # and a container that mounted the directory runs its programs from it. A file that cannot be opened for writing is in use.
    # Renaming the directory is no test: it works while a container runs from it, and the container then loses its files.
    param([string] $Dir)
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Include '*.exe', '*.dll' -ErrorAction SilentlyContinue)) {
        try { $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None); $stream.Dispose() } catch { return $true }
    }
    return $false
}

function Move-Away([string] $Path) {
    # Removes a version directory that no process uses: it is moved out of the way and then deleted. $false: in use.
    if (Test-InUse $Path) { return $false }
    $trash = Join-Path $script:Root ('.trash-{0}-{1}' -f (Split-Path -Leaf $Path), [DateTime]::UtcNow.Ticks)
    try { [IO.Directory]::Move($Path, $trash) } catch { return $false }
    Invoke-TreeRemoval $trash
    return $true
}

function Switch-Link {
    # Points the relative directory symbolic link Link at Target (relative to the directory of Link). Docker resolves it when it
    # mounts the subpath; it refuses a junction. A link cannot be replaced in one step: a container created in the moment between
    # the two steps does not start, and Swarm starts the next one after the restart delay. Returns $true when it changed.
    param([string] $Link, [string] $Target)
    if ((Get-LinkTarget $Link) -eq $Target) { return $false }
    $new = "$Link.new"
    Invoke-TreeRemoval $new
    $r = Invoke-Native $env:ComSpec @('/c', 'mklink', '/D', $new, $Target)
    if ($r.ExitCode -ne 0) { throw "mklink /D $new $Target failed: $($r.Output -join ' ')" }
    if (Test-Entry $Link) {
        $r = Invoke-Native $env:ComSpec @('/c', 'rmdir', $Link)   # the link only, never its target
        if ($r.ExitCode -ne 0) { throw "cannot remove the link ${Link}: $($r.Output -join ' ')" }
    }
    [IO.Directory]::Move($new, $Link)
    return $true
}

function Move-IntoPlace {
    # Moves the finished directory Source to Parent\Name. When Parent\Name exists (a copy that failed its check) and cannot be
    # moved away because it is in use, the new copy goes to Parent\Name_<n>. Returns the name that it got.
    param([string] $Source, [string] $Parent, [string] $Name)
    $final = $Name
    if ((Test-Entry (Join-Path $Parent $Name)) -and -not (Move-Away (Join-Path $Parent $Name))) {
        $n = 1
        while (Test-Entry (Join-Path $Parent "${Name}_$n")) { $n++ }
        $final = "${Name}_$n"
        Write-DistributorLog "$Parent\$Name is in use and does not match its record: installing as $final"
    }
    [IO.Directory]::Move($Source, (Join-Path $Parent $final))
    return $final
}

# --- the runner --------------------------------------------------------------------------------------------------------

function Test-RunnerDirectory {
    # A version directory is complete, its binary matches its record, and (with Accept) its tarball was one of Accept.
    param([string] $Dir, [string[]] $Accept = @())
    $exe = Join-Path $Dir 'bin\circleci-runner.exe'
    $record = Join-Path $Dir 'SHA256'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not (Test-Path -LiteralPath $record -PathType Leaf)) { return $false }
    if ([IO.File]::ReadAllText($record).Trim() -notmatch '^([0-9a-f]{64})  bin/circleci-runner\.exe$') { return $false }
    if ((Get-Sha256 $exe) -ne $Matches[1]) { return $false }
    if (@($Accept).Count -eq 0) { return $true }
    $tarball = Join-Path $Dir 'TARBALL'
    if (-not (Test-Path -LiteralPath $tarball -PathType Leaf)) { return $false }
    return (@($Accept) -contains ([IO.File]::ReadAllText($tarball).Trim() -split ' ')[0])
}

function Find-Runner {
    # The directory name under versions of a verified copy of Version: the active one first, then <version>, then <version>_<n>.
    param([string] $Version, [string[]] $Accept = @())
    $versions = Join-Path $script:Root 'versions'
    if (-not (Test-Path -LiteralPath $versions)) { return $null }
    $pattern = '^' + [regex]::Escape($Version) + '(_[0-9]+)?$'
    $active = Split-Path -Leaf "$(Get-LinkTarget (Join-Path $script:Root 'current'))"
    $names = @(Get-ChildItem -LiteralPath $versions -Directory | Where-Object { $_.Name -match $pattern } | ForEach-Object { $_.Name } | Sort-Object)
    foreach ($name in @($names | Where-Object { $_ -eq $active }) + @($names | Where-Object { $_ -ne $active })) {
        if (Test-RunnerDirectory -Dir (Join-Path $versions $name) -Accept $Accept) { return $name }
    }
    return $null
}

function Install-Runner {
    # Downloads, verifies and records Version next to the other versions. Returns the directory name, or $null.
    param([string] $Version, [string[]] $Accept, [string] $Base)
    $versions = Join-Path $script:Root 'versions'
    $tmp = Join-Path $script:Root ".tmp-runner-$PID"
    Invoke-TreeRemoval $tmp
    New-Item -ItemType Directory -Force -Path $versions, (Join-Path $tmp 'bin') | Out-Null
    $tgz = Join-Path $tmp $script:Tarball
    Write-DistributorLog "downloading circleci-runner $Version windows/$($script:Arch)"
    if (-not (Save-Url "$Base/$Version/$($script:Tarball)" $tgz)) { Invoke-TreeRemoval $tmp; return $null }
    $got = Get-Sha256 $tgz
    if (@($Accept) -notcontains $got) {
        Write-DistributorLog "SHA-256 mismatch for $($script:Tarball) ${Version}: got $got, wanted $($Accept -join ' '): refusing to install"
        Invoke-TreeRemoval $tmp
        return $null
    }
    Write-Ascii (Join-Path $tmp 'TARBALL') "$got  $($script:Tarball)"
    $exe = Join-Path $tmp 'bin\circleci-runner.exe'
    $r = Invoke-Native "$env:SystemRoot\System32\tar.exe" @('-xzf', $tgz, '-C', (Join-Path $tmp 'bin'), 'circleci-runner.exe')
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
        Write-DistributorLog "$($script:Tarball) $Version has no circleci-runner.exe: $($r.Output -join ' ')"
        Invoke-TreeRemoval $tmp
        return $null
    }
    Remove-Item -LiteralPath $tgz -Force
    $r = Invoke-Native $exe @('--version')
    if (($r.Output -join ' ') -notmatch ('(^|[^0-9.])' + [regex]::Escape($Version) + '([^0-9.]|$)')) {
        Write-DistributorLog "the downloaded binary does not report version ${Version} ($($r.Output -join ' ')): refusing to install"
        Invoke-TreeRemoval $tmp
        return $null
    }
    Write-Ascii (Join-Path $tmp 'SHA256') "$(Get-Sha256 $exe)  bin/circleci-runner.exe"
    Write-Ascii (Join-Path $tmp 'VERSION') $Version
    $name = Move-IntoPlace -Source $tmp -Parent $versions -Name $Version
    Write-DistributorLog "installed circleci-runner $Version in versions\${name}: binary SHA-256 $(([IO.File]::ReadAllText((Join-Path $versions "$name\SHA256")) -split ' ')[0])"
    return $name
}

function Get-ManifestSha256 {
    # The SHA-256 that the manifest lists for the windows tarball of this architecture of Release (a version, current or edge), or ''.
    param($Manifest, [string] $Release)
    $entry = $Manifest.releases.$Release
    $build = $null
    if ($entry -and $entry.windows) { $build = $entry.windows.($script:Arch) }
    if ($build -and $build.sha256) { return ([string]$build.sha256).ToLowerInvariant() }
    return ''
}

function Resolve-Runner {
    # @{ Version; Accept } to install, @{ Version = '' } when current is a major version that is not followed, or $null.
    param($Setting)
    $accept = @($Setting.Hashes)
    if ($Setting.Kind -eq 'exact') {
        if ($accept.Count -gt 0) { return @{ Version = $Setting.Want; Accept = $accept } }
        # A pin that is installed and verified needs no manifest, so a rollback works offline.
        if (Find-Runner -Version $Setting.Want) { return @{ Version = $Setting.Want; Accept = @() } }
    }
    $file = Join-Path $env:TEMP "runner-distributor-manifest-$PID.json"
    if (-not (Save-Url "$($Setting.Base)/manifest.json" $file)) { return $null }
    try { $manifest = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { Write-DistributorLog "manifest.json is not JSON: $($_.Exception.Message)"; return $null }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    $arch = $script:Arch
    switch ($Setting.Kind) {
        'exact' {
            $sha = Get-ManifestSha256 $manifest $Setting.Want
            if (-not $sha) { Write-DistributorLog "the manifest has no windows/$arch build for $($Setting.Want)"; return $null }
            return @{ Version = $Setting.Want; Accept = @($sha) }
        }
        { $_ -in 'minor', 'major' } {
            # the newest release of a line: 3.1 is the newest 3.1.x, 3 the newest 3.x.y
            $line = '^' + [regex]::Escape($Setting.Want) + $(if ($Setting.Kind -eq 'minor') { '\.[0-9]+$' } else { '\.[0-9]+\.[0-9]+$' })
            $newest = @($manifest.releases.PSObject.Properties | Where-Object { $_.Name -match $line -and (Get-ManifestSha256 $manifest $_.Name) } |
                    ForEach-Object { $_.Name } | Sort-Object { [version]$_ } | Select-Object -Last 1)
            if ($newest.Count -eq 0) { Write-DistributorLog "the manifest has no windows/$arch release in $($Setting.Want).x"; return $null }
            if ($accept.Count -eq 0) { $accept = @(Get-ManifestSha256 $manifest $newest[0]) }
            return @{ Version = $newest[0]; Accept = $accept }
        }
    }
    $cur = Get-ManifestSha256 $manifest 'current'
    if (-not $cur) { Write-DistributorLog "the manifest has no windows/$arch build for current"; return $null }
    $version = @($manifest.releases.PSObject.Properties | Where-Object { $_.Name -match '^[0-9]+\.[0-9]+\.[0-9]+$' -and (Get-ManifestSha256 $manifest $_.Name) -eq $cur } |
            ForEach-Object { $_.Name } | Sort-Object { [version]$_ } | Select-Object -Last 1)
    if ($version.Count -eq 0) { Write-DistributorLog "current has SHA-256 $cur, which no versioned release of the manifest has: not adopting it"; return $null }
    $version = $version[0]
    if ($version.Split('.')[0] -ne $Setting.Major) {
        Write-DistributorLog "current is $version (major $($version.Split('.')[0])), not $($Setting.Major): not adopting it (MACHINE_RUNNER_SWARM_RUNNER_MAJOR)"
        return @{ Version = ''; Accept = @() }
    }
    if ($accept.Count -eq 0) { $accept = @($cur) }
    return @{ Version = $version; Accept = $accept }
}

function Get-RecentRunner {
    # The last Count directories that current pointed to, most recent first (from history).
    param([int] $Count)
    $history = Join-Path $script:Root 'history'
    if (-not (Test-Path -LiteralPath $history)) { return @() }
    $lines = @(Get-Content -LiteralPath $history)
    $seen = @()
    for ($i = $lines.Count - 1; $i -ge 0 -and $seen.Count -lt $Count; $i--) {
        $name = ($lines[$i] -split ' ')[-1]
        if ($name -and $seen -notcontains $name) { $seen += $name }
    }
    return $seen
}

function Switch-Runner {
    # current -> versions\Name, and remember that it was active.
    param([string] $Name)
    if (-not (Switch-Link -Link (Join-Path $script:Root 'current') -Target "versions\$Name")) { return }
    $history = Join-Path $script:Root 'history'
    $lines = @()
    if (Test-Path -LiteralPath $history) { $lines = @(Get-Content -LiteralPath $history) }
    $lines += "$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) $Name"
    Write-Ascii $history @($lines | Select-Object -Last 200)
    Write-DistributorLog "[ ok ] current -> versions\${Name}: circleci-runner $([IO.File]::ReadAllText((Join-Path $script:Root "versions\$Name\VERSION")).Trim()) windows/$($script:Arch)"
}

function Invoke-RunnerPruning {
    # Keeps the last Keep versions that were active, and never the active one.
    $active = Split-Path -Leaf "$(Get-LinkTarget (Join-Path $script:Root 'current'))"
    $keep = @(Get-RecentRunner -Count $script:Keep)
    foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'versions') -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -eq $active -or $keep -contains $dir.Name) { continue }
        if (Move-Away $dir.FullName) {
            Write-DistributorLog "removed circleci-runner $($dir.Name) (only the last $($script:Keep) active versions are kept)"
        } else {
            Write-DistributorLog "circleci-runner $($dir.Name) is in use: removing it at a later check"
        }
    }
}

# --- portable Git ------------------------------------------------------------------------------------------------------

function Test-GitDirectory {
    # A Git directory is complete: the record of the pinned download and the tools that the runner and the task agent use.
    param([string] $Dir)
    $record = Join-Path $Dir 'PORTABLEGIT'
    if (-not (Test-Path -LiteralPath $record -PathType Leaf)) { return $false }
    if (([IO.File]::ReadAllText($record).Trim() -split ' ')[0] -ne $script:GitSha256) { return $false }
    foreach ($f in 'usr\bin\bash.exe', 'usr\bin\sh.exe', 'usr\bin\tar.exe', 'usr\bin\gzip.exe', 'usr\bin\ssh.exe', 'cmd\git.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $f) -PathType Leaf)) { return $false }
    }
    return $true
}

function Install-Git {
    # Downloads and verifies the pinned 7zr.exe and PortableGit, unpacks it, runs its post-install once, and returns the
    # directory name under git, or $null.
    param([string] $Tools)
    $gitRoot = Join-Path $script:Root 'git'
    $tmp = Join-Path $script:Root ".tmp-git-$PID"
    Invoke-TreeRemoval $tmp
    New-Item -ItemType Directory -Force -Path $gitRoot, $tmp | Out-Null
    $sfxName = $script:GitAsset
    $sevenZipUrl = "https://github.com/ip7z/7zip/releases/download/$($script:Git.SevenZipVersion)/7zr.exe"
    $sfxUrl = "https://github.com/git-for-windows/git/releases/download/$($script:Git.ReleaseTag)/$sfxName"
    if ($Tools) { $sevenZipUrl = "$Tools/7zr.exe"; $sfxUrl = "$Tools/$sfxName" }
    $sevenZip = Join-Path $tmp '7zr.exe'
    $sfx = Join-Path $tmp $sfxName
    Write-DistributorLog "downloading portable Git $($script:Git.Version)"
    foreach ($d in @(@($sevenZipUrl, $sevenZip, $script:Git.SevenZipSha256), @($sfxUrl, $sfx, $script:GitSha256))) {
        if (-not (Save-Url $d[0] $d[1])) { Invoke-TreeRemoval $tmp; return $null }
        $got = Get-Sha256 $d[1]
        if ($got -ne $d[2]) { Write-DistributorLog "SHA-256 mismatch for $($d[0]): got $got, wanted $($d[2]): refusing to install"; Invoke-TreeRemoval $tmp; return $null }
    }
    $dir = Join-Path $tmp 'git'
    $r = Invoke-Native $sevenZip @('x', '-y', '-bso0', '-bsp0', "-o$dir", $sfx)
    if ($r.ExitCode -ne 0) { Write-DistributorLog "7zr.exe exited $($r.ExitCode): $($r.Output -join ' ')"; Invoke-TreeRemoval $tmp; return $null }
    # Git's post-install scripts (POSIX device directories, /etc/mtab, the hosts and services files), as post-install.bat runs
    # them through git-bash.exe, with bash directly (no GUI). Once, here: the runner classes mount the tree read-only.
    $post = Join-Path $dir 'post-install.bat'
    if (Test-Path -LiteralPath $post) {
        $loop = 'export PATH=/usr/bin:/ucrt64/bin:/mingw64/bin:/cmd:$PATH; export SYSCONFDIR=/etc; ' +
        'for p in $(export LC_COLLATE=C; echo /etc/post-install/*.post); do test -e "$p" && . "$p"; done'
        $r = Invoke-Native (Join-Path $dir 'usr\bin\bash.exe') @('--norc', '-c', $loop)
        if ($r.ExitCode -ne 0) { Write-DistributorLog "Git post-install exited $($r.ExitCode); the checks below decide" }
        Remove-Item -LiteralPath $post -Force -ErrorAction SilentlyContinue
    }
    Write-Ascii (Join-Path $dir 'PORTABLEGIT') "$($script:GitSha256)  $sfxName"
    $git = Invoke-Native (Join-Path $dir 'cmd\git.exe') @('--version')
    $bash = Invoke-Native (Join-Path $dir 'usr\bin\bash.exe') @('-c', 'echo bash-ok')
    if (-not (Test-GitDirectory $dir) -or $git.ExitCode -ne 0 -or ($bash.Output -join ' ') -notmatch 'bash-ok') {
        Write-DistributorLog "portable Git $($script:Git.Version) is incomplete after the unpacking ($($git.Output -join ' ') $($bash.Output -join ' '))"
        Invoke-TreeRemoval $tmp
        return $null
    }
    $name = Move-IntoPlace -Source $dir -Parent $gitRoot -Name $script:Git.Version
    Invoke-TreeRemoval $tmp
    Write-DistributorLog "installed portable Git $($script:Git.Version) in git\$name ($($git.Output -join ' '))"
    return $name
}

function Install-PinnedGit {
    # git\current -> the pinned Git, installed when it is missing or incomplete. Older Git directories are removed when no
    # container uses them. $false: the pinned Git is not in place.
    param([string] $Tools)
    $gitRoot = Join-Path $script:Root 'git'
    $name = $null
    $pattern = '^' + [regex]::Escape($script:Git.Version) + '(_[0-9]+)?$'
    if (Test-Path -LiteralPath $gitRoot) {
        $name = @(Get-ChildItem -LiteralPath $gitRoot -Directory | Where-Object { $_.Name -match $pattern -and (Test-GitDirectory $_.FullName) } |
                ForEach-Object { $_.Name } | Sort-Object | Select-Object -First 1)[0]
    }
    if (-not $name) { $name = Install-Git -Tools $Tools }
    if (-not $name) { return $false }
    if (Switch-Link -Link (Join-Path $gitRoot 'current') -Target $name) { Write-DistributorLog "[ ok ] git\current -> git\${name}: portable Git $($script:Git.Version)" }
    foreach ($dir in @(Get-ChildItem -LiteralPath $gitRoot -Directory | Where-Object { $_.Name -ne $name -and $_.Name -ne 'current' -and $_.Name -notlike '*.new' })) {
        if (Move-Away $dir.FullName) { Write-DistributorLog "removed portable Git $($dir.Name)" } else { Write-DistributorLog "portable Git $($dir.Name) is in use: removing it at a later check" }
    }
    return $true
}

# --- the token proxy ---------------------------------------------------------------------------------------------------

function Test-ProxyDirectory {
    # A proxy version directory is complete and its binary matches its record (and, with Accept, one of those hashes).
    param([string] $Dir, [string[]] $Accept = @())
    $exe = Join-Path $Dir "bin\$($script:ProxyExe)"
    $record = Join-Path $Dir 'SHA256'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not (Test-Path -LiteralPath $record -PathType Leaf)) { return $false }
    if ([IO.File]::ReadAllText($record).Trim() -notmatch ('^([0-9a-f]{64})  bin/' + [regex]::Escape($script:ProxyExe) + '$')) { return $false }
    $recorded = $Matches[1]
    if ((Get-Sha256 $exe) -ne $recorded) { return $false }
    return (@($Accept).Count -eq 0 -or @($Accept) -contains $recorded)
}

function Find-Proxy {
    # The directory name under proxy\versions of a verified copy of Version: the active one first, then <version>, then <version>_<n>.
    param([string] $Version, [string[]] $Accept = @())
    $versions = Join-Path $script:Root 'proxy\versions'
    if (-not (Test-Path -LiteralPath $versions)) { return $null }
    $pattern = '^' + [regex]::Escape($Version) + '(_[0-9]+)?$'
    $active = Split-Path -Leaf "$(Get-LinkTarget (Join-Path $script:Root 'proxy\current'))"
    $names = @(Get-ChildItem -LiteralPath $versions -Directory | Where-Object { $_.Name -match $pattern } | ForEach-Object { $_.Name } | Sort-Object)
    foreach ($name in @($names | Where-Object { $_ -eq $active }) + @($names | Where-Object { $_ -ne $active })) {
        if (Test-ProxyDirectory -Dir (Join-Path $versions $name) -Accept $Accept) { return $name }
    }
    return $null
}

function Install-Proxy {
    # Downloads the SHA256SUMS and the binary of the release v<Version>, checks the binary against its line (and against Accept when it is
    # not empty), records it next to the others. Returns the directory name, or $null.
    param([string] $Version, [string[]] $Accept, [string] $Base)
    $versions = Join-Path $script:Root 'proxy\versions'
    $tmp = Join-Path $script:Root ".tmp-proxy-$PID"
    Invoke-TreeRemoval $tmp
    New-Item -ItemType Directory -Force -Path $versions, (Join-Path $tmp 'bin') | Out-Null
    Write-DistributorLog "downloading the token proxy $Version windows/$($script:Arch) from $Base/v$Version"
    $sums = Join-Path $tmp 'SHA256SUMS'
    if (-not (Save-Url "$Base/v$Version/SHA256SUMS" $sums)) { Invoke-TreeRemoval $tmp; return $null }
    $want = ''
    foreach ($line in @(Get-Content -LiteralPath $sums)) {
        if ($line -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($script:ProxyAsset) + '$')) { $want = $Matches[1].ToLowerInvariant(); break }
    }
    if (-not $want) { Write-DistributorLog "SHA256SUMS of v$Version lists no $($script:ProxyAsset)"; Invoke-TreeRemoval $tmp; return $null }
    if (@($Accept).Count -gt 0 -and @($Accept) -notcontains $want) {
        Write-DistributorLog "SHA256SUMS of v$Version lists $want for $($script:ProxyAsset), which MACHINE_RUNNER_SWARM_PROXY_SHA256 does not allow: refusing to install"
        Invoke-TreeRemoval $tmp
        return $null
    }
    $exe = Join-Path $tmp "bin\$($script:ProxyExe)"
    if (-not (Save-Url "$Base/v$Version/$($script:ProxyAsset)" $exe)) { Invoke-TreeRemoval $tmp; return $null }
    $got = Get-Sha256 $exe
    if ($got -ne $want) {
        Write-DistributorLog "SHA-256 mismatch for $($script:ProxyAsset) v${Version}: got $got, SHA256SUMS says ${want}: refusing to install"
        Invoke-TreeRemoval $tmp
        return $null
    }
    $r = Invoke-Native $exe @('-version')
    if (($r.Output -join ' ') -notmatch ('(^|[^0-9.])' + [regex]::Escape($Version) + '([^0-9.]|$)')) {
        Write-DistributorLog "the downloaded proxy does not report version ${Version} ($($r.Output -join ' ')): refusing to install"
        Invoke-TreeRemoval $tmp
        return $null
    }
    Remove-Item -LiteralPath $sums -Force
    Write-Ascii (Join-Path $tmp 'SHA256') "$got  bin/$($script:ProxyExe)"
    Write-Ascii (Join-Path $tmp 'VERSION') $Version
    $name = Move-IntoPlace -Source $tmp -Parent $versions -Name $Version
    Write-DistributorLog "installed the token proxy $Version in proxy\versions\${name}: binary SHA-256 $got"
    return $name
}

function Get-LatestProxyVersion {
    # The version of the latest published release of this repository (what unreleased means), from the JSON that Url returns, or $null.
    param([string] $Url)
    $file = Join-Path $env:TEMP "runner-distributor-latest-$PID.json"
    if (-not (Save-Url $Url $file)) {
        Write-DistributorLog "error: the token proxy is not installed: MACHINE_RUNNER_SWARM_PROXY_VERSION is unreleased (a checkout of this repository), which means its latest published release, and $Url returns none. Either this repository has published no release yet, or GitHub is not reachable. Use the bundle of a release, or set MACHINE_RUNNER_SWARM_PROXY_VERSION to a release such as 0.3.0"
        return $null
    }
    try { $json = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { Write-DistributorLog "error: $Url is not JSON: the token proxy is not installed"; return $null }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    if ("$($json.tag_name)" -notmatch '^v([0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z._-]*)$') {
        Write-DistributorLog "error: $Url names no release tag of the form v0.3.0: the token proxy is not installed"
        return $null
    }
    return $Matches[1]
}

function Invoke-ProxyCheck {
    # $true when the proxy is not wanted, or is installed and active. A failure never touches the runner.
    param($Setting)
    if (-not $Setting.ProxyVersion) { return $true }
    $version = $Setting.ProxyVersion
    if ($version -eq 'unreleased') {
        $version = Get-LatestProxyVersion $Setting.ProxyLatest
        if (-not $version) { return $false }
    }
    $proxyRoot = Join-Path $script:Root 'proxy'
    $name = Find-Proxy -Version $version -Accept $Setting.ProxyHashes
    if ($name) {
        Write-DistributorLog "the token proxy $version is installed already (proxy\versions\$name)"
    } else {
        $name = Install-Proxy -Version $version -Accept $Setting.ProxyHashes -Base $Setting.ProxyBase
        if (-not $name) { return $false }
    }
    if (Switch-Link -Link (Join-Path $proxyRoot 'current') -Target "versions\$name") {
        $history = Join-Path $proxyRoot 'history'
        $lines = @()
        if (Test-Path -LiteralPath $history) { $lines = @(Get-Content -LiteralPath $history) }
        $lines += "$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) $name"
        Write-Ascii $history @($lines | Select-Object -Last 200)
        Write-DistributorLog "[ ok ] proxy\current -> versions\${name}: the token proxy $version windows/$($script:Arch)"
    }
    # keep the last ProxyKeep versions that were active, never the active one
    $active = Split-Path -Leaf "$(Get-LinkTarget (Join-Path $proxyRoot 'current'))"
    $seen = @()
    $history = Join-Path $proxyRoot 'history'
    if (Test-Path -LiteralPath $history) {
        $lines = @(Get-Content -LiteralPath $history)
        for ($i = $lines.Count - 1; $i -ge 0 -and $seen.Count -lt $script:ProxyKeep; $i--) {
            $n = ($lines[$i] -split ' ')[-1]
            if ($n -and $seen -notcontains $n) { $seen += $n }
        }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $proxyRoot 'versions') -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -eq $active -or $seen -contains $dir.Name) { continue }
        if (Move-Away $dir.FullName) { Write-DistributorLog "removed the token proxy $($dir.Name) (only the last $($script:ProxyKeep) active versions are kept)" }
        else { Write-DistributorLog "the token proxy $($dir.Name) is in use: removing it at a later check" }
    }
    return $true
}

# --- one check ---------------------------------------------------------------------------------------------------------

function Invoke-Check {
    # $true when the check passed. The active versions stay in place whatever fails.
    param($Setting)
    New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
    foreach ($left in @(Get-ChildItem -LiteralPath $script:Root -Force -Directory -Filter '.t*' -ErrorAction SilentlyContinue)) {
        if ($left.Name -like '.tmp-*' -or $left.Name -like '.trash-*') { Invoke-TreeRemoval $left.FullName }   # what a stopped run left
    }
    $gitOk = $true
    if (-not $script:SkipGit) { $gitOk = Install-PinnedGit -Tools $Setting.Tools }
    $proxyOk = Invoke-ProxyCheck $Setting
    $gitOk = $gitOk -and $proxyOk   # a failed proxy install is retried like a failed Git install, and never touches the runner
    $target = Resolve-Runner $Setting
    if (-not $target) { return $false }
    if (-not $target.Version) {
        if (-not (Test-Entry (Join-Path $script:Root 'current'))) { Write-DistributorLog "no runner is installed and current is not a major $($Setting.Major) release"; return $false }
        return $gitOk
    }
    $name = Find-Runner -Version $target.Version -Accept $target.Accept
    if ($name) {
        Write-DistributorLog "circleci-runner $($target.Version) is installed already (versions\$name)"
    } else {
        $name = Install-Runner -Version $target.Version -Accept $target.Accept -Base $Setting.Base
        if (-not $name) { return $false }
    }
    Switch-Runner $name
    Invoke-RunnerPruning
    return $gitOk
}

$script:Root = $Root
$script:SkipGit = $NoGit.IsPresent
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is many times slower with the progress bar
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        if ($Architecture) { Initialize-Architecture $Architecture } else { Initialize-Architecture (Get-RunnerArchitecture) }
        $setting = Get-DistributorSetting
    } catch { Write-DistributorLog "error: $($_.Exception.Message)"; exit 1 }
    switch ($setting.Kind) {
        'exact' { $what = 'an exact pin: it never changes by itself, and the manifest is asked only when it is not installed' }
        'current' { $what = "floating: CircleCI's current, within major $($setting.Major)" }
        default { $what = "floating: the newest $($setting.Want).x of the manifest" }
    }
    Write-DistributorLog "version $($setting.Want) ($what), windows/$($script:Arch), check every $($setting.Interval)s, from $($setting.Base)"
    if ($setting.ProxyVersion -eq 'unreleased') { Write-DistributorLog "token proxy: the latest published release of this repository (unreleased), looked at every $($setting.Interval)s: $($setting.ProxyLatest)" }
    elseif ($setting.ProxyVersion) { Write-DistributorLog "token proxy $($setting.ProxyVersion) from $($setting.ProxyBase)" }
    else { Write-DistributorLog 'no token proxy is installed: MACHINE_RUNNER_SWARM_PROXY_VERSION is empty' }
    while ($true) {
        $ok = $false
        try { $ok = Invoke-Check $setting } catch { Write-DistributorLog "error: $($_.Exception.Message)" }
        if ($Once) { if ($ok) { exit 0 } exit 1 }
        $wait = $setting.Interval
        if (-not $ok) {
            $active = Get-LinkTarget (Join-Path $script:Root 'current')
            if (-not $active) { Write-DistributorLog 'no runner is active on this node yet: exiting, the restart policy tries again'; exit 1 }
            Write-DistributorLog "keeping $active; the next check is in $($setting.Retry)s"
            $wait = $setting.Retry
        }
        Start-Sleep -Seconds $wait
    }
}
