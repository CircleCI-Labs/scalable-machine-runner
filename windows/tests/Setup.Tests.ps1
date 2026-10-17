# Pester 5+ unit tests for windows/Setup.ps1.
# Cross-platform (Linux pwsh or Windows); Docker and the network are never touched.

BeforeAll {
    $script:windowsDir = Join-Path $PSScriptRoot '..'
    . (Join-Path $script:windowsDir 'Setup.ps1')
}

Describe 'Get-BuildLabel' {
    It 'maps Server 2022 and 2025 builds to the image tag, and nothing else' -TestCases @(
        @{ Build = 20348; Label = 'ltsc2022' }, @{ Build = 26100; Label = 'ltsc2025' }, @{ Build = 17763; Label = $null }
    ) {
        param($Build, $Label)
        Get-BuildLabel -Build $Build | Should -Be $Label
    }
}

Describe 'Get-CapabilityLabel' {
    It 'gives a Server 2022 host windows-ltsc2022, a Server 2025 host both (it also runs ltsc2022 images), and anything else nothing' {
        @(Get-CapabilityLabel -Build 20348) | Should -Be @('windows-ltsc2022')
        @(Get-CapabilityLabel -Build 26100) | Should -Be @('windows-ltsc2022', 'windows-ltsc2025')
        @(Get-CapabilityLabel -Build 17763).Count | Should -Be 0
    }

    It 'covers the label every stack file requires, on every supported build' {
        foreach ($build in 20348, 26100) { @(Get-CapabilityLabel -Build $build) | Should -Contain 'windows-ltsc2022' }
    }
}

Describe 'Install-CapabilityLabel' {
    It 'adds machine-runner-swarm.<name>=true for each capability' {
        $script:calls = @()
        Mock Invoke-Docker { $script:calls += , ($ArgumentList -join ' '); return @{ ExitCode = 0; Output = @() } }
        Install-CapabilityLabel -NodeId 'node1' -Build 26100 | Out-Null
        $script:calls | Should -Be @(
            'node update --label-add machine-runner-swarm.windows-ltsc2022=true node1',
            'node update --label-add machine-runner-swarm.windows-ltsc2025=true node1')
    }

    It 'stops when docker refuses the label, because every replica would stay Pending' {
        Mock Invoke-Docker { return @{ ExitCode = 1; Output = @('not a swarm manager') } }
        { Install-CapabilityLabel -NodeId 'node1' -Build 20348 | Out-Null } | Should -Throw '*not a swarm manager*'
    }
}

Describe 'Get-DockerInfo' {
    It 'parses docker info' {
        Mock Invoke-Docker { return @{ ExitCode = 0; Output = @('windows|active|true|abc123') } }
        $d = Get-DockerInfo
        $d.OSType | Should -Be 'windows'
        $d.Swarm | Should -Be 'active'
        $d.Manager | Should -BeTrue
        $d.NodeId | Should -Be 'abc123'
    }

    It 'returns nothing without a working docker' {
        Mock Invoke-Docker { return @{ ExitCode = 127; Output = @('not found') } }
        Get-DockerInfo | Should -BeNullOrEmpty
    }
}

Describe 'Test-DockerVersion' {
    It 'wants the CLI and the engine at 28.0 or later: volume.subpath in a stack file is ignored by the CLI before 28.0 and by Swarm before 26.1' -TestCases @(
        @{ Client = '29.4.0'; Server = '29.4.0'; Ok = $true }, @{ Client = '28.0.0'; Server = '28.1.1'; Ok = $true }, @{ Client = '28.0.0-rc.1'; Server = '29.0.0'; Ok = $true },
        @{ Client = '27.5.1'; Server = '29.0.0'; Ok = $false }, @{ Client = '29.0.0'; Server = '26.1.0'; Ok = $false }, @{ Client = '29.0.0'; Server = 'unknown'; Ok = $false }
    ) {
        param($Client, $Server, $Ok)
        Test-DockerVersion @{ Client = $Client; Server = $Server } | Should -Be $Ok
    }

    It 'fails without a working docker' {
        Test-DockerVersion $null | Should -BeFalse
    }
}

Describe 'Get-DockerVersion' {
    It 'parses docker version' {
        Mock Invoke-Docker { return @{ ExitCode = 0; Output = @('29.4.0|29.4.1') } }
        $v = Get-DockerVersion
        $v.Client | Should -Be '29.4.0'
        $v.Server | Should -Be '29.4.1'
    }

    It 'returns nothing without a working docker' {
        Mock Invoke-Docker { return @{ ExitCode = 127; Output = @('not found') } }
        Get-DockerVersion | Should -BeNullOrEmpty
    }
}

Describe 'Initialize-Swarm' {
    It 'needs the address only while the swarm is inactive, so a run on an active swarm is safe to repeat' {
        Mock Invoke-Docker { return @{ ExitCode = 0; Output = @('windows|active|true|abc123') } }
        Initialize-Swarm -AdvertiseAddr '' | Should -BeFalse
        Should -Invoke Invoke-Docker -Times 1 -Exactly   # only docker info: no swarm init
    }

    It 'asks for the address when the swarm is inactive' {
        Mock Invoke-Docker { return @{ ExitCode = 0; Output = @('windows|inactive|false|') } }
        { Initialize-Swarm -AdvertiseAddr '' } | Should -Throw '*-AdvertiseAddr*'
    }

    It 'runs docker swarm init with the address when the swarm is inactive' {
        $script:swarmCalls = @()
        $script:infoCalls = 0
        Mock Invoke-Docker {
            $script:swarmCalls += , ($ArgumentList -join ' ')
            if ($ArgumentList[0] -eq 'info') {
                $script:infoCalls++
                if ($script:infoCalls -eq 1) { return @{ ExitCode = 0; Output = @('windows|inactive|false|') } }
                return @{ ExitCode = 0; Output = @('windows|active|true|abc123') }
            }
            return @{ ExitCode = 0; Output = @() }
        }
        Initialize-Swarm -AdvertiseAddr '10.0.0.5' | Should -BeTrue
        $script:swarmCalls | Should -Contain 'swarm init --advertise-addr 10.0.0.5'
    }
}

Describe 'Get-NextStep' {
    It 'names only the steps that are not done' {
        @(Get-NextStep -SwarmActive $true -HasSecrets $true -Deployed $true -StackFile @('a.yaml') -StackName 'runners').Count | Should -Be 0
        $s = @(Get-NextStep -SwarmActive $true -HasSecrets $true -Deployed $false -StackFile @('a.yaml', 'b.yaml') -StackName 'runners')
        $s.Count | Should -Be 1
        $s[0] | Should -Be 'docker stack deploy -c a.yaml -c b.yaml runners'
        $s = @(Get-NextStep -SwarmActive $true -HasSecrets $false -Deployed $false -StackFile @('a.yaml') -StackName 'runners')
        $s.Count | Should -Be 2
        $s[0] | Should -BeLike '*-Class windows-default*'
    }

    It 'lists every step on a fresh host' {
        @(Get-NextStep -SwarmActive $false -HasSecrets $false -Deployed $false -StackFile @('a.yaml') -StackName 'runners').Count | Should -Be 3
    }
}

Describe 'Get-InstallState' {
    It 'reads the swarm, the secrets and the stack from docker' {
        Mock Invoke-Docker {
            switch ($ArgumentList[0]) {
                'info' { return @{ ExitCode = 0; Output = @('windows|active|true|abc123') } }
                'secret' { return @{ ExitCode = 0; Output = @('runner-placeholder-token', 'windows-default-token') } }
                'stack' { return @{ ExitCode = 0; Output = @('runners_windows-default') } }
            }
        }
        $st = Get-InstallState -StackName 'runners'
        $st.SwarmActive | Should -BeTrue
        $st.HasSecrets | Should -BeTrue
        $st.Deployed | Should -BeTrue
    }

    It 'needs the placeholder and a class token for the secrets' {
        Mock Invoke-Docker {
            switch ($ArgumentList[0]) {
                'info' { return @{ ExitCode = 0; Output = @('windows|active|true|abc123') } }
                'secret' { return @{ ExitCode = 0; Output = @('windows-default-token') } }
                'stack' { return @{ ExitCode = 1; Output = @() } }
            }
        }
        $st = Get-InstallState -StackName 'runners'
        $st.HasSecrets | Should -BeFalse
        $st.Deployed | Should -BeFalse
    }
}
