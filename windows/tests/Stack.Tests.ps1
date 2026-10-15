# Pester 5+ checks of windows/stack/*.yaml: the invariants of the no-entrypoint design and of the runner distributor. Plain text checks, so they
# run without Docker or a YAML module; "docker stack config" does the schema check in CI.

BeforeAll {
    $script:stackDir = Join-Path $PSScriptRoot '..\stack'
    $script:files = @{}
    $script:blocks = @{}      # service name -> its text
    $script:fileOf = @{}      # service name -> file name
    foreach ($name in 'runners.yaml', 'custom-image.yaml', 'persistent.yaml', 'docker-build.yaml', 'ssh-rerun.yaml') {
        $text = Get-Content -LiteralPath (Join-Path $script:stackDir $name) -Raw
        $script:files[$name] = $text
        # One block per service: from "  <name>:" under services: to the next service or the top-level key after them.
        $start = $text.IndexOf("`nservices:")
        $end = $text.Length
        foreach ($next in "`nvolumes:", "`nsecrets:", "`nconfigs:") { $i = $text.IndexOf($next, $start); if ($i -gt 0 -and $i -lt $end) { $end = $i + 1 } }
        $services = $text.Substring($start, $end - $start)
        foreach ($m in [regex]::Matches($services, '(?ms)^  (windows-[a-z-]+):\r?\n(.*?)(?=^  [a-z][a-z-]+:|\z)')) {
            $script:blocks[$m.Groups[1].Value] = $m.Groups[2].Value
            $script:fileOf[$m.Groups[1].Value] = $name
        }
    }
    $script:allText = ($script:files.Values -join "`n")
    $script:stockServices = @('windows-default', 'windows-custom', 'windows-persistent', 'windows-docker-build', 'windows-default-ssh')
}

Describe 'the stack files' {
    It 'split the classes: runners.yaml holds only windows-default and deploys alone, the optional ones are separate add-on stack files' {
        ($script:blocks.Keys | Sort-Object) | Should -Be @('windows-custom', 'windows-default', 'windows-default-ssh', 'windows-docker-build', 'windows-persistent')
        $script:fileOf['windows-default'] | Should -Be 'runners.yaml'
        @($script:fileOf.Keys | Where-Object { $script:fileOf[$_] -eq 'runners.yaml' }) | Should -Be @('windows-default')
        $script:files['runners.yaml'] | Should -Not -Match 'windows-custom|registry\.example\.com'
        $script:fileOf['windows-custom'] | Should -Be 'custom-image.yaml'
        $script:fileOf['windows-persistent'] | Should -Be 'persistent.yaml'
        $script:fileOf['windows-docker-build'] | Should -Be 'docker-build.yaml'
        $script:fileOf['windows-default-ssh'] | Should -Be 'ssh-rerun.yaml'
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
        $script:files['persistent.yaml'] | Should -Match '(?m)^volumes:\r?\n(  .*\r?\n)*?  windows-persistent-cache: \{\}'
    }

    It 'declare every secret they use, as external, in the same file' {
        foreach ($s in $script:blocks.Keys) {
            $text = $script:files[$script:fileOf[$s]]
            $text | Should -Match "(?m)^  $s-token:\r?\n    external: true"
            if ($s -eq 'windows-persistent') {
                # a continuous runner claims after every job, so it keeps its own token and does not use the proxy
                $script:blocks[$s] | Should -Match "(?m)^      - source: $s-token\r?\n        target: circleci_runner_config\.yaml"
                $script:blocks[$s] | Should -Not -Match 'token-proxy'
            } else {
                # the runner reads a made-up token; the class token is in the proxy only
                $text | Should -Match '(?m)^  runner-placeholder-token:\r?\n    external: true'
                $script:blocks[$s] | Should -Match "(?m)^      - source: runner-placeholder-token[^\r\n]*\r?\n        target: circleci_runner_config\.yaml"
                $script:blocks[$s] | Should -Not -Match "source: $s-token"
            }
        }
    }

    It 'send the API calls of every proxied class to the token proxy, and the persistent class straight to CircleCI' {
        foreach ($s in $script:blocks.Keys) {
            $text = $script:files[$script:fileOf[$s]]
            if ($s -eq 'windows-persistent') { $text | Should -Not -Match 'CIRCLECI_RUNNER_API_URL' }
            else { $text | Should -Match '(?m)^  CIRCLECI_RUNNER_API_URL: http://token-proxy-windows:8080' }
        }
    }

    It 'run the token proxy from its image as one replica with dnsrr, with its state in a named volume, on a manager by default' {
        $proxy = [regex]::Match($script:files['runners.yaml'], '(?ms)^  token-proxy-windows:\r?\n(.*?)(?=^[a-z])').Groups[1].Value
        $proxy | Should -Not -BeNullOrEmpty
        $proxy | Should -Match '(?m)^    image: \$\{MACHINE_RUNNER_SWARM_PROXY_IMAGE:-ccilabs/machine-runner-swarm-proxy:latest\}'
        $proxy | Should -Not -Match 'runner-bin|subpath|entrypoint' -Because 'the image is the program: nothing comes from the volume of the distributor'
        $proxy | Should -Not -Match 'windows-ltsc20' -Because 'one tag covers both Windows versions, and Docker picks the image of the node'
        $proxy | Should -Match '(?m)^      replicas: 1'
        $proxy | Should -Match '(?m)^      endpoint_mode: dnsrr'
        $proxy | Should -Match '(?m)^        source: proxy-state'
        $proxy | Should -Match "(?m)^      - -state-dir\r?\n      - 'C:\\proxy-state'"
        $proxy | Should -Match "(?m)^      test: \['CMD', 'C:\\machine-runner-swarm-proxy\.exe', '-healthcheck'\]"
        $proxy | Should -Match '(?m)^          - "\$\{MACHINE_RUNNER_SWARM_PROXY_PLACEMENT:-node\.role == manager\}"'
        $proxy | Should -Not -Match 'machine-runner-swarm\.proxy ==' -Because 'a manager is the default and needs no label'
        $proxy | Should -Match '(?m)^          - node\.labels\.machine-runner-swarm\.docker-build != true'
        $proxy | Should -Match '(?m)^    healthcheck:'
        $script:files['runners.yaml'] | Should -Match '(?m)^volumes:\r?\n(  .*\r?\n)*?  proxy-state: \{\}'
        # the class tokens are the secrets of the proxy only: the proxy takes a class for every secret <service>-token that it holds
        $proxy | Should -Match '(?m)^      - source: windows-default-token\r?\n        target: windows-default-token'
        $proxy | Should -Not -Match 'MACHINE_RUNNER_SWARM_PROXY_CLASS_|(?m)^    environment:|runner-placeholder' -Because 'a class is a secret <service>-token of the proxy, and nothing else'
        $proxy | Should -Match '(?m)^      start_period: (?:[4-9][0-9]|[0-9]{3,})s' -Because 'a start probes CircleCI for up to 25 s before the proxy listens'
    }

    It 'add the class of an add-on stack file to the token proxy with its secret and nothing else' {
        foreach ($c in @(@('custom-image.yaml', 'windows-custom'), @('docker-build.yaml', 'windows-docker-build'), @('ssh-rerun.yaml', 'windows-default-ssh'))) {
            $text = $script:files[$c[0]]
            $text | Should -Match '(?m)^  token-proxy-windows:'
            $text | Should -Not -Match 'MACHINE_RUNNER_SWARM_PROXY_CLASS_'
            $text | Should -Match "(?m)^      - source: $($c[1])-token\r?\n        target: $($c[1])-token"
        }
        $script:files['persistent.yaml'] | Should -Not -Match 'token-proxy-windows:'
    }

    It 'name the proxy image by a variable, and give the distributor and the runner services no proxy setting' {
        $text = $script:files['runners.yaml']
        $text | Should -Not -Match 'PROXY_VERSION|PROXY_BASE_URL|PROXY_LATEST_URL|PROXY_SHA256|PROXY_NO_STATE' -Because 'the proxy is an image, not a download of the distributor'
        foreach ($s in $script:blocks.Keys) { $script:blocks[$s] | Should -Not -Match 'PROXY_IMAGE' }
    }

    It 'have no entrypoint script in a runner service: the runner is the main process' {
        $script:allText | Should -Not -Match 'circleci-runner-entrypoint'
        foreach ($s in $script:blocks.Keys) { $script:blocks[$s] | Should -Not -Match 'powershell\.exe' }
    }

    It 'run circleci-runner.exe directly with --config on the secret, from the stock anchor in each file' {
        foreach ($name in 'runners.yaml', 'custom-image.yaml', 'persistent.yaml', 'docker-build.yaml', 'ssh-rerun.yaml') {
            $script:files[$name] | Should -Match "(?m)^x-stock: &stock\r?\n  entrypoint: \['C:\\machine-runner-swarm\\bin\\circleci-runner\.exe', machine, '--config', 'C:\\ProgramData\\Docker\\secrets\\circleci_runner_config\.yaml'\]"
        }
        foreach ($s in $script:stockServices) { $script:blocks[$s] | Should -Match '<<: \[\*runner, \*stock\]' }
    }

    It 'mount the volume runner-bin read-only twice, through links that Docker resolves when it creates the container: current at C:\machine-runner-swarm and Git at the path the task agent hard-codes' -TestCases @(
        @{ Service = 'windows-default' }, @{ Service = 'windows-custom' }, @{ Service = 'windows-persistent' }, @{ Service = 'windows-docker-build' }, @{ Service = 'windows-default-ssh' }
    ) {
        param($Service)
        $script:blocks[$Service] | Should -Match '- \*runner-mount\r?\n      - \*git-mount'
        $text = $script:files[$script:fileOf[$Service]]
        $text | Should -Match "(?m)^x-runner-mount: &runner-mount.*\r?\n  type: volume\r?\n  source: runner-bin.*\r?\n  target: 'C:\\machine-runner-swarm'.*\r?\n  read_only: true\r?\n  volume:\r?\n    subpath: current\b"
        $text | Should -Match "(?m)^x-git-mount: &git-mount.*\r?\n  type: volume\r?\n  source: runner-bin.*\r?\n  target: 'C:\\Program Files\\Git'.*\r?\n  read_only: true\r?\n  volume:\r?\n    subpath: 'git\\current'"
        $text | Should -Match '(?m)^volumes:\r?\n(  .*\r?\n)*?  runner-bin: \{\}' -Because 'every file also deploys alone'
    }

    It 'carry no runner version, hash or mirror in a runner service: an upgrade changes the distributor only, so no runner restarts' {
        foreach ($s in $script:blocks.Keys) {
            $script:blocks[$s] | Should -Not -Match 'MACHINE_RUNNER_SWARM_(RUNNER_VERSION|RUNNER_SHA256|DOWNLOAD_BASE_URL|TOOLS_BASE_URL|CHECK_INTERVAL)'
        }
    }

    It 'run the distributor as a global service of runners.yaml: stock Server Core, its script a Swarm config named after its content, the volume read-write' {
        $text = $script:files['runners.yaml']
        $text | Should -Match '(?ms)^  runner-distributor-windows:\r?\n.*?image: mcr\.microsoft\.com/windows/servercore:ltsc2022.*\r?\n'
        $text | Should -Match '(?ms)^  runner-distributor-windows:.*?isolation: process'
        $text | Should -Match '(?ms)^  runner-distributor-windows:.*?mode: global'
        $text | Should -Match '(?ms)^  runner-distributor-windows:.*?node\.platform\.os == windows'
        $text | Should -Match '(?ms)^  runner-distributor-windows:.*?node\.labels\.machine-runner-swarm\.windows-ltsc2022 == true'
        $text | Should -Match '(?ms)^  runner-distributor-windows:.*?- type: volume\r?\n        source: runner-bin\r?\n        target: ''C:\\runner-bin''.*\r?\n(?!        read_only)'
        $text | Should -Match '(?m)^  distributor-windows: \{name: machine-runner-swarm-distributor-windows-[0-9a-f]{12}, file: runner-distributor\.ps1\}'
        foreach ($v in 'MACHINE_RUNNER_SWARM_RUNNER_VERSION: ${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-3.1.13}', 'MACHINE_RUNNER_SWARM_RUNNER_MAJOR: ${MACHINE_RUNNER_SWARM_RUNNER_MAJOR:-3}', 'MACHINE_RUNNER_SWARM_CHECK_INTERVAL: ${MACHINE_RUNNER_SWARM_CHECK_INTERVAL:-24h}') {
            $text | Should -Match ([regex]::Escape($v))
        }
        # no other file defines a second distributor
        foreach ($name in 'custom-image.yaml', 'persistent.yaml', 'docker-build.yaml', 'ssh-rerun.yaml') { $script:files[$name] | Should -Not -Match '(?m)^  runner-distributor' -Because 'the distributor is part of the base stack file' }
    }

    It 'spell out PATH for stock services: Windows first, then Git cmd, usr\bin and ucrt64\bin' {
        $paths = [regex]::Matches($script:allText, "(?m)^\s+PATH: '([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        @($paths).Count | Should -Be 6   # runners.yaml, custom-image.yaml, persistent.yaml, ssh-rerun.yaml, docker-build.yaml (twice: the anchor and the override with C:\docker)
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
        foreach ($s in 'windows-default', 'windows-custom', 'windows-docker-build', 'windows-default-ssh') { $script:blocks[$s] | Should -Match 'CIRCLECI_RUNNER_IDLE_TIMEOUT: 1h' }
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
        # The capability label of the image's tag: a 2022 and a 2025 host both carry windows-ltsc2022, so ltsc2022 images run on both.
        foreach ($s in $script:blocks.Keys) { $script:blocks[$s] | Should -Match 'node\.labels\.machine-runner-swarm\.windows-ltsc2022 == true' }
        $script:allText | Should -Not -Match 'windows-build'
        $script:blocks['windows-docker-build'] | Should -Match 'node\.labels\.machine-runner-swarm\.docker-build == true'
        $script:blocks['windows-docker-build'] | Should -Not -Match 'docker-build !='
        # The engine pipe lets a job create a service that mounts every secret of the swarm: never on a manager (also not on a single-node swarm).
        $script:blocks['windows-docker-build'] | Should -Match '(?m)^          - node\.role == worker\b'
        $script:blocks['windows-persistent'] | Should -Match 'node\.labels\.machine-runner-swarm\.class\.windows-persistent == true'
        $script:blocks['windows-docker-build'] | Should -Match ([regex]::Escape('type: npipe') + '\r?\n        ' + [regex]::Escape("source: '\\.\pipe\docker_engine'"))
    }

    It 'keep every class except the Docker-build one off Docker-build nodes (a missing label also matches !=)' {
        foreach ($s in @($script:blocks.Keys | Where-Object { $_ -ne 'windows-docker-build' })) {
            $script:blocks[$s] | Should -Match 'node\.labels\.machine-runner-swarm\.docker-build != true'
        }
    }

    It 'publish the SSH rerun port only in the SSH add-on: host mode, one replica per node, the node name advertised' {
        $b = $script:blocks['windows-default-ssh']
        $b | Should -Match '(?m)^    ports:\r?\n      - target: 54782\r?\n        published: 54782\r?\n        protocol: tcp\r?\n        mode: host'
        $b | Should -Not -Match 'mode: ingress'
        $b | Should -Match '(?m)^        max_replicas_per_node: 1\b'
        $b | Should -Match '(?m)^      CIRCLECI_RUNNER_SSH_ADVERTISE_ADDR: "\{\{\.Node\.Hostname\}\}:54782"'
        $script:files['runners.yaml'] | Should -Match '(?m)^  endpoint_mode: dnsrr' -Because 'an ingress port cannot be used with dnsrr, so the SSH port must stay in host mode'
        foreach ($s in @($script:blocks.Keys | Where-Object { $_ -ne 'windows-default-ssh' })) {
            $script:blocks[$s] | Should -Not -Match '(?m)^    ports:|SSH_ADVERTISE_ADDR|max_replicas_per_node' -Because "$s is not the SSH add-on"
        }
    }

    It 'keep windows-default-ssh the same as windows-default apart from the SSH settings and the replica count' {
        $ssh = $script:blocks['windows-default-ssh']
        $default = $script:blocks['windows-default']
        foreach ($pattern in '<<: \[\*runner, \*stock\]', '<<: \[\*runner-env, \*stock-env\]', '<<: \*runner-deploy', '- \*runner-mount\r?\n      - \*git-mount') {
            $ssh | Should -Match $pattern
        }
        $image = { param($x) [regex]::Match($x, '(?m)^    image: (\S+)').Groups[1].Value }
        (& $image $ssh) | Should -Be (& $image $default)
        $resources = { param($x) @([regex]::Matches($x, '(?m)^        (limits|reservations): (\{[^}]*\})') | ForEach-Object { $_.Value }) }
        @(& $resources $default).Count | Should -Be 2
        (& $resources $ssh) | Should -Be (& $resources $default)
        $constraints = { param($x) @([regex]::Matches($x, '(?m)^          - (node\..+?)\s*(#.*)?$') | ForEach-Object { $_.Groups[1].Value.TrimEnd() }) }
        (& $constraints $ssh) | Should -Be (& $constraints $default)
        $ssh | Should -Match '(?m)^          - spread: node\.id'
    }

    It 'use nothing the Windows engine rejects' {
        $script:allText | Should -Not -Match '(?m)^\s+(pids|ulimits|cap_drop|read_only: true\r?\n\s+init|tmpfs):'
        $script:allText | Should -Not -Match '(?m)^\s+hostname:'
    }
}
