<#
.SYNOPSIS
    Proves that a STOCK Windows Server Core image runs the runner with nothing but mounts and environment
    variables (no entrypoint script). Windows
    host, Docker in Windows-container mode. Needs no runner token.

.DESCRIPTION
    The containers get exactly what windows\stack\runners.yaml gives a stock service: C:\machine-runner-swarm and C:\machine-runner-swarm\git
    mounted read-only (Git at C:\Program Files\Git), and the environment of its x-runner-env and
    x-stock-env anchors, PATH included. Prints "CHECK <name> PASS|FAIL <detail>" lines and ends with a
    RESULT line; exits 0 only when every check passed.

      os-version         the image build can run process-isolated on this host
      runner-mount       C:\machine-runner-swarm\bin\circleci-runner.exe --version works through the read-only mount (the ACL
                         grants the container identity read and execute)
      mount-readonly     a job cannot write to C:\machine-runner-swarm or to Git
      toolchain          with the stack's PATH: bash, sh, git, gzip, tar and ssh resolve; powershell.exe and
                         cmd.exe still do; C:\Program Files\Git\usr\bin\tar.exe, the path the task agent
                         hard-codes, is GNU tar; the user is ContainerAdministrator, holds
                         SeCreateSymbolicLinkPrivilege and can create a symbolic link (the runner makes one
                         for the task agent); the settings in GIT_CONFIG_* reach git
      path-default       every system directory on the image's own PATH is in the stack's PATH
      shell              "bash -eo pipefail" and "sh -eo pipefail" work: the task agent's default shell
      tar-agent-style    GNU tar called the way the task agent calls it (forward-slash operands relative to the
                         drive root, as build-agent's RelativeToRoot produces) round-trips a tree with a symlink
      git-local          git init, commit and clone work; core.longpaths is on
      long-paths         a path over 260 characters is committed and cloned
      runner-exit-80     the runner itself exits 80 for a missing name, a missing token, an invalid name and
                         an invalid mode, and says why. (A missing config FILE exits 1, shown as a NOTE.)
      config-file        the runner reads its token from the --config file, and an environment variable
                         overrides the file (name from the environment wins)
      online             (-Online only) with a bogus token and a 30 s idle timeout the REAL runner downloads
                         its task agent (symlink privilege, egress, PATH), gets 401s and exits 0 at the idle
                         timeout. Contacts runner.circleci.com and circleci-binary-releases.s3.amazonaws.com.

.PARAMETER SwarmRoot
    The staged host directory. Create it with:  .\windows\Setup.ps1 -StageOnly

.EXAMPLE
    .\windows\Setup.ps1 -StageOnly
    .\windows\tests\Test-Injection.ps1 -Online

#>
[CmdletBinding()]
param(
    [string] $Image,
    [string] $SwarmRoot = 'C:\machine-runner-swarm',
    [switch] $Online,
    [int] $OnlineTimeoutSeconds = 300,
    [ValidateSet('process', 'hyperv', 'default')][string] $Isolation = 'process',
    [string] $DockerCommand = 'docker'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'SwarmTestHelpers.psm1') -Force

if (-not $Image) { $Image = 'mcr.microsoft.com/windows/servercore:' + (Get-SwarmWindowsTag) }
$mode = 'injected'
$iso = @()
if ($Isolation -ne 'default') { $iso = @("--isolation=$Isolation") }

# What the stack gives a service: the environment and the mounts.
$stackEnv = Get-SwarmStackEnvironment
$stockPath = $stackEnv['PATH']
$envArgs = ConvertTo-SwarmEnvArgument -Environment $stackEnv
$mountArgs = Get-SwarmStockMountArgument -SwarmRoot $SwarmRoot
$psHost = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')
$runner = 'C:\machine-runner-swarm\bin\circleci-runner.exe'
$dummyToken = 'swarm-injection-not-a-real-token-0000'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "swarm-inj-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Invoke-Container {
    # docker run --rm with the stack's mounts and (unless -NoStack) environment.
    param([string] $Entrypoint, [string[]] $Argument = @(), [string[]] $Extra = @(), [switch] $NoStack)
    $run = @('run', '--rm') + $iso
    if (-not $NoStack) { $run += $mountArgs + $envArgs }
    $run += $Extra   # after the stack's environment: for a repeated --env the last one wins
    $run += @('--entrypoint', $Entrypoint, $Image) + $Argument
    return (Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList $run)
}

function Invoke-PowerShellProbe {
    # Runs a PowerShell script in a fresh container; -EncodedCommand avoids quoting problems.
    param([string] $Script, [switch] $NoStack)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
    return (Invoke-Container -Entrypoint 'powershell.exe' -Argument ($psHost + @('-EncodedCommand', $encoded)) -NoStack:$NoStack)
}

function Get-JsonLine {
    param([string[]] $Output)
    $line = @($Output | Where-Object { $_ -like '{*' } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return $null }
    try { return ($line[0] | ConvertFrom-Json) } catch { return $null }
}

try {
    # --- os-version ---------------------------------------------------------------------------------
    $imageBuild = Get-SwarmImageBuild -Image $Image -DockerCommand $DockerCommand
    if ($imageBuild -eq 0) {
        [Console]::Out.WriteLine("image $Image is not on this host; pulling it")
        $null = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('pull', $Image)
        $imageBuild = Get-SwarmImageBuild -Image $Image -DockerCommand $DockerCommand
    }
    $hostBuild = Get-SwarmHostBuild
    $canProcess = Test-SwarmProcessIsolation -HostBuild $hostBuild -ImageBuild $imageBuild
    Write-SwarmCheck 'os-version' ($imageBuild -ne 0 -and ($canProcess -or $Isolation -eq 'hyperv')) "image_build=$imageBuild host_build=$hostBuild process_isolation=$canProcess mode=$mode"

    # --- runner-mount, mount-readonly ---------------------------------------------------------------
    $r = Invoke-Container -Entrypoint $runner -Argument @('--version')
    Write-SwarmCheck 'runner-mount' ($r.ExitCode -eq 0 -and ($r.Output -join ' ') -match '\d+\.\d+\.\d+') "exit=$($r.ExitCode) $($r.Output -join ' ')"

    $r = Invoke-PowerShellProbe -Script "foreach (`$p in 'C:\machine-runner-swarm\job-wrote-this', 'C:\Program Files\Git\job-wrote-this') { try { Set-Content -LiteralPath `$p -Value x -ErrorAction Stop; 'WRITABLE' } catch { 'READONLY' } }"
    $text = $r.Output -join ' '
    Write-SwarmCheck 'mount-readonly' ($text -match 'READONLY READONLY' -and $text -notmatch 'WRITABLE') $text

    # --- toolchain, shell, tar-agent-style, git-local, long-paths -------------------------------------
    $probe = @'
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}
$r.user = (& whoami.exe)
$r.symlinkPrivilege = [bool]((& whoami.exe /priv) -match 'SeCreateSymbolicLinkPrivilege')
$r.symlinkMade = $false
try {
    New-Item -ItemType Directory -Force -Path 'C:\cci\w' | Out-Null
    Set-Content -LiteralPath 'C:\cci\w\target.txt' -Value x
    New-Item -ItemType SymbolicLink -Path 'C:\cci\w\link.txt' -Target 'C:\cci\w\target.txt' -ErrorAction Stop | Out-Null
    $r.symlinkMade = $true
} catch { $r.symlinkError = $_.Exception.Message }
foreach ($c in 'bash', 'sh', 'git', 'gzip', 'tar', 'ssh', 'powershell', 'cmd') {
    $cmd = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $r[$c] = ''
    if ($cmd) { $r[$c] = $cmd.Source }
}
$gitTar = 'C:\Program Files\Git\usr\bin\tar.exe'
$r.gitTarVersion = ((& $gitTar --version 2>&1) | Select-Object -First 1) -join ''
$r.psexec = [bool](Get-Command PsExec64.exe -ErrorAction SilentlyContinue)
$r.path = $env:Path
$r.bashRun = ((& bash -eo pipefail -c 'echo bash-ok' 2>&1) -join ' ')
$r.shRun = ((& sh -eo pipefail -c 'echo sh-ok' 2>&1) -join ' ')

# GNU tar the way the task agent calls it (build-agent pkg/tar/systemtar, pkg/path RelativeToRoot): the working
# directory is the drive root, the operands are relative to it WITH FORWARD SLASHES (C:\foo\bar becomes foo/bar,
# filepath.ToSlash), --file is the Windows path, and --force-local comes last.
try {
    $work = 'C:\cci\w\tartest'
    New-Item -ItemType Directory -Force -Path "$work\src\sub" | Out-Null
    Set-Content -LiteralPath "$work\src\sub\a.txt" -Value 'hello'
    $linkMade = $false
    try { New-Item -ItemType SymbolicLink -Path "$work\src\link.txt" -Target "$work\src\sub\a.txt" -ErrorAction Stop | Out-Null; $linkMade = $true } catch { $linkMade = $false }
    $env:MSYS = 'winsymlinks:nativestrict'
    Set-Location 'C:\'
    $archive = 'C:\cci\w\out.tar.gz'
    $o1 = & $gitTar --gzip --file $archive --create --verbose 'cci/w/tartest/src' --force-local 2>&1
    $c1 = $LASTEXITCODE
    $o2 = & $gitTar --gzip --file $archive --list --force-local 2>&1
    $c2 = $LASTEXITCODE
    New-Item -ItemType Directory -Force -Path 'C:\cci\w\tarout' | Out-Null
    Set-Location 'C:\cci\w\tarout'
    $o3 = & $gitTar --gzip --file $archive --extract --no-same-owner --force-local 2>&1
    $c3 = $LASTEXITCODE
    $content = ''
    if (Test-Path 'C:\cci\w\tarout\cci\w\tartest\src\sub\a.txt') { $content = (Get-Content 'C:\cci\w\tarout\cci\w\tartest\src\sub\a.txt' -Raw).Trim() }
    $linkBack = Test-Path 'C:\cci\w\tarout\cci\w\tartest\src\link.txt'
    $r.tar = "create=$c1 list=$c2 extract=$c3 content=$content link=$linkBack"
    $r.tarOk = ($c1 -eq 0 -and $c2 -eq 0 -and $c3 -eq 0 -and $content -eq 'hello' -and ((-not $linkMade) -or $linkBack))
    if (-not $r.tarOk) { $r.tarOutput = (@($o1) + @($o2) + @($o3)) -join ' | ' }
    # For the record, what the agent does NOT do: a relative operand with backslashes (an earlier version of this test
    # did, and msys tar could not stat it), and a --file path with \t in it.
    Set-Location 'C:\'
    $b1 = & $gitTar --gzip --file 'C:\cci\w\bs.tar.gz' --create 'cci\w\tartest\src' --force-local 2>&1
    $r.tarBackslashOperand = "exit=$LASTEXITCODE $(@($b1) | Select-Object -First 1)"
    New-Item -ItemType Directory -Force -Path 'C:\cci\w\tmp' | Out-Null
    $b2 = & $gitTar --gzip --file 'C:\cci\w\tmp\t.tar.gz' --create 'cci/w/tartest/src' --force-local 2>&1
    $r.tarFileInTmp = "exit=$LASTEXITCODE $(@($b2) | Select-Object -First 1)"
} catch { $r.tar = "exception: $($_.Exception.Message)"; $r.tarOk = $false }

# git, as a job would use it. Nothing but the stack's environment configures it.
try {
    Set-Location 'C:\cci\w'
    $r.longpathsConfig = ((& git config --get core.longpaths) -join '')
    & git init -q repo 2>&1 | Out-Null
    Set-Location 'C:\cci\w\repo'
    & git config user.email 'swarm@example.com'; & git config user.name 'swarm'
    Set-Content -LiteralPath 'file.txt' -Value 'v1'
    $deep = 'C:\cci\w\repo\' + ((1..8 | ForEach-Object { 'd' * 40 }) -join '\')
    [System.IO.Directory]::CreateDirectory('\\?\' + $deep) | Out-Null
    [System.IO.File]::WriteAllText('\\?\' + $deep + '\long.txt', 'long')
    $r.longPathLength = ($deep + '\long.txt').Length
    & git add -A 2>&1 | Out-Null
    $addExit = $LASTEXITCODE
    & git commit -q -m one 2>&1 | Out-Null
    $commitExit = $LASTEXITCODE
    Set-Location 'C:\cci\w'
    & git clone -q repo clone 2>&1 | Out-Null
    $cloneExit = $LASTEXITCODE
    $r.git = "add=$addExit commit=$commitExit clone=$cloneExit"
    $r.gitOk = ($addExit -eq 0 -and $commitExit -eq 0 -and $cloneExit -eq 0)
    $r.longPathCloned = [System.IO.File]::Exists('\\?\' + $deep.Replace('C:\cci\w\repo', 'C:\cci\w\clone') + '\long.txt')
} catch { $r.git = "exception: $($_.Exception.Message)"; $r.gitOk = $false }
$r | ConvertTo-Json -Compress
'@
    $r = Invoke-PowerShellProbe -Script $probe
    $j = Get-JsonLine -Output $r.Output
    if (-not $j) {
        $r.Output | Select-Object -Last 25 | ForEach-Object { [Console]::Out.WriteLine("  probe: $_") }
        foreach ($n in 'toolchain', 'shell', 'tar-agent-style', 'git-local', 'long-paths') { Write-SwarmCheck $n $false "probe did not return JSON (exit $($r.ExitCode))" }
    } else {
        $missing = @('bash', 'sh', 'git', 'gzip', 'tar', 'ssh', 'powershell', 'cmd' | Where-Object { -not $j.$_ })
        $isAdmin = "$($j.user)" -match 'containeradministrator'
        $isGnuTar = "$($j.gitTarVersion)" -match 'GNU tar'
        Write-SwarmCheck 'toolchain' ($missing.Count -eq 0 -and $isGnuTar -and $isAdmin -and $j.symlinkPrivilege -and $j.symlinkMade -and -not $j.psexec) `
            "missing=[$($missing -join ',')] git_tar='$($j.gitTarVersion)' user=$($j.user) symlink_privilege=$($j.symlinkPrivilege) symlink_made=$($j.symlinkMade) bash=$($j.bash) PATH=$($j.path)"
        Write-SwarmCheck 'shell' (("$($j.bashRun)" -match 'bash-ok') -and ("$($j.shRun)" -match 'sh-ok')) "bash='$($j.bashRun)' sh='$($j.shRun)'"
        Write-SwarmCheck 'tar-agent-style' ([bool]$j.tarOk) "$($j.tar) $($j.tarOutput)"
        [Console]::Out.WriteLine("NOTE tar with a backslash operand (not what the agent passes): $($j.tarBackslashOperand)")
        [Console]::Out.WriteLine("NOTE tar with --file under C:\cci\w\tmp (a backslash-t in the path): $($j.tarFileInTmp)")
        Write-SwarmCheck 'git-local' ([bool]$j.gitOk -and "$($j.longpathsConfig)" -eq 'true') "$($j.git) core.longpaths=$($j.longpathsConfig) (set by GIT_CONFIG_* in the stack)"
        Write-SwarmCheck 'long-paths' ([bool]$j.longPathCloned) "path_length=$($j.longPathLength) cloned=$($j.longPathCloned)"
    }

    # --- path-default: nothing the image needs on PATH is lost by the stack's explicit PATH ------------
    $r = Invoke-Container -Entrypoint 'cmd.exe' -Argument @('/c', 'echo %PATH%') -NoStack
    $imagePath = @($r.Output | Select-Object -Last 1) -join ''
    $norm = { param($p) $p.Trim().TrimEnd('\').ToLowerInvariant() }
    $have = @($stockPath -split ';' | ForEach-Object { & $norm $_ })
    $lost = @($imagePath -split ';' | Where-Object { $_ -and $_ -notmatch '\\Users\\' -and ($have -notcontains (& $norm $_)) })
    Write-SwarmCheck 'path-default' ($imagePath -ne '' -and $lost.Count -eq 0) "image PATH=$imagePath lost_from_stack_PATH=[$($lost -join ';')]"

    # --- runner-exit-80: the runner's own configuration check -----------------------------------------
    $cases = @(
        @{ Name = 'no-name-no-token'; Env = @(); Expect = 'must be set' }
        @{ Name = 'no-token'; Env = @('--env', 'CIRCLECI_RUNNER_NAME=swarm-test'); Expect = 'auth_token must be set' }
        @{ Name = 'no-name'; Env = @('--env', "CIRCLECI_RUNNER_API_AUTH_TOKEN=$dummyToken"); Expect = 'runner.name must be set' }
        @{ Name = 'invalid-name'; Env = @('--env', 'CIRCLECI_RUNNER_NAME=bad/name', '--env', "CIRCLECI_RUNNER_API_AUTH_TOKEN=$dummyToken"); Expect = 'must contain only' }
        @{ Name = 'invalid-mode'; Env = @('--env', 'CIRCLECI_RUNNER_NAME=swarm-test', '--env', "CIRCLECI_RUNNER_API_AUTH_TOKEN=$dummyToken", '--env', 'CIRCLECI_RUNNER_MODE=sometimes'); Expect = 'single-task' }
    )
    $codes = @()
    $allOk = $true
    foreach ($c in $cases) {
        $r = Invoke-Container -Entrypoint $runner -Argument @('machine') -Extra $c.Env
        $ok = ($r.ExitCode -eq 80) -and (($r.Output -join ' ') -match [regex]::Escape($c.Expect)) -and (($r.Output -join ' ') -notmatch [regex]::Escape($dummyToken))
        if (-not $ok) { $allOk = $false }
        $codes += "$($c.Name)=$($r.ExitCode)"
    }
    Write-SwarmCheck 'runner-exit-80' $allOk ($codes -join ' ')
    $r = Invoke-Container -Entrypoint $runner -Argument @('machine', '--config', 'C:\no\such\file.yaml') -Extra @('--env', 'CIRCLECI_RUNNER_NAME=swarm-test')
    [Console]::Out.WriteLine("NOTE a missing --config file makes the runner exit $($r.ExitCode) (not 80): $($r.Output | Select-Object -Last 1)")

    # --- config-file: the token comes from the file, the environment overrides the file ----------------
    $cfgDir = Join-Path $work 'cfg'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cfgDir 'circleci_runner_config.yaml'), "api:`n  auth_token: $dummyToken`nrunner:`n  name: swarm-name-from-file`n")
    Grant-SwarmAuthenticatedUserRead -Path $cfgDir
    $name = "swarm-inj-config-$PID"
    $run = @('run', '--detach', '--name', $name) + $iso + $mountArgs + $envArgs + @('--mount', "type=bind,source=$cfgDir,target=C:\cfg,readonly",
        '--env', 'CIRCLECI_RUNNER_NAME=swarm-name-from-env', '--env', 'CIRCLECI_RUNNER_API_URL=http://127.0.0.1:9', '--env', 'CIRCLECI_RUNNER_LOGGING_LEVEL=debug',
        '--entrypoint', $runner, $Image, 'machine', '--config', 'C:\cfg\circleci_runner_config.yaml')
    $null = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList $run
    $null = Wait-SwarmCondition -TimeoutSeconds 90 -IntervalSeconds 3 -Condition { ((Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('logs', $name)).Output -join "`n") -match 'swarm-name-from' }
    $cfgLog = (Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('logs', $name)).Output -join "`n"
    $null = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('rm', '--force', $name)
    Write-SwarmCheck 'config-file' ($cfgLog -match 'swarm-name-from-env' -and $cfgLog -notmatch 'swarm-name-from-file' -and $cfgLog -match 'REDACTED' -and $cfgLog -notmatch 'must be set' -and $cfgLog -notmatch [regex]::Escape($dummyToken)) `
        "name_from_env_wins=$($cfgLog -match 'swarm-name-from-env') token_loaded_from_file=$($cfgLog -match 'REDACTED') token_printed=$($cfgLog -match [regex]::Escape($dummyToken))"

    # --- online -------------------------------------------------------------------------------------
    if ($Online) {
        $name = "swarm-inj-online-$PID"
        $start = Get-Date
        $run = @('run', '--detach', '--name', $name) + $iso + $mountArgs + $envArgs + @('--env', "CIRCLECI_RUNNER_API_AUTH_TOKEN=$dummyToken",
            '--env', 'CIRCLECI_RUNNER_NAME=swarm-injection-online', '--env', 'CIRCLECI_RUNNER_IDLE_TIMEOUT=30s', '--entrypoint', $runner, $Image, 'machine')
        $null = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList $run
        $logs = @()
        $exitCode = $null
        while (((Get-Date) - $start).TotalSeconds -lt $OnlineTimeoutSeconds) {
            $logs = @((Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('logs', $name)).Output)
            $w = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('inspect', '--format', '{{.State.Status}} {{.State.ExitCode}}', $name)
            $st = ([string]($w.Output | Select-Object -First 1)).Trim() -split ' '
            if ($w.ExitCode -eq 0 -and $st[0] -eq 'exited') { $exitCode = $st[1]; break }
            Start-Sleep -Seconds 5
        }
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $null = Invoke-SwarmDocker -DockerCommand $DockerCommand -ArgumentList @('rm', '--force', $name)
        $logs | Select-Object -Last 15 | ForEach-Object { [Console]::Out.WriteLine("  log: $_") }
        if ($null -eq $exitCode) {
            Write-SwarmCheck 'online' $false "the runner did not exit within ${OnlineTimeoutSeconds}s. A hang before the first claim usually means the task-agent download failed: egress, a proxy, or the symlink privilege"
        } else {
            $saw401 = [bool]($logs | Where-Object { $_ -match '401|Unauthorized' })
            Write-SwarmCheck 'online' (($exitCode -eq '0') -and $saw401) "exit=$exitCode elapsed=${elapsed}s saw_401=$saw401"
        }
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$count = Get-SwarmCheckCount
$verdict = 'PASS'
if ($count.Failed -gt 0) { $verdict = 'FAIL' }
[Console]::Out.WriteLine("RESULT injection mode=$mode image=$Image checks=$($count.Checks) failed=$($count.Failed) verdict=$verdict")
if ($count.Failed -gt 0) { exit 1 }
exit 0
