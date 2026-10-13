# Pester 5+ unit tests for windows/Setup.ps1 and its pins.
# Cross-platform (Linux pwsh or Windows); Docker and the network are never touched.

BeforeAll {
    $script:windowsDir = Join-Path $PSScriptRoot '..'
    . (Join-Path $script:windowsDir 'Setup.ps1')
}

Describe 'Pins' {
    It 'look like SHA-256 values' {
        $script:Pins.GitSha256 | Should -Match '^[0-9a-f]{64}$'
        $script:Pins.SevenZipSha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'derive the Git release tag from the version (2.56.0.2 is release tag v2.56.0.windows.2)' {
        $script:Pins.GitReleaseTag | Should -Be ('v' + ($script:Pins.GitVersion -replace '^(\d+\.\d+\.\d+)\.(\d+)$', '$1.windows.$2'))
    }

    It 'give Setup.ps1 the runner version of linux/setup.sh' {
        $linux = Get-Content -LiteralPath (Join-Path $script:windowsDir '..\linux\setup.sh') -Raw
        $linux | Should -Match '(?m)^MACHINE_RUNNER_SWARM_VERSION=3\.1\.12\r?$'
        (Select-String -LiteralPath (Join-Path $script:windowsDir 'Setup.ps1') -Pattern "\[string\] \`$RunnerVersion = '3.1.12'" -Quiet) | Should -BeTrue
    }
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

Describe 'Install-Stage' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Force -Path (Join-Path $script:dir 'git/usr/bin') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:dir 'git/usr/bin/tar.exe') -Value x
        Set-Content -LiteralPath (Join-Path $script:dir 'VERSION') -Value @('runner=3.1.12', "git=$($script:Pins.GitVersion)")
        Mock Invoke-WebRequest { return [pscustomobject]@{ Content = '{"releases":{"3.1.12":{"windows":{"amd64":{"sha256":"abc","url":"u"}}}}}' } }
    }

    It 'does nothing when the same runner and Git are already staged' {
        Install-Stage -Dir $script:dir -Version '3.1.12'
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'rejects a runner version that is not in the manifest' {
        { Install-Stage -Dir $script:dir -Version '9.9.9' } | Should -Throw '*no windows/amd64 build*'
    }
}

Describe 'Switch-CurrentLink' {
    It 'protects the root, then points a junction at the version, replacing the old link and keeping the old version' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $root = Join-Path $TestDrive 'swarm'
        foreach ($v in '1.0.0', '2.0.0') { New-Item -ItemType Directory -Force -Path (Join-Path $root $v) | Out-Null; Set-Content -LiteralPath (Join-Path $root "$v\VERSION") -Value $v }
        Mock Invoke-Acl { }
        Switch-CurrentLink -Root $root -Version '1.0.0'
        (Get-Content -LiteralPath (Join-Path $root 'current\VERSION')) | Should -Be '1.0.0'
        Switch-CurrentLink -Root $root -Version '2.0.0'
        (Get-Content -LiteralPath (Join-Path $root 'current\VERSION')) | Should -Be '2.0.0'
        (Get-Content -LiteralPath (Join-Path $root '1.0.0\VERSION')) | Should -Be '1.0.0'
        Should -Invoke Invoke-Acl -Times 2
    }
}

Describe 'Protect-Directory' {
    It 'sets the ACL on the directory only, then resets every child to inherit it' {
        $script:calls = New-Object System.Collections.Generic.List[string]
        Mock Invoke-Acl { $script:calls.Add(($args -join ' ')) }
        Protect-Directory -Dir 'S:\machine-runner-swarm'
        $script:calls.Count | Should -Be 2
        $script:calls[0] | Should -Match '^S:\\machine-runner-swarm /inheritance:r /grant:r \*S-1-5-18:\(OI\)\(CI\)F \*S-1-5-32-544:\(OI\)\(CI\)F \*S-1-5-11:\(OI\)\(CI\)RX$'
        $script:calls[0] | Should -Not -Match '/T'
        $script:calls[1] | Should -Be 'S:\machine-runner-swarm\* /reset /T /C /Q'
    }
}
