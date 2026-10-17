---
page-title: Install on Windows Server with Docker Swarm
page-audience: admin
page-description: Deploy CircleCI machine runner 3 as a Docker Swarm stack on Windows Server 2022 or 2025, with one clean container for every job.
---

# Install on Windows Server with Docker Swarm

This page deploys CircleCI machine runner 3 as a Docker Swarm stack on Windows Server. Every job runs in a new Windows Server Core container, and Swarm replaces the container after the job. The steps cover one host ([Multi-node clusters](multi-node.md) adds more). For a first run, [Quickstart on Windows Server](quickstart-windows.md) is shorter.

> [!NOTE]
> If you can run Kubernetes, CircleCI recommends [container runner](https://circleci.com/docs/guides/execution-runner/container-runner-installation/) for containerized jobs. This page is for teams that run Docker Swarm and need a clean Windows container for every job.

**Status.** This is a CircleCI Labs project, `0.x`, and CircleCI support does not cover it. It is tested against CircleCI cloud only: [What is tested](../README.md#what-is-tested) says how. Replicas are fixed: the stack does not add or remove nodes, and it does not scale to the queue.

The steps: start or join a swarm, label the node, create the secrets, deploy. The optional [setup helper](#optional-use-the-setup-helper) runs most of them.

> [!IMPORTANT]
> The services run the stock Server Core image, and no image is built. Stopping a busy container from outside kills its job after about 5 seconds, so change a Windows class while it is idle ([Stop a busy Windows container](operations.md#stop-a-busy-windows-container)).

## Prerequisites

- A CircleCI cloud organization and a user who is an organization admin. CircleCI server is not tested: [CircleCI server](security.md#circleci-server) says what is known.
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, signed in. It can run on your workstation. Pass `--org <ORG>` (a slug such as `gh/my-org`, or a UUID): without it the CLI uses the organization of the git remote of the current directory, which in a clone of this repository is not yours.
- One or more Windows Server hosts (table below). The host cannot be a domain controller.
- Docker Engine 28.0 or later (CLI and engine), in Windows-container mode, with the Windows Containers feature (enabling it restarts the host). The stack files mount a subpath of a volume (`current` and `git\current`), which older CLIs and engines ignore: the runner would not start. CI runs Docker 29.4.0 on Windows, and `windows\Setup.ps1` checks the version. The `Install-DockerCE` script in the `helpful_tools` directory of the [Microsoft Windows Containers repository](https://github.com/microsoft/Windows-Containers) installs both.
- An elevated Windows PowerShell 5.1 session.
- A host clock synchronized with NTP. TLS to CircleCI fails silently when the clock drifts.
- Outbound HTTPS from each host to the hosts in [Egress hosts](security.md#egress-hosts): `circleci-binary-releases.s3.amazonaws.com` (the runner and its manifest), `github.com` and `release-assets.githubusercontent.com` (Git and 7-Zip), `mcr.microsoft.com` (the base image), and Docker Hub (the token proxy image). [What needs internet](security.md#what-needs-internet) lists everything. Not tested without internet access: [Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows).
- Disk: `servercore` is about 2.2 GB compressed. Each container shows 20 GB free on `C:` by default. To raise the limit, add `"storage-opts": ["size=60GB"]` to `C:\ProgramData\docker\config\daemon.json`. Every finished container keeps its layer until Swarm prunes it.
- CPU and memory for the services, and runner concurrency in your CircleCI plan for your replicas ([Size the limits](resource-classes.md#size-the-limits)).

| Windows Server | Machine runner 3 | Status in this repository |
|---|---|---|
| 2025 | Compatible | Tested in CI, image tag `ltsc2025` |
| 2022 | Compatible | Tested in CI, image tag `ltsc2022` |
| 2019 | Compatible | Untested here: the stack files have no label or placement for it |
| 2016 and older | Not compatible | Not supported |

### Image tags and host builds

With process isolation, the image build must be the host build or an older one. Label every node with the image tags it can run: a service is placed on a node that carries the label of its image tag.

| Host | Images it can run | Node labels |
|---|---|---|
| Windows Server 2022 | `ltsc2022` only | `machine-runner-swarm.windows-ltsc2022=true` |
| Windows Server 2025 | `ltsc2025` and `ltsc2022` | `machine-runner-swarm.windows-ltsc2022=true` and `machine-runner-swarm.windows-ltsc2025=true` |

The shipped services use `ltsc2022` images, so they run on 2022 and 2025 nodes. A service on an `ltsc2025` image requires `machine-runner-swarm.windows-ltsc2025 == true`, so it runs on 2025 nodes only. A mismatch that the labels do not catch fails with `0xc0370101`.

### Self-hosted runner terms agreement

An organization admin must agree to the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/) before you install self-hosted runners through the web app. Through the CLI, you agree by installing and using them ([details](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-windows/#self-hosted-runner-terms-agreement)). Whether the token proxy between your runners and CircleCI is covered is for your own review: this project does not give legal advice.

## Get the files

Use a release (recommended) or clone the repository at a release tag. Paths on this page are relative to the root of either. The [GitHub release](https://github.com/CircleCI-Labs/machine-runner-swarm/releases) has the bundle `machine-runner-swarm-<VERSION>.zip`, and the Linux page lists [every file of a release](install-linux.md#get-the-files).

```powershell
git clone --branch <RELEASE_TAG> https://github.com/CircleCI-Labs/machine-runner-swarm.git
cd machine-runner-swarm
```

### Install cosign

[cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 3.1.3 or a later 3.x verifies the release (CI signs and verifies with 3.1.3, and earlier versions are not tested). Download the executable and the checksum list of the cosign release, compare the checksum, and put the file in a directory on your `PATH`:

```powershell
$cosign = '3.1.3'
$u = "https://github.com/sigstore/cosign/releases/download/v$cosign"
Invoke-WebRequest -UseBasicParsing -Uri "$u/cosign-windows-amd64.exe" -OutFile cosign.exe
Invoke-WebRequest -UseBasicParsing -Uri "$u/cosign_checksums.txt" -OutFile cosign_checksums.txt
$want = ((Get-Content cosign_checksums.txt | Where-Object { $_ -match '\scosign-windows-amd64\.exe$' }) -split '\s+')[0]
if ((Get-FileHash -Algorithm SHA256 -LiteralPath cosign.exe).Hash.ToLower() -ne $want) { throw 'the checksum of cosign.exe does not match: stop' }
.\cosign.exe version
```

This checks the file against a list from the same place: it catches a damaged download, not a compromised release page. Your own package manager is another source.

### Verify a release

CircleCI signs the file `SHA256SUMS` of each release with the OIDC token of the job that makes the release. The signature proves that a job of this CircleCI project made the file, and the checksum proves that your download is the file that the job made. The Linux page explains [what the signature proves](install-linux.md#verify-a-release), and what it does not.

Set `$version` once to the number of the [latest release](https://github.com/CircleCI-Labs/machine-runner-swarm/releases/latest) without the `v`, and read its notes. The download fails while the placeholder is unchanged.

```powershell
$version = 'X.Y.Z'
$base = "https://github.com/CircleCI-Labs/machine-runner-swarm/releases/download/v$version"
$zip = "machine-runner-swarm-$version.zip"
```

Then paste this block. It stops at the first failing check. The variables are set outside it, because `&` runs the block in a scope of its own. Only a bundle that passes the signature, the ref and the checksum is unpacked.

```powershell
& {
  $ErrorActionPreference = 'Stop'
  foreach ($f in $zip, 'SHA256SUMS', 'SHA256SUMS.sigstore.json') { Invoke-WebRequest -UseBasicParsing -Uri "$base/$f" -OutFile $f }

  # 1. the signature: the CircleCI project and pipeline definition of this repository signed SHA256SUMS
  cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json `
    --certificate-identity 'https://circleci.com/api/v2/projects/7bbdbb66-6ba8-4f6c-982e-d4fb401ec257/pipeline-definitions/8b2a66db-3f28-5c80-88e4-03f4694b5b60' `
    --certificate-oidc-issuer 'https://oidc.circleci.com'
  if ($LASTEXITCODE -ne 0) { throw 'the signature does not verify: stop' }

  # 2. the ref: a job of any branch can sign with that identity, so the certificate must also say that the job ran for refs/heads/main
  #    (the long string is the OID 1.3.6.1.4.1.57264.1.14 followed by the value refs/heads/main)
  $material = (Get-Content -Raw -LiteralPath SHA256SUMS.sigstore.json | ConvertFrom-Json).verificationMaterial
  if ($material.certificate) { $cert = $material.certificate.rawBytes } else { $cert = $material.x509CertificateChain.certificates[0].rawBytes }
  $hex = -join ([Convert]::FromBase64String($cert) | ForEach-Object { $_.ToString('x2') })
  if ($hex -notmatch '^([0-9a-f]{2})*2b0601040183bf30010e0411(0c|13)0f726566732f68656164732f6d61696e') { throw 'NOT signed for refs/heads/main: stop' }

  # 3. the file: its checksum is in the signed list
  $want = ((Get-Content SHA256SUMS | Where-Object { $_ -match "\s$([regex]::Escape($zip))$" }) -split '\s+')[0]
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLower() -ne $want) { throw "the checksum of $zip is not the signed one: stop" }

  # only a verified bundle is unpacked
  Expand-Archive -LiteralPath $zip -DestinationPath .
  'RELEASE VERIFIED'
}
```

Continue only when the last line is `RELEASE VERIFIED`. Anything else, an error message or no output at all, means that the release is not verified: delete the downloaded files, and start again or ask in an issue. The ref check exists because the signing identity is the same for every branch, so the block reads the certificate extension `1.3.6.1.4.1.57264.1.14` (the OID in the long string) and fails unless its value is `refs/heads/main`. The pattern starts on a byte boundary, and ASN.1 tag `0c` or `13` is the string type of the value.

Then change into the bundle:

```powershell
cd "machine-runner-swarm-$version"
```

The token proxy image has its own signature: [Verify the token proxy image](security.md#verify-the-token-proxy-image) has the commands.

### The token proxy image

The token proxy holds your class tokens ([The token proxy](concepts.md#the-token-proxy)). On Windows it is the image `ccilabs/machine-runner-swarm-proxy` of Docker Hub (`ccilabs` is the Docker Hub organization of CircleCI Labs), which the stack file `token-proxy-windows` pulls on deploy: a static binary on Nano Server, for `windows/amd64`. The name is not the trust root: the signature check is. One tag also holds the Linux images, and a manifest list holds one Windows image for Server 2022 and one for Server 2025, so Docker picks the one of the host. Tags, pinning and the signature are the same as on Linux: [The token proxy image](install-linux.md#the-token-proxy-image) and [Verify the token proxy image](security.md#verify-the-token-proxy-image).

The image runs as `ContainerAdministrator`, as the stock Server Core image does, because `ContainerUser` of Nano Server cannot write to the volume that keeps the state of the proxy.

There is no `windows/arm64` image, because CI has no Windows on Arm host to build and test one on. In a cluster with Windows on Arm nodes, pin the proxy to a `windows/amd64` node with `MACHINE_RUNNER_SWARM_PROXY_PLACEMENT` ([Multi-node clusters](multi-node.md)). A cluster of only Windows on Arm nodes needs an image of your own: build the proxy with `GOARCH=arm64`, build `proxy\Dockerfile.windows` on an arm64 host with an arm64 Nano Server image as `--build-arg BASE=`, and name it with `MACHINE_RUNNER_SWARM_PROXY_IMAGE`.

To use another image (development, an air gap), set `MACHINE_RUNNER_SWARM_PROXY_IMAGE` in the environment of `docker stack deploy`. The image must be on the node that runs the proxy: a local build exists only where you built it. This builds one from a checkout: build the binary on any host with Go, then build the image on the Windows host whose build matches the base image.

```powershell
$env:GOOS = 'windows'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
New-Item -ItemType Directory -Force -Path build | Out-Null
Push-Location proxy; go build -trimpath -o ..\build\machine-runner-swarm-proxy.exe .\cmd\machine-runner-swarm-proxy; Pop-Location
docker build -f proxy\Dockerfile.windows -t machine-runner-swarm-proxy:dev build
$env:MACHINE_RUNNER_SWARM_PROXY_IMAGE = 'machine-runner-swarm-proxy:dev'
```

## 1. Create the resource classes

1. Create a namespace if your organization has none.

   ```powershell
   circleci namespace create <NAMESPACE> --org <ORG>
   ```

2. Create one resource class for each service in the stack files. The class name must equal the service name. The shipped `windows\stack\runners.yaml` has the service `windows-default` and deploys on its own.

   ```powershell
   circleci runner resource-class create <NAMESPACE>/windows-default --org <ORG> --generate-token
   ```

The command prints the token once: store it in your secret manager. The optional add-on files in the same directory add `windows-custom` (`custom-image.yaml`), `windows-persistent` (`persistent.yaml`), `windows-docker-build` (`docker-build.yaml`) and `windows-default-ssh` (`ssh-rerun.yaml`, untested). Create the classes you plan to use.

## 2. Prepare each host

Run these steps in an elevated PowerShell on every host, before you start Swarm: the network of the host drops for a few seconds after `docker swarm init`, and the pull needs it.

1. Confirm that Docker runs Windows containers. The command prints `windows`.

   ```powershell
   docker info --format '{{.OSType}}'
   ```

2. Pull the base image of the shipped services once, so the first task does not wait for it. A Server 2025 host runs `ltsc2022` images too, so this is the image for both hosts. Pull `ltsc2025` as well only for a service that you put on that image.

   ```powershell
   docker pull mcr.microsoft.com/windows/servercore:ltsc2022
   ```

3. On the host that runs the token proxy (a manager, by default), pull its image too, or build your own ([The token proxy image](#the-token-proxy-image)).

   ```powershell
   docker pull ccilabs/machine-runner-swarm-proxy:latest
   ```

## 3. Start Swarm and label the node

1. On the first host, start Swarm. Always pass `--advertise-addr` with the IPv4 address of the host: a plain `docker swarm init` fails on some hosts with `could not find the system's IP address`. For more than one node, see [Multi-node clusters](multi-node.md).

   ```powershell
   docker swarm init --advertise-addr <HOST_IPV4_ADDRESS>
   ```

2. Label the node with the image tags it can run. A Server 2022 node gets the first label, and a Server 2025 node gets both.

   ```powershell
   docker node update --label-add machine-runner-swarm.windows-ltsc2022=true <NODE_NAME>
   docker node update --label-add machine-runner-swarm.windows-ltsc2025=true <NODE_NAME>
   ```

On a single node, the token proxy needs no label: it runs on the manager, and the jobs run there too. In a cluster, give the proxy a node of its own: label it `machine-runner-swarm.proxy=true`, and runner services never run there, so a job never shares a node with the proxy. Do not set the label on the only node of a swarm, because no runner would be placed. If the managers are Linux hosts, or there are several managers, also pin the proxy to a Windows node with the placement in the environment of `docker stack deploy`:

```powershell
docker node update --label-add machine-runner-swarm.proxy=true <NODE_NAME>
$env:MACHINE_RUNNER_SWARM_PROXY_PLACEMENT = 'node.labels.machine-runner-swarm.proxy == true'
```

Without a matching node the proxy stays pending and no runner can claim ([Where the proxy runs, and when it moves](operations.md#where-the-proxy-runs-and-when-it-moves)). The optional classes need one more label each, on the nodes that run them:

| Class | Label |
|---|---|
| `windows-docker-build` | `machine-runner-swarm.docker-build=true` |
| `windows-persistent` | `machine-runner-swarm.class.windows-persistent=true` |

## 4. Create the secrets

Create one secret for each service you deploy, named `<SERVICE>-token`, including each optional class (`windows-persistent-token` too: `persistent.yaml` declares it as external, so the deploy fails without it). It is a runner config file that holds only the token:

```yaml
api:
  auth_token: <TOKEN>
```

The token proxy mounts the secrets of the proxied classes, and those runners never see them. The persistent class is the exception ([The persistent class](security.md#the-persistent-class)). The runners read one more secret, `runner-placeholder-token`, with a dummy token in the same format (the setup helper creates it). Swarm mounts it at `C:\ProgramData\Docker\secrets\circleci_runner_config.yaml`, and the runner reads it with `--config`. Every other runner setting is a `CIRCLECI_RUNNER_*` variable in the stack file.

This block asks for the token with hidden input and passes the config to `docker secret create` on stdin, so no file with the token is written on the host. Repeat the first part for each class, with its name in `$class`. Create the placeholder once.

```powershell
$class = 'windows-default'
$secure = Read-Host -Prompt "Runner token for $class" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if (-not $token) { throw "no token entered for $class" }
"api:`n  auth_token: $token`n" | docker secret create "$class-token" -
Remove-Variable token
"api:`n  auth_token: machine-runner-swarm-placeholder`n" | docker secret create runner-placeholder-token -
```

Windows does not support the `uid`, `gid` and `mode` options of secrets: only administrators and `SYSTEM` can read the file inside the container, and jobs run as an administrator. Swarm also writes the secret in clear text to the disk of the container until it stops, which is a Swarm limitation on Windows (Linux keeps it in memory). Enable BitLocker on the Docker volume ([Token model on each OS](security.md#token-model-on-each-os)).

## 5. Review the stack files

Copy `windows\stack` to a directory of your own, `deploy\`, and keep it under version control. From here on you check and deploy your copies and never the files under `windows\stack`. For a first run, change nothing.

```powershell
Copy-Item -Recurse windows\stack deploy
```

Check that the file parses. This needs no running Swarm.

```powershell
docker stack config -c deploy\runners.yaml | Out-Null
```

The directory holds the stack files and `runner-distributor.ps1`, the script that `runners.yaml` ships as a Swarm config (`file: runner-distributor.ps1`): keep it next to `runners.yaml`. Review these first ([Resource classes](resource-classes.md) has the details):

| Service | File | Purpose |
|---|---|---|
| `runner-distributor-windows` | `runners.yaml` | Installs and upgrades the runner and Git on every Windows node. Keep it in your copy |
| `windows-default` | `runners.yaml` | Stock Server Core image, two replicas |
| `windows-custom` | `custom-image.yaml` | Your own image on top of stock Server Core ([Images](images.md#windows-bring-your-own-image)). It has a placeholder image that you replace |
| `windows-persistent` | `persistent.yaml` | A long-lived runner with a named volume ([Persistent mode](resource-classes.md#persistent-mode)) |
| `windows-docker-build` | `docker-build.yaml` | Builds Windows images with the host engine ([Docker builds](docker-builds.md)) |
| `windows-default-ssh` | `ssh-rerun.yaml` | Rerun job with SSH, port 54782. Untested on Windows ([Rerun job with SSH](resource-classes.md#rerun-job-with-ssh)) |

- `runners.yaml` needs the secrets `windows-default-token` and `runner-placeholder-token`. Each add-on file needs its own `<SERVICE>-token`.
- The distributor settings (the runner version, a mirror, an explicit SHA-256 list) are variables of `docker stack deploy` and need no edit ([Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows)).
- For a class on the `ltsc2025` image, copy a service under a new name and resource class, use the `ltsc2025` image tag, and set the constraint `node.labels.machine-runner-swarm.windows-ltsc2025 == true`.
- Add each optional file with another `-c` flag, and pass the same list on every deploy ([how the files merge](concepts.md#add-on-stack-files-and-how-they-merge)). Each add-on file repeats the anchors of `runners.yaml` and declares the volume `runner-bin`, so it also loads alone: change a common setting in every file you use.

To check the optional files, pass them all in the order you deploy them:

```powershell
docker stack config -c deploy\runners.yaml -c deploy\custom-image.yaml -c deploy\persistent.yaml -c deploy\docker-build.yaml | Out-Null
```

For the keys that Windows honors and ignores, see [Stack keys on Windows](resource-classes.md#stack-keys-on-windows).

## 6. Deploy the stack

Deploy your copy from step 5:

```powershell
docker stack deploy -c deploy\runners.yaml runners
```

To add optional classes, pass your copies after `runners.yaml` with more `-c` flags, for example your own image on top of stock Server Core:

```powershell
docker stack deploy -c deploy\runners.yaml -c deploy\custom-image.yaml runners
```

This is the whole install: nothing is staged on the host. The service `runner-distributor-windows` starts on every Windows node, downloads the pinned runner version (the newest that CI tests) and the pinned portable Git (about 60 MB, 406 MB unpacked), verifies their SHA-256 checksums (the runner against the values the stack file carries, not CircleCI's manifest), installs them into the per-node volume `runner-bin`, and flips two links. The runner services mount the volume read-only twice: `current` at `C:\machine-runner-swarm`, and `git\current` at `C:\Program Files\Git`, where the task agent expects `tar.exe`. The stock Server Core image needs no changes, and `circleci-runner.exe` is the main process of the container.

On a new node the first runner tasks fail with `cannot access path ... \current` until the distributor has flipped the link, which takes a few minutes for the first download. Swarm starts the next task after the restart delay of 10 seconds, so nothing needs to be done. Watch the distributor:

```powershell
docker service logs runners_runner-distributor-windows
```

## Verify the deployment

1. List the services and tasks. The service `runners_runner-distributor-windows` shows one replica for each Windows node.

   ```powershell
   docker stack services runners
   docker stack ps runners --no-trunc
   ```

2. Check that the runners connected. Each replica is listed as `online`, named `<NODE_HOSTNAME>-<SERVICE>-<SLOT>`. The web app shows the same under **Runners**.

   ```powershell
   circleci runner instance list --org <ORG> --resource-class <NAMESPACE>/windows-default
   ```

3. Run a job. The [quickstart](quickstart-windows.md#steps) has a complete config, and [`examples/windows-job.yml`](../examples/windows-job.yml) has more steps. Run the workflow twice: the two runs print different values for `$MACHINE_RUNNER_SWARM_INSTANCE_ID`, because each job runs in a new container.

## What jobs can use

- The default shell is Git Bash (`bash -eo pipefail`). Set `shell: powershell.exe -ExecutionPolicy Bypass` for Windows PowerShell 5.1, or `shell: cmd.exe`, per job or step.
- The working directory is `C:\cci\w`, and the task agent lives in `C:\cci\agent`. The `PATH` of the service reaches every step.
- `checkout`, caches, test results and artifacts need Git and outbound access. Workspaces use the `tar` and `gzip` from the mounted Git.
- OpenID Connect tokens need a writable `%TEMP%`.
- The stack enables Git long paths through the environment. The registry value `LongPathsEnabled` is not set: a job that needs long paths for other tools sets it itself, or in its own image.
- Not supported: desktop or UI automation, Docker commands in jobs (except the opt-in docker-build class), and service containers.
- Not tested: `add_ssh_keys`, Hyper-V isolation, group managed service accounts, and proxies.
- `MACHINE_RUNNER_SWARM_JOB_SUDO` and `MACHINE_RUNNER_SWARM_JOB_USER` of the Linux entrypoint do not exist on Windows, and Windows ignores them. There is no step-down.

## Optional: use the setup helper

`windows\Setup.ps1` checks the host, starts Swarm on request, labels the node, creates the secrets, and deploys. It does not install the runner: the distributor service of the stack does that on every node. It runs in an elevated Windows PowerShell 5.1 session and is safe to run again. It prints `CHECK <NAME> PASS` or `FAIL` for each preflight check (administrator, Windows Server build, Windows-container mode, Docker 28.0 or later, Swarm manager), and ends with `Next:` and the steps still to do, or `Check:` and the commands that watch the start.

| Parameter | Effect |
|---|---|
| `-InitSwarm -AdvertiseAddr <IP_ADDRESS>` | Creates a Swarm when none exists, and waits until the node is a manager. The address is needed only then: on an active Swarm, `-InitSwarm` changes nothing |
| `-Class <NAME>,<NAME>` | Asks for each token with hidden input and creates the secret `<NAME>-token`. An existing secret stays unchanged |
| (placeholder) | With `-Class` or `-Deploy`, it also creates the secret `runner-placeholder-token` with a dummy token, which every runner reads |
| `-Deploy` | Runs `docker stack deploy` with `-StackFile` (one or more files, `runners.yaml` first) and `-StackName` (default `runners`). Without `-StackFile` it deploys the shipped `windows\stack\runners.yaml` as it is, which suits a first run. Once you keep copies as in step 5, pass them. It prints the files it deploys |

The helper labels the node from the host build: `windows-ltsc2022=true` on Server 2022, and both `windows-ltsc2022=true` and `windows-ltsc2025=true` on Server 2025 (`machine-runner-swarm.` prefix). It supports Server 2022 and 2025 only, and does not add the labels of the optional classes. The distributor reads its settings from the environment of `-Deploy`.

The first command is a first run with the shipped `runners.yaml`. The second deploys your copy from step 5, with its optional file.

```powershell
.\windows\Setup.ps1 -InitSwarm -AdvertiseAddr 10.0.0.5 -Class windows-default -Deploy
.\windows\Setup.ps1 -Class windows-default,windows-custom -StackFile .\deploy\runners.yaml,.\deploy\custom-image.yaml -Deploy
```

## Upgrade

The distributor pins the exact runner version that this release tests, with the SHA-256 values of its tarballs, and the nodes keep it until you change it. `3.1`, `3` or `current` (weaker: they trust the hash of the manifest) follow CircleCI's manifest and check every 24 hours. A pin of your own is two variables of `docker stack deploy`: the version and its SHA-256 values (or `manifest` for an exact version without a list). Running jobs keep their version, and the runner services never restart ([Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows)).

A new release of this repository changes the shipped stack files, and your copy `deploy\` is not updated by itself. To merge, with `git` from Git for Windows or another diff and merge tool:

1. Read the notes of the release and the [changelog](../CHANGELOG.md): entries marked `[BREAKING]` say what to change. This is a `0.x` project, so a minor release can change the files.
2. Verify and unpack the new release beside the old one ([Verify a release](#verify-a-release)). The old directory is the base of the merge.
3. See what changed between the two releases, and merge each file that differs into your copy. `git merge-file` edits the file in place, marks conflicts with `<<<<<<<` lines, and exits with the number of conflicts.

   ```powershell
   git diff --no-index "machine-runner-swarm-$old\windows\stack" "machine-runner-swarm-$new\windows\stack"
   git merge-file deploy\runners.yaml "machine-runner-swarm-$old\windows\stack\runners.yaml" "machine-runner-swarm-$new\windows\stack\runners.yaml"
   ```

   Repeat for the other files you copied. Take `runner-distributor.ps1` of the new release unless you edited it ([Upgrade to a new release of this repository](operations.md#upgrade-to-a-new-release-of-this-repository) explains the names of the Swarm configs).
4. Check `deploy.replicas`, `image`, `deploy.placement.constraints` and `deploy.resources`, the runner version pin with its SHA-256 values (a release changes them together), and the token proxy image (a release names it by digest).
5. Check the result.

   ```powershell
   docker stack config -c deploy\runners.yaml | Out-Null
   ```

6. Deploy while the classes are idle ([Stop a busy Windows container](operations.md#stop-a-busy-windows-container)), with the same list of `-c` files as before.

   ```powershell
   docker stack deploy -c deploy\runners.yaml runners
   ```

To roll back, deploy the previous copy.

## Stop and uninstall

Refer to [Uninstall](operations.md#uninstall). Every stop of a busy service kills its job after about 5 seconds. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

## Troubleshooting

Refer to [Troubleshooting](troubleshooting.md#windows). The most common problems are an image tag that does not match the host build, a distributor that has not installed the runner yet, and a job that ends about 5 seconds after a stop. A task also stays pending when no node carries the `machine-runner-swarm.windows-ltsc2022` label (or `windows-ltsc2025`, for a service on an `ltsc2025` image).

## Additional resources

- [Concepts](concepts.md)
- [Resource classes](resource-classes.md)
- [Security](security.md)
- [Operations](operations.md)
- [Machine runner 3 on Windows](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-windows/)
