# Pester 5+ unit tests for windows/Setup.ps1 and the pins it shares with the baked-image Dockerfile.
# Cross-platform (Linux pwsh or Windows); Docker and the network are never touched.

BeforeAll {
    $script:windowsDir = Join-Path $PSScriptRoot '..'
    . (Join-Path $script:windowsDir 'Setup.ps1')
    $script:dockerfile = Get-Content -LiteralPath (Join-Path $script:windowsDir 'images\servercore\Dockerfile') -Raw
    function Get-DockerfileArg([string] $Name) {
        if ($script:dockerfile -match "(?m)^ARG $Name=(\S+)\s*$") { return $Matches[1] }
        return $null
    }
}

Describe 'Pins' {
    It 'are the same in Setup.ps1 and the baked-image Dockerfile' -TestCases @(
        @{ Arg = 'GIT_VERSION'; Pin = 'GitVersion' }
        @{ Arg = 'GIT_RELEASE_TAG'; Pin = 'GitReleaseTag' }
        @{ Arg = 'GIT_SHA256'; Pin = 'GitSha256' }
        @{ Arg = 'SEVENZIP_VERSION'; Pin = 'SevenZipVersion' }
        @{ Arg = 'SEVENZIP_SHA256'; Pin = 'SevenZipSha256' }
    ) {
        param($Arg, $Pin)
        Get-DockerfileArg $Arg | Should -Be $script:Pins[$Pin]
    }

    It 'look like SHA-256 values' {
        $script:Pins.GitSha256 | Should -Match '^[0-9a-f]{64}$'
        $script:Pins.SevenZipSha256 | Should -Match '^[0-9a-f]{64}$'
        Get-DockerfileArg 'RUNNER_SHA256' | Should -Match '^[0-9a-f]{64}$'
    }

    It 'derive the Git release tag from the version (2.56.0.2 is release tag v2.56.0.windows.2)' {
        $script:Pins.GitReleaseTag | Should -Be ('v' + ($script:Pins.GitVersion -replace '^(\d+\.\d+\.\d+)\.(\d+)$', '$1.windows.$2'))
    }

    It 'give Setup.ps1 and the Dockerfile the same runner version' {
        Get-DockerfileArg 'RUNNER_VERSION' | Should -Be '3.1.12'
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
