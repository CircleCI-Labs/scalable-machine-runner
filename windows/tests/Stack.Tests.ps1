# Pester 5+ checks of windows/stack/*.yaml: the invariants of the no-entrypoint design. Plain text checks, so they
# run without Docker or a YAML module; "docker stack config" does the schema check in CI.

BeforeAll {
    $script:stackDir = Join-Path $PSScriptRoot '..\stack'
    $script:files = @{}
    $script:blocks = @{}      # service name -> its text
    $script:fileOf = @{}      # service name -> file name
    foreach ($name in 'runners.yaml', 'custom-image.yaml', 'persistent.yaml', 'docker-build.yaml') {
        $text = Get-Content -LiteralPath (Join-Path $script:stackDir $name) -Raw
        $script:files[$name] = $text
        # One block per service: from "  <name>:" under services: to the next service or the top-level key after them.
        $start = $text.IndexOf("`nservices:")
        $end = $text.Length
        foreach ($next in "`nvolumes:", "`nsecrets:") { $i = $text.IndexOf($next, $start); if ($i -gt 0 -and $i -lt $end) { $end = $i + 1 } }
        $services = $text.Substring($start, $end - $start)
        foreach ($m in [regex]::Matches($services, '(?ms)^  (windows-[a-z-]+):\r?\n(.*?)(?=^  windows-[a-z-]+:|\z)')) {
            $script:blocks[$m.Groups[1].Value] = $m.Groups[2].Value
            $script:fileOf[$m.Groups[1].Value] = $name
        }
    }
    $script:allText = ($script:files.Values -join "`n")
    $script:stockServices = @('windows-default', 'windows-custom', 'windows-persistent', 'windows-docker-build')
}

Describe 'the stack files' {
    It 'split the classes: runners.yaml holds only windows-default and deploys alone, the optional ones are separate overlays' {
        ($script:blocks.Keys | Sort-Object) | Should -Be @('windows-custom', 'windows-default', 'windows-docker-build', 'windows-persistent')
        $script:fileOf['windows-default'] | Should -Be 'runners.yaml'
        @($script:fileOf.Keys | Where-Object { $script:fileOf[$_] -eq 'runners.yaml' }) | Should -Be @('windows-default')
        $script:files['runners.yaml'] | Should -Not -Match 'windows-custom|registry\.example\.com'
        $script:fileOf['windows-custom'] | Should -Be 'custom-image.yaml'
        $script:fileOf['windows-persistent'] | Should -Be 'persistent.yaml'
        $script:fileOf['windows-docker-build'] | Should -Be 'docker-build.yaml'
    }

    It 'declare every named volume they use (docker stack deploy fails with "undefined volume" otherwise)' {
        foreach ($name in $script:files.Keys) {
            $text = $script:files[$name]
            $used = @([regex]::Matches($text, "(?m)^\s+- type: volume\r?\n\s+source: ([A-Za-z0-9_.-]+)") | ForEach-Object { $_.Groups[1].Value })
            $declared = @()
            if ($text -match '(?ms)^volumes:\r?\n((?:  .*\r?\n?)+)') {
                $declared = @([regex]::Matches($Matches[1], '(?m)^  ([A-Za-z0-9_.-]+):') | ForEach-Object { $_.Groups[1].Value })
            }
            foreach ($v in $used) { $declared | Should -Contain $v -Because "$name uses volume $v" }
        }
        $script:files['persistent.yaml'] | Should -Match '(?m)^volumes:\r?\n  windows-persistent-cache: \{\}'
    }

    It 'declare every secret they use, as external, in the same file' {
        foreach ($s in $script:blocks.Keys) {
            $text = $script:files[$script:fileOf[$s]]
            $text | Should -Match "(?m)^  $s-token:\r?\n    external: true"
            $script:blocks[$s] | Should -Match "(?m)^      - source: $s-token\r?\n        target: circleci_runner_config\.yaml"
        }
    }

    It 'have no entrypoint script anywhere' {
        $script:allText | Should -Not -Match 'circleci-runner-entrypoint'
        $script:allText | Should -Not -Match 'powershell\.exe'
    }

    It 'run circleci-runner.exe directly with --config on the secret, from the stock anchor in each file' {
        foreach ($name in 'runners.yaml', 'custom-image.yaml', 'persistent.yaml', 'docker-build.yaml') {
            $script:files[$name] | Should -Match "(?m)^x-stock: &stock\r?\n  entrypoint: \['C:\\machine-runner-swarm\\bin\\circleci-runner\.exe', machine, '--config', 'C:\\ProgramData\\Docker\\secrets\\circleci_runner_config\.yaml'\]"
        }
        foreach ($s in $script:stockServices) { $script:blocks[$s] | Should -Match '<<: \[\*runner, \*stock\]' }
    }

    It 'mount the junction current of the installed version read-only, Git at the path the task agent hard-codes' -TestCases @(
        @{ Service = 'windows-default' }, @{ Service = 'windows-custom' }, @{ Service = 'windows-persistent' }, @{ Service = 'windows-docker-build' }
    ) {
        param($Service)
        $script:blocks[$Service] | Should -Match '- \*runner-mount\r?\n      - \*git-mount'
        $script:files[$script:fileOf[$Service]] | Should -Match "(?m)^x-runner-mount: &runner-mount.*\r?\n  type: bind\r?\n  source: 'C:\\machine-runner-swarm\\current'"
        $script:files[$script:fileOf[$Service]] | Should -Match "(?m)^x-git-mount: &git-mount.*\r?\n  type: bind\r?\n  source: 'C:\\machine-runner-swarm\\current\\git'\r?\n  target: 'C:\\Program Files\\Git'\r?\n  read_only: true"
    }

    It 'spell out PATH for stock services: Windows first, then Git cmd, usr\bin and ucrt64\bin' {
        $paths = [regex]::Matches($script:allText, "(?m)^\s+PATH: '([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        @($paths).Count | Should -Be 5   # runners.yaml, custom-image.yaml, persistent.yaml, docker-build.yaml (twice: the anchor and the override with C:\docker)
        foreach ($p in $paths) {
            $entries = $p -split ';'
            foreach ($sys in 'C:\Windows\system32', 'C:\Windows', 'C:\Windows\System32\WindowsPowerShell\v1.0\') { $entries | Should -Contain $sys }
            ($entries.IndexOf('C:\Windows\system32')) | Should -BeLessThan ($entries.IndexOf('C:\Program Files\Git\usr\bin'))
            foreach ($g in 'cmd', 'ucrt64\bin', 'usr\bin') { $entries | Should -Contain "C:\Program Files\Git\$g" }
        }
        @($paths | Where-Object { $_ -match ';C:\\docker$' }).Count | Should -Be 1
    }

    It 'give every runner its own name, and an idle timeout only in single-task mode' {
        foreach ($s in $script:blocks.Keys) {
            $script:blocks[$s] | Should -Match "CIRCLECI_RUNNER_NAME: `"\{\{\.Node\.Hostname\}\}-$s-\{\{\.Task\.Slot\}\}`""
        }
        $script:blocks['windows-persistent'] | Should -Match 'CIRCLECI_RUNNER_MODE: continuous'
        $script:blocks['windows-persistent'] | Should -Not -Match 'IDLE_TIMEOUT'
        foreach ($s in 'windows-default', 'windows-custom', 'windows-docker-build') { $script:blocks[$s] | Should -Match 'CIRCLECI_RUNNER_IDLE_TIMEOUT: 1h' }
    }

    It 'restart every exit in a new container, one at a time, with the long grace period' {
        foreach ($name in $script:files.Keys) {
            $script:files[$name] | Should -Match '(?ms)restart_policy:\r?\n    condition: any[^\n]*\n    delay: 10s'
            $script:files[$name] | Should -Match '(?ms)update_config:\r?\n    order: stop-first\r?\n    parallelism: 1'
            $script:files[$name] | Should -Match 'stop_grace_period: 5h5m'
            $script:files[$name] | Should -Match 'isolation: process'
        }
    }

    It 'place classes on the matching Windows build, and the optional ones only on labelled nodes' {
        foreach ($s in $script:blocks.Keys) { $script:blocks[$s] | Should -Match 'node\.platform\.os == windows' }
        foreach ($s in $script:blocks.Keys) { $script:blocks[$s] | Should -Match 'node\.labels\.machine-runner-swarm\.windows-build == ltsc2022' }
        $script:blocks['windows-docker-build'] | Should -Match 'node\.labels\.machine-runner-swarm\.docker-build == true'
        $script:blocks['windows-persistent'] | Should -Match 'node\.labels\.machine-runner-swarm\.class\.windows-persistent == true'
        $script:blocks['windows-docker-build'] | Should -Match ([regex]::Escape('type: npipe') + '\r?\n        ' + [regex]::Escape("source: '\\.\pipe\docker_engine'"))
    }

    It 'use nothing the Windows engine rejects' {
        $script:allText | Should -Not -Match '(?m)^\s+(pids|ulimits|cap_drop|read_only: true\r?\n\s+init|tmpfs):'
        $script:allText | Should -Not -Match '(?m)^\s+hostname:'
    }
}
