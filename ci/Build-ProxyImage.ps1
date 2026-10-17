<#
.SYNOPSIS
    ci\Build-ProxyImage.ps1: builds the Windows image of the token proxy (proxy\Dockerfile.windows), tests it, and, on request, pushes it.
    Windows PowerShell 5.1 on a Windows host (a CircleCI Windows machine executor); ASCII only.

.DESCRIPTION
    The image is the static windows/amd64 build of the proxy (ci/build-proxy.sh, which the proxy-test job makes and passes on in its
    workspace) on a Nano Server base for the host's Windows tag, ltsc2022 or ltsc2025. The base images are pinned by digest here, and
    Renovate keeps them (docs/ci.md, "Pinned versions"). The build runs on a host whose build matches the base (process isolation).

      -Binary    the machine-runner-swarm-proxy_windows_amd64 file (default: proxy-bin\ of the workspace of proxy-test)
      -Tag       ltsc2022 or ltsc2025 (default: the tag of this host's build)
      -Name      the image name to build, e.g. machine-runner-swarm-proxy:dev or ccilabs/machine-runner-swarm-proxy:sha-0123456789ab-windows-ltsc2022
      -Version   what the proxy reports (default dev; CI passes sha-<12 characters of the commit>). The binary must have been built with it
      -Revision  the commit, for the label org.opencontainers.image.revision
      -Test      the image reports its version, runs as it should, and starts with a token file and a state directory: it becomes healthy
                 (its own -healthcheck, and the HEALTHCHECK of Docker) and writes its state. A failure exits 1
      -Push      docker login with DOCKERHUB_USERNAME and DOCKERHUB_TOKEN (from the environment, never printed), then docker push of -Name.
                 Without both variables nothing is pushed, and the script says so and exits 0 (a pipeline without the credentials stays green),
                 unless REQUIRE_CREDENTIALS is true or 1 (a production main: the setup gate sets it): then it exits 1

.EXAMPLE
    .\ci\Build-ProxyImage.ps1 -Binary C:\work\machine-runner-swarm-proxy_windows_amd64 -Test
#>
[CmdletBinding()]
param(
    [string] $Tag = '',
    [string] $Binary = '',
    [string] $Name = 'machine-runner-swarm-proxy:dev',
    [string] $Version = 'dev',
    [string] $Revision = '',
    [switch] $Test,
    [switch] $Push
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'windows\tests\SwarmTestHelpers.psm1') -Force

# The Nano Server images of the two Windows tags that the proxy image covers, by digest (each tag is an index of one build).
$bases = @{
    ltsc2022 = 'mcr.microsoft.com/windows/nanoserver:ltsc2022@sha256:32729e1cdc6718c90952375e9bbae2b2c5d38f41ceb50a693fc2383b76df28fd'
    ltsc2025 = 'mcr.microsoft.com/windows/nanoserver:ltsc2025@sha256:4d81c65bfec7e1b00e004ba8d7306347a880935179bc20cae1044b5a7d35f789'
}

function Write-Step([string] $Message) { Write-Host ("[proxy-image {0}] {1}" -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss'), $Message) }
function Exit-WithFailure([string] $Message) { Write-Host "FAIL: $Message"; exit 1 }
function Invoke-Docker([string[]] $DockerArgument) {
    # docker with Continue (Windows PowerShell 5.1 turns redirected stderr into an error record), plain strings back, the exit code kept
    # in $script:dockerExit. The arguments are an array, because the proxy takes single-dash options that PowerShell would read as its own.
    $r = Invoke-SwarmDocker -ArgumentList $DockerArgument
    $script:dockerExit = $r.ExitCode
    return $r.Output
}

if (-not $Tag) { $Tag = Get-SwarmWindowsTag }
if (-not $bases.ContainsKey($Tag)) { Exit-WithFailure "the tag must be ltsc2022 or ltsc2025, got '$Tag'" }
if (-not $Binary) { $Binary = Join-Path $repo 'proxy-bin\machine-runner-swarm-proxy_windows_amd64' }
if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) { Exit-WithFailure "the proxy binary $Binary is missing (ci/build-proxy.sh makes it; the job attaches the workspace of proxy-test)" }

# --- build -------------------------------------------------------------------------------------------------------------------
$context = Join-Path ([IO.Path]::GetTempPath()) "proxy-image-$PID"
New-Item -ItemType Directory -Force -Path $context | Out-Null
try {
    Copy-Item -LiteralPath $Binary -Destination (Join-Path $context 'machine-runner-swarm-proxy.exe')
    Write-Step "docker build $Name ($Tag, base $($bases[$Tag]))"
    $out = Invoke-Docker @('build', '--tag', $Name, '--file', (Join-Path $repo 'proxy\Dockerfile.windows'), '--build-arg', "BASE=$($bases[$Tag])",
        '--build-arg', "VERSION=$Version", '--build-arg', "REVISION=$Revision", $context)
    $out | ForEach-Object { Write-Host $_ }
    if ($script:dockerExit -ne 0) { Exit-WithFailure "docker build exited $script:dockerExit" }
} finally {
    Remove-Item -LiteralPath $context -Recurse -Force -ErrorAction SilentlyContinue
}
$info = Invoke-Docker @('image', 'inspect', $Name, '--format', '{{.Os}}/{{.Architecture}} {{.OsVersion}} user={{.Config.User}} {{.Size}} bytes')
Write-Step "built ${Name}: $($info -join ' ')"

# --- test --------------------------------------------------------------------------------------------------------------------
if ($Test) {
    function Test-Check([string] $CheckName, [bool] $Ok, [string] $Detail) { Write-SwarmCheck -Name $CheckName -Ok $Ok -Detail $Detail }
    $reported = (Invoke-Docker @('run', '--rm', '--isolation=process', $Name, '-version')) -join ' '
    Test-Check 'proxy-image-version' ($script:dockerExit -eq 0 -and $reported -eq "machine-runner-swarm-proxy $Version") "reports '$reported', want 'machine-runner-swarm-proxy $Version'"
    $osv = (Invoke-Docker @('image', 'inspect', $Name, '--format', '{{.Os}} {{.OsVersion}}')) -join ' '
    Test-Check 'proxy-image-os' ($osv -like 'windows 10.0.*') "image: $osv"

    # A token file and a state directory from the host, as a stack gives them: it must become healthy and write its state. The proxy finds its classes
    # as the <service>-token files of -secrets-dir: smoke-token is the class smoke.
    $work = Join-Path ([IO.Path]::GetTempPath()) "proxy-smoke-$PID"
    $secrets = Join-Path $work 'secrets'
    $state = Join-Path $work 'state'
    New-Item -ItemType Directory -Force -Path $secrets, $state | Out-Null
    [IO.File]::WriteAllText((Join-Path $secrets 'smoke-token'), "api:`n  auth_token: smoke-not-a-real-token`n", (New-Object Text.ASCIIEncoding))
    foreach ($d in $secrets, $state) { & icacls.exe $d /grant '*S-1-5-11:(OI)(CI)M' /T /Q | Out-Null }
    $cname = "proxy-smoke-$PID"
    try {
        $null = Invoke-Docker @('rm', '--force', $cname)
        $null = Invoke-Docker @('run', '--detach', '--name', $cname, '--isolation=process', '--volume', "${secrets}:C:\secrets", '--volume', "${state}:C:\state",
            $Name, '-secrets-dir', 'C:\secrets', '-state-dir', 'C:\state', '-upstream', 'http://127.0.0.1:9')
        Test-Check 'proxy-image-starts' ($script:dockerExit -eq 0) 'docker run'
        $healthy = $false
        for ($i = 0; $i -lt 60 -and -not $healthy; $i++) {
            $null = Invoke-Docker @('exec', $cname, 'C:\machine-runner-swarm-proxy.exe', '-healthcheck')
            if ($script:dockerExit -eq 0) { $healthy = $true } else { Start-Sleep -Seconds 2 }
        }
        Test-Check 'proxy-image-healthcheck-flag' $healthy 'machine-runner-swarm-proxy.exe -healthcheck exits 0 inside the container'
        $stateFile = Join-Path $state 'state.json'
        Test-Check 'proxy-image-writes-its-state' (Test-Path -LiteralPath $stateFile) "a state directory from a volume is writable: $stateFile"
        $status = ''
        for ($i = 0; $i -lt 45; $i++) {
            $status = (Invoke-Docker @('inspect', '--format', '{{.State.Health.Status}}', $cname)) -join ''
            if ($status -eq 'healthy') { break }
            Start-Sleep -Seconds 4
        }
        Test-Check 'proxy-image-docker-healthy' ($status -eq 'healthy') "the HEALTHCHECK of the image: $status"
        $logs = Invoke-Docker @('logs', $cname)
        $logs | Select-Object -Last 8 | ForEach-Object { Write-Host "    proxy: $_" }
        Test-Check 'proxy-image-no-token-in-the-log' (-not (($logs -join "`n") -match 'smoke-not-a-real-token')) 'the log names no token'
    } finally {
        $null = Invoke-Docker @('rm', '--force', $cname)
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    $count = Get-SwarmCheckCount
    Write-Host "RESULT proxy-image tag=$Tag checks=$($count.Checks) failed=$($count.Failed)"
    if ($count.Failed -gt 0) { Exit-WithFailure "$($count.Failed) check(s) of the image failed" }
}

# --- push --------------------------------------------------------------------------------------------------------------------
if ($Push) {
    if (-not $env:DOCKERHUB_USERNAME -or -not $env:DOCKERHUB_TOKEN) {
        if ($env:REQUIRE_CREDENTIALS -in @('1', 'true')) {
            Exit-WithFailure 'DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are not both set, and this pipeline must publish (REQUIRE_CREDENTIALS): the context scalable-machine-runner-dockerhub is missing, restricted for this pipeline, or lacks a variable.'
        }
        Write-Step 'NOT PUSHED: DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are not both set (the context scalable-machine-runner-dockerhub holds them). The image was built and tested; nothing was published.'
        exit 0
    }
    Write-Step "docker login as $env:DOCKERHUB_USERNAME"
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # docker login warns on stderr
    $login = @($env:DOCKERHUB_TOKEN | & docker login --username $env:DOCKERHUB_USERNAME --password-stdin 2>&1 | ForEach-Object { "$_" })
    $loginExit = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($loginExit -ne 0) { Exit-WithFailure "docker login failed: $($login | Select-Object -Last 1)" }
    Write-Step "docker push $Name"
    $out = Invoke-Docker @('push', $Name)
    $out | Select-Object -Last 4 | ForEach-Object { Write-Host $_ }
    if ($script:dockerExit -ne 0) { Exit-WithFailure "docker push exited $script:dockerExit" }
    Write-Step "pushed $Name"
}
exit 0
