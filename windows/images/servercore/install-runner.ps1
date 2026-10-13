<#
.SYNOPSIS
    Puts circleci-runner.exe and portable Git for Windows into place. Used by the baked-image
    Dockerfile at build time, and by windows\Setup.ps1 to stage the C:\machine-runner-swarm directory on a host.

.DESCRIPTION
    Every download is pinned and verified with SHA-256 before it is used; nothing is piped into a
    shell.

      circleci-runner.exe   circleci-binary-releases.s3.amazonaws.com tarball, extracted into -RunnerDir
      portable Git          PortableGit-<ver>-64-bit.7z.exe (a self-extracting 7-Zip archive), unpacked
                            into -GitDir with the standalone 7zr.exe, so no GUI or console is needed.
                            It provides git, bash, sh, tar, gzip and ssh. The task agent hard-codes
                            C:\Program Files\Git\usr\bin\tar.exe, and MinGit has no tar, gzip or bash.exe

    Git's post-install scripts run once (the README of the portable package requires it when it is
    unpacked by hand), so the tree is ready to be used read-only.

    With -SetMachinePath (the baked image) it also puts Git on the machine PATH and sets Git's system
    configuration (long paths, no credential helper). Windows PowerShell 5.1; ASCII only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $RunnerVersion,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $RunnerSha256,
    [Parameter(Mandatory = $true)][string] $GitVersion,
    [Parameter(Mandatory = $true)][string] $GitReleaseTag,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $GitSha256,
    [Parameter(Mandatory = $true)][string] $SevenZipVersion,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $SevenZipSha256,
    [string] $RunnerDir = 'C:\machine-runner-swarm\bin',
    [string] $GitDir = 'C:\Program Files\Git',
    [switch] $SetMachinePath,
    [string] $RunnerBaseUrl = 'https://circleci-binary-releases.s3.amazonaws.com/circleci-runner'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$tmp = Join-Path $env:TEMP 'swarm-install'

function Get-VerifiedDownload {
    param([string] $Uri, [string] $OutFile, [string] $Sha256)
    Write-Output "Downloading $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    $actual = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch for ${Uri}: expected $Sha256, got $actual"
    }
}

function Invoke-Native {
    # Windows PowerShell 5.1 turns native stderr into error records; run with Continue, check the exit code.
    param([string] $FilePath, [string[]] $ArgumentList, [int[]] $OkExitCode = @(0))
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $FilePath @ArgumentList 2>&1 | ForEach-Object { Write-Output "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($OkExitCode -notcontains $code) { throw "$FilePath exited with $code" }
}

New-Item -ItemType Directory -Force -Path $RunnerDir, $tmp | Out-Null

# --- circleci-runner (a static Go binary) -----------------------------------------
$tgz = Join-Path $tmp 'circleci-runner_windows_amd64.tar.gz'
Get-VerifiedDownload -Uri "$RunnerBaseUrl/$RunnerVersion/circleci-runner_windows_amd64.tar.gz" -OutFile $tgz -Sha256 $RunnerSha256
Invoke-Native -FilePath "$env:SystemRoot\System32\tar.exe" -ArgumentList @('-xzf', $tgz, '-C', $RunnerDir)   # bsdtar ships with Windows

# --- portable Git ------------------------------------------------------------------
$sevenZip = Join-Path $tmp '7zr.exe'
$sfx = Join-Path $tmp "PortableGit-$GitVersion-64-bit.7z.exe"
Get-VerifiedDownload -Uri "https://github.com/ip7z/7zip/releases/download/$SevenZipVersion/7zr.exe" -OutFile $sevenZip -Sha256 $SevenZipSha256
Get-VerifiedDownload -Uri "https://github.com/git-for-windows/git/releases/download/$GitReleaseTag/PortableGit-$GitVersion-64-bit.7z.exe" `
    -OutFile $sfx -Sha256 $GitSha256
if (Test-Path -LiteralPath $GitDir) { Remove-Item -LiteralPath $GitDir -Recurse -Force }
Invoke-Native -FilePath $sevenZip -ArgumentList @('x', '-y', '-bso0', '-bsp0', "-o$GitDir", $sfx)

# Git's post-install scripts (POSIX device directories, /etc/mtab, the hosts and services files).
# post-install.bat runs them through git-bash.exe; run the same loop with bash directly (no GUI).
$post = Join-Path $GitDir 'post-install.bat'
if (Test-Path -LiteralPath $post) {
    $loop = 'export PATH=/usr/bin:/ucrt64/bin:/mingw64/bin:/cmd:$PATH; export SYSCONFDIR=/etc; ' +
    'for p in $(export LC_COLLATE=C; echo /etc/post-install/*.post); do test -e "$p" && . "$p"; done'
    try {
        Invoke-Native -FilePath (Join-Path $GitDir 'usr\bin\bash.exe') -ArgumentList @('--norc', '-c', $loop)
    } catch {
        Write-Output "warning: Git post-install did not finish cleanly ($($_.Exception.Message)); the checks below decide"
    }
    Remove-Item -LiteralPath $post -Force -ErrorAction SilentlyContinue
}

if ($SetMachinePath) {
    $parts = @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ -ne '' })
    foreach ($sub in @('cmd', 'ucrt64\bin', 'usr\bin')) {
        $entry = Join-Path $GitDir $sub
        if ($parts -notcontains $entry) { $parts += $entry }
    }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'Machine')
    $git = Join-Path $GitDir 'cmd\git.exe'
    Invoke-Native -FilePath $git -ArgumentList @('config', '--system', 'core.longpaths', 'true')
    Invoke-Native -FilePath $git -ArgumentList @('config', '--system', '--unset-all', 'credential.helper') -OkExitCode @(0, 5)
}

# --- verify what the runner and the task agent need ------------------------------------
foreach ($f in @('usr\bin\bash.exe', 'usr\bin\sh.exe', 'usr\bin\tar.exe', 'usr\bin\gzip.exe', 'usr\bin\ssh.exe', 'cmd\git.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $GitDir $f))) { throw "Missing required file: $(Join-Path $GitDir $f)" }
}
Invoke-Native -FilePath (Join-Path $RunnerDir 'circleci-runner.exe') -ArgumentList @('--version')
Invoke-Native -FilePath (Join-Path $GitDir 'cmd\git.exe') -ArgumentList @('--version')
Invoke-Native -FilePath (Join-Path $GitDir 'usr\bin\bash.exe') -ArgumentList @('-c', 'echo bash-ok')
# The task agent switches to a PsExec/RDP desktop wrapper when PsExec64.exe is on ITS PATH, and that wrapper needs an
# interactive desktop, which containers do not have. Only an image build can put it there: a host that stages C:\machine-runner-swarm
# often has Sysinternals on its own PATH (CircleCI's Windows images do), which does not reach the containers.
if ($SetMachinePath -and (Get-Command 'PsExec64.exe' -ErrorAction SilentlyContinue)) { throw 'PsExec64.exe must not be on PATH in the image' }

Remove-Item -Recurse -Force $tmp
Write-Output 'install-runner.ps1: done'
