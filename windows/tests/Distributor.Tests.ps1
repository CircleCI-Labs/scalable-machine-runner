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
        foreach ($n in 'RUNNER_VERSION', 'RUNNER_MAJOR', 'CHECK_INTERVAL', 'DOWNLOAD_BASE_URL', 'RUNNER_SHA256', 'ALLOW_HTTP', 'TOOLS_BASE_URL') { Remove-Item "Env:MACHINE_RUNNER_SWARM_$n" -ErrorAction SilentlyContinue }
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

    It 'reads the word manifest as no list, so that the hash of the manifest is trusted for an exact pin' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; RUNNER_SHA256 = 'manifest' }
        @((Get-DistributorSetting).Hashes).Count | Should -Be 0
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; RUNNER_SHA256 = 'Manifest' }
        @((Get-DistributorSetting).Hashes).Count | Should -Be 0
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; RUNNER_SHA256 = ('a' * 64) + ',manifest' }
        { Get-DistributorSetting } | Should -Throw '*not a SHA-256*'
    }

    It 'ignores a SHA-256 list for a floating value, so the hash comes from the manifest' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1'; RUNNER_SHA256 = ('a' * 64) }
        @((Get-DistributorSetting).Hashes).Count | Should -Be 0
    }

    It 'wants an https download base, unless a SHA-256 list is set for an exact pin (or http is allowed on purpose)' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; DOWNLOAD_BASE_URL = 'http://mirror.example.com/runner' }
        { Get-DistributorSetting } | Should -Throw '*must be https://*'
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1'; RUNNER_SHA256 = ('a' * 64); DOWNLOAD_BASE_URL = 'http://mirror.example.com/runner' }
        { Get-DistributorSetting } | Should -Throw '*must be https://*'
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; RUNNER_SHA256 = ('a' * 64); DOWNLOAD_BASE_URL = 'http://mirror.example.com/runner' }
        (Get-DistributorSetting).Base | Should -Be 'http://mirror.example.com/runner'
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1'; ALLOW_HTTP = 'true'; DOWNLOAD_BASE_URL = 'http://mirror.example.com/runner' }
        (Get-DistributorSetting).Base | Should -Be 'http://mirror.example.com/runner'
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1.13'; RUNNER_SHA256 = ('a' * 64); DOWNLOAD_BASE_URL = 'ftp://mirror.example.com/runner' }
        { Get-DistributorSetting } | Should -Throw '*must be an https:// URL*'
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

    It 'names the tarball and portable Git of the architecture' {
        try {
            Initialize-Architecture 'arm64'
            $script:Tarball | Should -Be 'circleci-runner_windows_arm64.tar.gz'
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

    It 'resolves a floating line from the manifest even when a SHA-256 list is set, and gives up on a line that the manifest does not have' {
        Use-DistributorEnvironment @{ RUNNER_VERSION = '3.1'; RUNNER_SHA256 = ('f' * 64) }
        $r = Resolve-Runner (Get-DistributorSetting)
        $r.Version | Should -Be '3.1.10'
        @($r.Accept) | Should -Be @('c' * 64)
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
