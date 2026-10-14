# Pester 5+ unit tests for windows/stack/runner-distributor.ps1 (the settings, the manifest and the choice of a version).
# Cross-platform (Linux pwsh or Windows); Docker, the network and the volume are never touched. Test-Distributor.ps1 runs the
# script itself against a mirror on a Windows host.

BeforeAll {
    $script:script = Join-Path $PSScriptRoot '..\stack\runner-distributor.ps1'
    . $script:script
    $script:Root = Join-Path $TestDrive 'runner-bin'
    if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
    function Use-DistributorEnvironment {
        param([hashtable] $Values = @{})
        foreach ($n in 'RUNNER_VERSION', 'RUNNER_MAJOR', 'CHECK_INTERVAL', 'DOWNLOAD_BASE_URL', 'RUNNER_SHA256', 'TOOLS_BASE_URL', 'PROXY_VERSION', 'PROXY_BASE_URL', 'PROXY_LATEST_URL', 'PROXY_SHA256') { Remove-Item "Env:MACHINE_RUNNER_SWARM_$n" -ErrorAction SilentlyContinue }
        foreach ($k in $Values.Keys) { Set-Item "Env:MACHINE_RUNNER_SWARM_$k" $Values[$k] }
    }
    $script:manifestJson = @{ releases = [ordered]@{
            '3.0.9'  = @{ windows = @{ amd64 = @{ sha256 = ('a' * 64); url = 'u' } } }
            '3.1.2'  = @{ windows = @{ amd64 = @{ sha256 = ('b' * 64); url = 'u' } } }
            '3.1.10' = @{ windows = @{ amd64 = @{ sha256 = ('c' * 64); url = 'u' }; arm64 = @{ sha256 = ('1' * 64); url = 'u' } } }
            '3.2.0'  = @{ windows = @{ amd64 = @{ sha256 = ('e' * 64); url = 'u' } } }
            '4.0.0'  = @{ windows = @{ amd64 = @{ sha256 = ('d' * 64); url = 'u' } } }
            'current' = @{ windows = @{ amd64 = @{ sha256 = ('c' * 64); url = 'u' }; arm64 = @{ sha256 = ('1' * 64); url = 'u' } } }
            'edge'   = @{ windows = @{ amd64 = @{ sha256 = ('d' * 64); url = 'u' } } }
        } } | ConvertTo-Json -Depth 8
}

Describe 'ConvertTo-Second' {
    It 'reads seconds, and a number with s, m, h or d' -TestCases @(
        @{ Value = '90'; Seconds = 90 }, @{ Value = '30s'; Seconds = 30 }, @{ Value = '10m'; Seconds = 600 }, @{ Value = '24h'; Seconds = 86400 }, @{ Value = '2d'; Seconds = 172800 }
    ) {
        param($Value, $Seconds)
        ConvertTo-Second $Value | Should -Be $Seconds
    }

    It 'refuses a value that is not a number with a unit, and zero' -TestCases @(@{ Value = 'soon' }, @{ Value = '1h30' }, @{ Value = '-5' }, @{ Value = '0' }) {
        param($Value)
        $text = $Value
        { ConvertTo-Second $text } | Should -Throw
    }
}

Describe 'Get-DistributorSetting' {
    It 'asks for a version: the stack file sets an exact pin, and the script has no default of its own' {
        Use-DistributorEnvironment
        { Get-DistributorSetting } | Should -Throw '*MACHINE_RUNNER_SWARM_RUNNER_VERSION is empty*'
    }

    It 'checks every 24 hours, within major 3, against CircleCI, by default' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13' }
        $s = Get-DistributorSetting
        $s.Want | Should -Be '3.1.13'
        $s.Kind | Should -Be 'exact'
        $s.Major | Should -Be '3'
        $s.Interval | Should -Be 86400
        $s.Base | Should -Be 'https://circleci-binary-releases.s3.amazonaws.com/circleci-runner'
        @($s.Hashes).Count | Should -Be 0
    }

    It 'reads a pinned version, a mirror without a trailing slash, and a list of SHA-256 values in any case' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.12'; DOWNLOAD_BASE_URL = 'https://mirror.example.com/runner/'; CHECK_INTERVAL = '5m'; RUNNER_SHA256 = ('A' * 64) + ', ' + ('b' * 64) }
        $s = Get-DistributorSetting
        $s.Want | Should -Be '3.1.12'
        $s.Kind | Should -Be 'exact'
        $s.Base | Should -Be 'https://mirror.example.com/runner'
        $s.Interval | Should -Be 300
        $s.Retry | Should -Be 300
        @($s.Hashes) | Should -Be @(('a' * 64), ('b' * 64))
    }

    It 'tells an exact pin from the floating values 3.1, 3 and current' -TestCases @(
        @{ Value = '3.1.13'; Kind = 'exact' }, @{ Value = '3.1'; Kind = 'minor' }, @{ Value = '3'; Kind = 'major' }, @{ Value = 'current'; Kind = 'current' }
    ) {
        param($Value, $Kind)
        Use-DistributorEnvironment @{ RUNNER_VERSION = $Value }
        $s = Get-DistributorSetting
        $s.Want | Should -Be $Value
        $s.Kind | Should -Be $Kind
    }

    It 'retries a failed check after 5 minutes, or the interval when that is shorter' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; CHECK_INTERVAL = '1h' }
        (Get-DistributorSetting).Retry | Should -Be 300
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; CHECK_INTERVAL = '20s' }
        (Get-DistributorSetting).Retry | Should -Be 20
    }

    It 'refuses a setting that cannot work, so that the service fails visibly' -TestCases @(
        @{ Name = 'RUNNER_VERSION'; Value = 'latest' }, @{ Name = 'RUNNER_VERSION'; Value = '3.' }, @{ Name = 'RUNNER_VERSION'; Value = '.1' }, @{ Name = 'RUNNER_VERSION'; Value = '3.x' },
        @{ Name = 'RUNNER_MAJOR'; Value = 'three' }, @{ Name = 'CHECK_INTERVAL'; Value = 'often' }, @{ Name = 'RUNNER_SHA256'; Value = 'abc' }
    ) {
        param($Name, $Value)
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13' }
        Set-Item "Env:MACHINE_RUNNER_SWARM_$Name" $Value
        { Get-DistributorSetting } | Should -Throw
    }
}


Describe 'Get-DistributorSetting, the token proxy' {
    It 'installs no proxy without a version, and downloads from the GitHub releases of this repository' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13' }
        $s = Get-DistributorSetting
        $s.ProxyVersion | Should -Be ''
        $s.ProxyBase | Should -Be 'https://github.com/CircleCI-Labs/scalable-machine-runner/releases/download'
        $s.ProxyLatest | Should -Be 'https://api.github.com/repos/CircleCI-Labs/scalable-machine-runner/releases/latest'
        @($s.ProxyHashes).Count | Should -Be 0
    }

    It 'takes unreleased, a checkout, as the latest published release' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; PROXY_VERSION = 'unreleased'; PROXY_LATEST_URL = 'https://mirror.example.com/latest.json' }
        $s = Get-DistributorSetting
        $s.ProxyVersion | Should -Be 'unreleased'
        $s.ProxyLatest | Should -Be 'https://mirror.example.com/latest.json'
    }

    It 'reads a release, a mirror without a trailing slash, and a list of SHA-256 values in any case' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; PROXY_VERSION = '0.3.0'; PROXY_BASE_URL = 'https://mirror.example.com/proxy/'; PROXY_SHA256 = ('A' * 64) + ', ' + ('b' * 64) }
        $s = Get-DistributorSetting
        $s.ProxyVersion | Should -Be '0.3.0'
        $s.ProxyBase | Should -Be 'https://mirror.example.com/proxy'
        @($s.ProxyHashes) | Should -Be @(('a' * 64), ('b' * 64))
    }

    It 'refuses a proxy version that is not a release, and a hash that is not a SHA-256' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; PROXY_VERSION = 'latest' }
        { Get-DistributorSetting } | Should -Throw '*MACHINE_RUNNER_SWARM_PROXY_VERSION*'
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; PROXY_VERSION = '0.3.0'; PROXY_SHA256 = 'abc' }
        { Get-DistributorSetting } | Should -Throw '*MACHINE_RUNNER_SWARM_PROXY_SHA256*'
    }
}

Describe 'Get-RunnerArchitecture' {
    AfterAll { Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue }

    It 'maps PROCESSOR_ARCHITECTURE to the architectures of the manifest, and a 32-bit PowerShell on 64-bit Windows to its host' -TestCases @(
        @{ Arch = 'AMD64'; Wow = ''; Want = 'amd64' }, @{ Arch = 'ARM64'; Wow = ''; Want = 'arm64' }, @{ Arch = 'x86'; Wow = 'AMD64'; Want = 'amd64' }, @{ Arch = 'x86'; Wow = 'ARM64'; Want = 'arm64' }
    ) {
        param($Arch, $Wow, $Want)
        $saved = $env:PROCESSOR_ARCHITECTURE
        try {
            $env:PROCESSOR_ARCHITECTURE = $Arch
            if ($Wow) { $env:PROCESSOR_ARCHITEW6432 = $Wow } else { Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue }
            Get-RunnerArchitecture | Should -Be $Want
        } finally { $env:PROCESSOR_ARCHITECTURE = $saved }
    }

    It 'refuses another architecture' {
        $saved = $env:PROCESSOR_ARCHITECTURE
        try {
            Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue
            $env:PROCESSOR_ARCHITECTURE = 'x86'
            { Get-RunnerArchitecture } | Should -Throw "*unsupported architecture 'x86'*"
        } finally { $env:PROCESSOR_ARCHITECTURE = $saved }
    }

    It 'names the tarball, the proxy binary and portable Git of the architecture' {
        try {
            Initialize-Architecture 'arm64'
            $script:Tarball | Should -Be 'circleci-runner_windows_arm64.tar.gz'
            $script:ProxyAsset | Should -Be 'machine-runner-swarm-proxy_windows_arm64'
            $script:GitAsset | Should -Be 'PortableGit-2.56.0.2-arm64.7z.exe'
            Initialize-Architecture 'amd64'
            $script:Tarball | Should -Be 'circleci-runner_windows_amd64.tar.gz'
            $script:GitAsset | Should -Be 'PortableGit-2.56.0.2-64-bit.7z.exe'
        } finally { Initialize-Architecture 'amd64' }
    }
}

Describe 'Resolve-Runner' {
    BeforeEach {
        Use-DistributorEnvironment @{ RUNNER_VERSION = 'current' }
        $script:downloads = 0
        Mock Save-Url { $script:downloads++; [IO.File]::WriteAllText($OutFile, $script:manifestJson); return $true }
        Mock Find-Runner { return $null }
        Mock Write-DistributorLog { }
    }

    It 'resolves current to the highest versioned release that has its SHA-256, within the major version' {
        $r = Resolve-Runner (Get-DistributorSetting)
        $r.Version | Should -Be '3.1.10'
        @($r.Accept) | Should -Be @('c' * 64)
    }

    It 'does not adopt a current of another major version' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = 'current'; RUNNER_MAJOR = '4' }
        (Resolve-Runner (Get-DistributorSetting)).Version | Should -Be ''
        Use-DistributorEnvironment @{ RUNNER_VERSION = 'current'; RUNNER_MAJOR = '2' }
        (Resolve-Runner (Get-DistributorSetting)).Version | Should -Be ''
    }

    It 'takes the SHA-256 of the architecture of the host: arm64 has its own builds' {
        try {
            Initialize-Architecture 'arm64'
            $r = Resolve-Runner (Get-DistributorSetting)
            $r.Version | Should -Be '3.1.10'
            @($r.Accept) | Should -Be @('1' * 64)
        } finally { Initialize-Architecture 'amd64' }
    }

    It 'resolves 3.1 to the newest 3.1.x, whatever current and a newer line say' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1' }
        $r = Resolve-Runner (Get-DistributorSetting)
        $r.Version | Should -Be '3.1.10'
        @($r.Accept) | Should -Be @('c' * 64)
    }

    It 'resolves 3 to the newest 3.x.y, and never a 4.x' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3' }
        $r = Resolve-Runner (Get-DistributorSetting)
        $r.Version | Should -Be '3.2.0'
        @($r.Accept) | Should -Be @('e' * 64)
    }

    It 'resolves a floating line with an explicit SHA-256 list, and gives up on a line that the manifest does not have' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1'; RUNNER_SHA256 = ('f' * 64) }
        $r = Resolve-Runner (Get-DistributorSetting)
        $r.Version | Should -Be '3.1.10'
        @($r.Accept) | Should -Be @('f' * 64)
        Use-DistributorEnvironment @{ RUNNER_VERSION = '5' }
        Resolve-Runner (Get-DistributorSetting) | Should -BeNullOrEmpty
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.3' }
        Resolve-Runner (Get-DistributorSetting) | Should -BeNullOrEmpty
    }

    It 'takes the SHA-256 of a pinned version from the manifest' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.2' }
        $r = Resolve-Runner (Get-DistributorSetting)
        $r.Version | Should -Be '3.1.2'
        @($r.Accept) | Should -Be @('b' * 64)
    }

    It 'needs no manifest for a pinned version with an explicit SHA-256, and the explicit value wins over the manifest' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.2'; RUNNER_SHA256 = ('e' * 64) }
        $r = Resolve-Runner (Get-DistributorSetting)
        @($r.Accept) | Should -Be @('e' * 64)
        $script:downloads | Should -Be 0
    }

    It 'switches to an installed version without the manifest, so that a rollback works offline' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.2' }
        Mock Find-Runner { return '3.1.2' }
        $r = Resolve-Runner (Get-DistributorSetting)
        $r.Version | Should -Be '3.1.2'
        $script:downloads | Should -Be 0
    }

    It 'gives up on a version that the manifest does not list, and when the manifest cannot be downloaded' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '9.9.9' }
        Resolve-Runner (Get-DistributorSetting) | Should -BeNullOrEmpty
        Use-DistributorEnvironment @{ RUNNER_VERSION = 'current' }
        Mock Save-Url { return $false }
        Resolve-Runner (Get-DistributorSetting) | Should -BeNullOrEmpty
    }
}

Describe 'Get-LatestProxyVersion' {
    BeforeEach {
        Mock Write-DistributorLog { }
    }

    It 'reads the tag of the latest release and drops the v' {
        Mock Save-Url { [IO.File]::WriteAllText($OutFile, '{ "url": "u", "tag_name": "v0.3.0", "draft": false }'); return $true }
        Get-LatestProxyVersion 'https://mirror.example.com/latest.json' | Should -Be '0.3.0'
    }

    It 'says that no release is published, in words, when the URL answers with an error' {
        Mock Save-Url { return $false }
        Get-LatestProxyVersion 'https://mirror.example.com/latest.json' | Should -BeNullOrEmpty
        Should -Invoke Write-DistributorLog -ParameterFilter { $Message -like '*unreleased (a checkout of this repository), which means its latest published release*published no release yet*' }
    }

    It 'refuses an answer that is not JSON, and one without a tag of the form v0.3.0' -TestCases @(@{ Body = 'not json' }, @{ Body = '{ "tag_name": "nightly" }' }, @{ Body = '{ "name": "x" }' }) {
        param($Body)
        $script:body = $Body
        Mock Save-Url { [IO.File]::WriteAllText($OutFile, $script:body); return $true }
        Get-LatestProxyVersion 'https://mirror.example.com/latest.json' | Should -BeNullOrEmpty
    }
}

Describe 'Get-RecentRunner' {
    It 'lists the last distinct directories that current pointed to, most recent first' {
        New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'history') -Value @('2026-01-01T00:00:00Z 1.0.0', '2026-01-02T00:00:00Z 1.1.0', '2026-01-03T00:00:00Z 1.0.0', '2026-01-04T00:00:00Z 1.2.0', '2026-01-05T00:00:00Z 1.3.0')
        @(Get-RecentRunner -Count 3) | Should -Be @('1.3.0', '1.2.0', '1.0.0')
    }
}

Describe 'Test-InUse' {
    It 'finds a program that a process holds, and no other directory' {
        $dir = Join-Path $TestDrive 'version'
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'bin') | Out-Null
        $exe = Join-Path $dir 'bin\circleci-runner.exe'
        Set-Content -LiteralPath $exe -Value 'x'
        Test-InUse $dir | Should -BeFalse
        $held = [IO.File]::Open($exe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { Test-InUse $dir | Should -BeTrue } finally { $held.Dispose() }
        Test-InUse $dir | Should -BeFalse
    }
}
