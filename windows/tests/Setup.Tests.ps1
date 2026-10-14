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
