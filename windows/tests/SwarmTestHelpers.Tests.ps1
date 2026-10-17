# Pester 5+ unit tests for the helpers behind the Windows-only tests, and a syntax check of the
# PowerShell that those tests run inside containers. Runs on Linux or Windows; needs no Docker.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'SwarmTestHelpers.psm1') -Force
}

Describe 'Test-SwarmProcessIsolation' {
    It 'follows Microsoft''s matrix' -TestCases @(
        @{ HostBuild = 20348; ImageBuild = 20348; Expected = $true }
        @{ HostBuild = 26100; ImageBuild = 26100; Expected = $true }
        @{ HostBuild = 26100; ImageBuild = 20348; Expected = $true }
        @{ HostBuild = 20348; ImageBuild = 26100; Expected = $false }
        @{ HostBuild = 20348; ImageBuild = 17763; Expected = $false }
    ) {
        param($HostBuild, $ImageBuild, $Expected)
        Test-SwarmProcessIsolation -HostBuild $HostBuild -ImageBuild $ImageBuild | Should -Be $Expected
    }
}

Describe 'Get-SwarmWindowsTag' {
    It 'maps the supported builds and refuses others' {
        Get-SwarmWindowsTag -Build 20348 | Should -Be 'ltsc2022'
        Get-SwarmWindowsTag -Build 26100 | Should -Be 'ltsc2025'
        { Get-SwarmWindowsTag -Build 19045 } | Should -Throw '*pass -Image*'
    }
}

Describe 'ConvertFrom-SwarmServiceTaskLine' {
    It 'parses docker service ps json lines and ignores everything else' {
        $lines = @(
            '{"ID":"abc","Name":"runners_windows-default.1","Node":"WIN1","DesiredState":"Running","CurrentState":"Pending 3 seconds ago","Error":"no suitable node (scheduling constraints not satisfied on 1 node)"}',
            'not json',
            '{"ID":"def","Name":"runners_windows-default.1","Node":"WIN1","DesiredState":"Shutdown","CurrentState":"Failed 10 seconds ago","Error":"task: non-zero exit (80)"}')
        $t = @(ConvertFrom-SwarmServiceTaskLine -Line $lines)
        $t.Count | Should -Be 2
        $t[0].CurrentState | Should -Match '^Pending'
        $t[1].Error | Should -Be 'task: non-zero exit (80)'
    }
}

Describe 'Measure-SwarmFakeJobLine' {
    It 'tells containers apart by host= and counts residue' {
        $lines = @(
            'FAKEJOB layer=aaa host=C1 user=u residue=[]',
            'FAKEJOB layer=bbb host=C2 user=u residue=[]',
            'FAKEJOB layer=ccc host=C2 user=u residue=[C:\Users\x\.job-marker]',
            'noise')
        $oldOut = [Console]::Out
        [Console]::SetOut((New-Object System.IO.StringWriter))
        try { $m = Measure-SwarmFakeJobLine -ModeName 'unit' -Line $lines } finally { [Console]::SetOut($oldOut) }
        $m.Jobs | Should -Be 3
        $m.Distinct | Should -Be 2
        $m.Dirty | Should -Be 1
    }
}

Describe 'Get-SwarmImageBuild' {
    It 'reads the build from docker image inspect' {
        Mock -ModuleName SwarmTestHelpers Invoke-SwarmDocker { return @{ ExitCode = 0; Output = @('windows 10.0.20348.5622') } }
        Get-SwarmImageBuild -Image 'x' | Should -Be 20348
    }

    It 'returns 0 for a missing or non-Windows image' {
        Mock -ModuleName SwarmTestHelpers Invoke-SwarmDocker { return @{ ExitCode = 1; Output = @('No such image') } }
        Get-SwarmImageBuild -Image 'x' | Should -Be 0
        Mock -ModuleName SwarmTestHelpers Invoke-SwarmDocker { return @{ ExitCode = 0; Output = @('linux 6.1') } }
        Get-SwarmImageBuild -Image 'x' | Should -Be 0
    }
}

Describe 'Initialize-SwarmCluster' {
    It 'does nothing on an active manager' {
        Mock -ModuleName SwarmTestHelpers Invoke-SwarmDocker { return @{ ExitCode = 0; Output = @('active true') } }
        (Initialize-SwarmCluster).Initialised | Should -BeFalse
        Should -Invoke -ModuleName SwarmTestHelpers Invoke-SwarmDocker -Times 1
    }

    It 'initialises an inactive engine and says so, so the caller can leave it again' {
        Mock -ModuleName SwarmTestHelpers Invoke-SwarmDocker {
            if ($ArgumentList[0] -eq 'info') { return @{ ExitCode = 0; Output = @('inactive false') } }
            return @{ ExitCode = 0; Output = @('Swarm initialized') }
        }
        (Initialize-SwarmCluster -AdvertiseAddr '10.0.0.5').Initialised | Should -BeTrue
        Should -Invoke -ModuleName SwarmTestHelpers Invoke-SwarmDocker -ParameterFilter { $ArgumentList[0] -eq 'swarm' -and $ArgumentList -contains '10.0.0.5' }
    }

    It 'refuses a worker node' {
        Mock -ModuleName SwarmTestHelpers Invoke-SwarmDocker { return @{ ExitCode = 0; Output = @('active false') } }
        { Initialize-SwarmCluster } | Should -Throw '*worker*'
    }
}

Describe 'Get-SwarmServiceSchedulingEarlyFailure' {
    BeforeAll {
        $script:RejectedTaskJson = '{"ID":"r1","Name":"runners_runner-distributor-windows.1","Node":"","DesiredState":"Rejected","CurrentState":"Rejected 2 seconds ago","Error":"No suitable node (scheduling constraints not satisfied on 1 node)"}'
        $script:PreparingTaskJson = '{"ID":"p1","Name":"runners_runner-distributor-windows.1","Node":"WIN1","DesiredState":"Running","CurrentState":"Preparing 1 minute ago","Error":""}'
        $script:MockLabelsJson = '{"machine-runner-swarm.windows-ltsc2022":"true"}'
        $script:MockPlacementJson = '{"Constraints":["node.platform.os == windows"]}'
    }

    It 'fails fast when Swarm scheduled no tasks' {
        Mock -ModuleName SwarmTestHelpers Invoke-SwarmDocker {
            if ($ArgumentList -contains '--format' -and ($ArgumentList -contains '{{json .}}')) {
                return @{ ExitCode = 0; Output = @() }
            }
            return @{ ExitCode = 0; Output = @('') }
        }
        Get-SwarmServiceSchedulingEarlyFailure -Service 'runners_runner-distributor-windows' | Should -Be 'Swarm scheduled no tasks for the service (placement constraints may be unmet)'
    }

    It 'keeps waiting while a task is still Preparing' {
        Mock -ModuleName SwarmTestHelpers Invoke-SwarmDocker {
            if ($ArgumentList -contains '--format' -and ($ArgumentList -contains '{{json .}}')) {
                return @{ ExitCode = 0; Output = @($script:PreparingTaskJson) }
            }
            return @{ ExitCode = 0; Output = @('') }
        }
        Get-SwarmServiceSchedulingEarlyFailure -Service 'runners_runner-distributor-windows' | Should -BeNullOrEmpty
    }

    It 'fails fast when every task was rejected or failed' {
        Mock -ModuleName SwarmTestHelpers Invoke-SwarmDocker {
            if ($ArgumentList -contains '--format' -and ($ArgumentList -contains '{{json .}}')) {
                return @{ ExitCode = 0; Output = @($script:RejectedTaskJson) }
            }
            return @{ ExitCode = 0; Output = @('') }
        }
        $reason = Get-SwarmServiceSchedulingEarlyFailure -Service 'runners_runner-distributor-windows'
        $reason | Should -Match '^every service task failed or was rejected'
        $reason | Should -Match 'scheduling constraints'
    }
}

Describe 'Install-SwarmDistributor early scheduling failure' {
    BeforeAll {
        $script:DistService = 'runners_runner-distributor-windows'
        $script:MockLabelsJson = '{"machine-runner-swarm.windows-ltsc2022":"true"}'
        $script:MockPlacementJson = '{"Constraints":["node.platform.os == windows","node.labels.machine-runner-swarm.windows-ltsc2022 == true"]}'
    }

    It 'adds node labels and placement constraints to the detail after the grace period' {
        Mock -ModuleName SwarmTestHelpers Invoke-SwarmDocker {
            $cmd = $ArgumentList[0]
            if ($cmd -eq 'secret') { return @{ ExitCode = 0; Output = @('exists') } }
            if ($cmd -eq 'stack') { return @{ ExitCode = 0; Output = @('Created') } }
            if ($cmd -eq 'service' -and $ArgumentList -contains 'logs') { return @{ ExitCode = 0; Output = @('') } }
            if ($cmd -eq 'service' -and $ArgumentList -contains '--format' -and ($ArgumentList -contains '{{json .}}')) {
                return @{ ExitCode = 0; Output = @() }
            }
            if ($cmd -eq 'service' -and $ArgumentList -contains '--no-trunc' -and -not ($ArgumentList -contains '--format')) {
                return @{ ExitCode = 0; Output = @('ID NAME IMAGE NODE DESIRED STATE CURRENT STATE ERROR') }
            }
            if ($cmd -eq 'service' -and $ArgumentList -contains 'inspect') {
                return @{ ExitCode = 0; Output = @($script:MockPlacementJson) }
            }
            if ($cmd -eq 'node') { return @{ ExitCode = 0; Output = @($script:MockLabelsJson) } }
            if ($cmd -eq 'image') { return @{ ExitCode = 0; Output = @('REPOSITORY TAG IMAGE ID') } }
            return @{ ExitCode = 0; Output = @('') }
        }
        $r = Install-SwarmDistributor -Stack 'runners' -StackFile (Join-Path $PSScriptRoot '..\stack\runners.yaml') -TimeoutSeconds 30 -EarlyFailureGraceSeconds 1 -DockerCommand 'docker'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'stopped after 1s'
        $r.Detail | Should -Match 'docker node inspect self \(labels\)'
        $r.Detail | Should -Match $script:MockLabelsJson
        $r.Detail | Should -Match 'docker service inspect \(placement\)'
        $r.Detail | Should -Match 'node.labels.machine-runner-swarm.windows-ltsc2022'
    }
}

Describe 'Get-SwarmStackEnvironment and the stock mounts' {
    It 'reads the environment the stack gives a stock service, without Swarm templates' {
        $e = Get-SwarmStackEnvironment
        $e['CIRCLECI_RUNNER_MODE'] | Should -Be 'single-task'
        $e['CIRCLECI_RUNNER_WORK_DIR'] | Should -Be 'C:\cci\w'
        $e['GIT_CONFIG_COUNT'] | Should -Be '1'
        $e['GIT_CONFIG_KEY_0'] | Should -Be 'core.longpaths'
        $e['PATH'] | Should -BeLike 'C:\Windows\system32;*'
        $e['PATH'] | Should -BeLike '*;C:\Program Files\Git\usr\bin'
        $e.ContainsKey('MACHINE_RUNNER_SWARM_INSTANCE_ID') | Should -BeFalse
        $e.ContainsKey('CIRCLECI_RUNNER_NAME') | Should -BeFalse
        $e.ContainsKey('CIRCLECI_RUNNER_API_URL') | Should -BeFalse -Because 'the token proxy service exists only inside the stack, and the tests run a standalone runner'
    }

    It 'turns it into docker run arguments' {
        $a = ConvertTo-SwarmEnvArgument -Environment @{ B = '2'; A = '1' }
        $a | Should -Be @('--env', 'A=1', '--env', 'B=2')
    }

    It 'mounts the links current and git\current of the runner-bin volume at C:\machine-runner-swarm and where the task agent expects Git, read-only' {
        $m = Get-SwarmStockMountArgument -Volume 'v1'
        $m | Should -Contain 'type=volume,source=v1,target=C:\machine-runner-swarm,readonly,volume-subpath=current'
        $m | Should -Contain 'type=volume,source=v1,target=C:\Program Files\Git,readonly,volume-subpath=git\current'
        (Get-SwarmStockMountArgument)[1] | Should -Match 'source=runners_runner-bin,'
    }
}

Describe 'Windows-only test scripts' {
    BeforeAll {
        # The scripts that run INSIDE containers are here-strings; make sure they parse.
        function Get-HereString([string] $Path) {
            $text = Get-Content -LiteralPath $Path -Raw
            [regex]::Matches($text, "(?s)@'\r?\n(.*?)\r?\n'@") | ForEach-Object { $_.Groups[1].Value }
        }
    }

    It 'has a syntax-clean <Name>' -TestCases @(
        @{ Name = 'Test-Injection.ps1' }, @{ Name = 'Test-Ephemerality.ps1' }, @{ Name = 'Test-Exit80.ps1' },
        @{ Name = 'Test-Placement.ps1' }, @{ Name = 'Test-StopHandling.ps1' }, @{ Name = 'Test-Persistent.ps1' }, @{ Name = 'Test-Distributor.ps1' }, @{ Name = 'Test-Install.ps1' }
    ) {
        param($Name)
        $errors = $null
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name), [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'has parseable container probes in Test-Injection.ps1' {
        $probes = @(Get-HereString (Join-Path $PSScriptRoot 'Test-Injection.ps1'))
        $probes.Count | Should -BeGreaterThan 0
        foreach ($p in $probes) {
            $errors = $null
            $tokens = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($p, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0
        }
    }

    It 'prints the RESULT and CHECK lines the CI expectations promise' {
        foreach ($pair in @(@('Test-Injection.ps1', 'RESULT injection'), @('Test-Ephemerality.ps1', 'Measure-SwarmFakeJobLine'), @('SwarmTestHelpers.psm1', 'RESULT mode='), @('Test-Exit80.ps1', 'RESULT exit80'),
                @('Test-Placement.ps1', 'RESULT placement'), @('Test-StopHandling.ps1', 'RESULT stop'), @('Test-Persistent.ps1', 'RESULT persistent'), @('Test-Distributor.ps1', 'RESULT distributor'), @('Test-Install.ps1', 'RESULT install'))) {
            (Get-Content -LiteralPath (Join-Path $PSScriptRoot $pair[0]) -Raw) | Should -Match ([regex]::Escape($pair[1]))
        }
    }
}
