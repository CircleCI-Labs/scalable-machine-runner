---
page-title: Install on Windows Server with Docker Swarm
page-audience: admin
page-description: Deploy CircleCI machine runner 3 as a Docker Swarm stack on Windows Server 2019, 2022, or 2025, with one clean container for every job.
---

# Install on Windows Server with Docker Swarm

This page describes how to deploy CircleCI machine runner 3 as a Docker Swarm stack on Windows Server. Every job runs in a new Windows Server Core container, and Swarm replaces the container after the job.

> [!NOTE]
> If you can run Kubernetes, CircleCI recommends [container runner](https://circleci.com/docs/guides/execution-runner/container-runner-installation/) for containerized jobs. This page is for teams that run Docker Swarm and need a clean Windows container for every job.

The manual steps come first. The optional [setup helper](#optional-use-the-setup-helper) runs most of the same steps.

> [!IMPORTANT]
> A stock Server Core container ends about 5 seconds after any stop, whatever `stop_grace_period` says. A rolling update, a scale down, or a node drain then kills the running job. Use the stop-timeout image for every stock-image service. Refer to [Build the stop-timeout image](#4-build-the-stop-timeout-image).

## Prerequisites

- A CircleCI cloud organization and a user who is an organization admin.
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/), signed in. It can run on your workstation.
- One or more Windows Server hosts. Machine runner 3 supports these versions:

  | Windows Server | Machine runner 3 | Status in this repository |
  |---|---|---|
  | 2025 | Compatible | Tested in CI, image tag `ltsc2025` |
  | 2022 | Compatible | Tested in CI, image tag `ltsc2022` |
  | 2019 | Compatible | Supported by machine runner 3, not tested in this repo's CI |
  | 2016 and older | Not compatible | Not supported |

  The host cannot be a domain controller.

- Docker Engine in Windows-container mode, with the Windows Containers feature. The `Install-DockerCE` script in the `helpful_tools` directory of the [Microsoft Windows Containers repository](https://github.com/microsoft/Windows-Containers) installs both.
- An elevated Windows PowerShell 5.1 session.
- A host clock that is synchronized with NTP. TLS to CircleCI fails silently when the clock drifts.
- Outbound HTTPS access from each host to the hosts in [Egress hosts](security.md#egress-hosts). During setup, the host also needs `github.com` and `release-assets.githubusercontent.com` for Git and 7-Zip, and `mcr.microsoft.com` for the base image.
- Disk space for the base image. The `servercore` image is about 2.2 GB compressed. Each container shows 20 GB free on `C:` by default. Add `"storage-opts": ["size=60GB"]` to `C:\ProgramData\docker\config\daemon.json` to raise the limit.

### Image tags and host builds

With process isolation, the image build must match the host build. Label every node with its build, and the stack places each service on a matching node.

| Host | Images it can run | Node label |
|---|---|---|
| Windows Server 2022 | `ltsc2022` only | `windows.build=ltsc2022` |
| Windows Server 2025 | `ltsc2025` and `ltsc2022` | `windows.build=ltsc2025` |

A mismatch fails with the error `0xc0370101`. The shipped file targets `ltsc2022`.

### Self-hosted runner terms agreement

If you install self-hosted runners through the web app, an organization admin must agree to the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/) at **Org** > **Runners**. If you install and use self-hosted runners through the CLI, you agree to the CircleCI Runner Terms.

## Get the files

Clone the repository at a release tag, or extract a release bundle. Paths on this page are relative to the root of either. The [GitHub release](https://github.com/CircleCI-Labs/scalable-machine-runner/releases) has the `scalable-machine-runner-<version>.zip` bundle for Windows, and the Linux page lists [every file of a release](install-linux.md#get-the-files).

```powershell
git clone --branch <release-tag> https://github.com/CircleCI-Labs/scalable-machine-runner.git
cd scalable-machine-runner
```

### Verify a release

CircleCI signs the file `SHA256SUMS` of each release with the OIDC token of the job that makes the release. Verify the signature with [cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 2.4 or later, then compare the checksum of the bundle with `SHA256SUMS`. The Linux page explains [what the signature proves](install-linux.md#verify-a-release).

1. Download the bundle and the two verification files. Set `$version` to the release you want, without the `v`.

   ```powershell
   $version = '0.1.0'
   $base = "https://github.com/CircleCI-Labs/scalable-machine-runner/releases/download/v$version"
   foreach ($file in "scalable-machine-runner-$version.zip", 'SHA256SUMS', 'SHA256SUMS.sigstore.json') {
     Invoke-WebRequest -Uri "$base/$file" -OutFile $file
   }
   ```

1. Verify the signature of `SHA256SUMS`. The command prints `Verified OK`.

   ```powershell
   cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json `
     --certificate-identity "https://circleci.com/api/v2/projects/7bbdbb66-6ba8-4f6c-982e-d4fb401ec257/pipeline-definitions/8b2a66db-3f28-5c80-88e4-03f4694b5b60" `
     --certificate-oidc-issuer "https://oidc.circleci.com"
   ```

1. Compare the checksum of the bundle with the line in `SHA256SUMS`.

   ```powershell
   $zip = "scalable-machine-runner-$version.zip"
   $expected = ((Select-String -Path SHA256SUMS -Pattern ([regex]::Escape($zip))).Line -split '\s+')[0]
   $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
   if ($actual -ne $expected) { throw "SHA-256 mismatch for $zip" } else { "$zip OK" }
   ```

Do not use a bundle if a command fails.

## 1. Create the resource classes

Create a namespace if your organization has none.

```console
$ circleci namespace create <namespace> --org-id <organization-id>
```

Create one resource class for each service in the stack files. The class name must equal the service name. The shipped file `windows\stack\runners.yaml` has the service `windows-default` and deploys on its own. The optional overlay files in the same directory add `windows-custom` (`custom-image.yaml`), `windows-persistent` (`persistent.yaml`), and `windows-docker-build` (`docker-build.yaml`). Create the classes you plan to use.

```console
$ circleci runner resource-class create <namespace>/windows-default --generate-token
```

The command prints the token once. Store it in your secret manager.

## 2. Prepare each host

Run these steps in an elevated PowerShell on every host. Do them before you start Swarm. The network of the host drops for a few seconds after `docker swarm init`, and the downloads and pulls need it.

1. Confirm that Docker runs Windows containers. The command prints `windows`.

   ```powershell
   docker info --format '{{.OSType}}'
   ```

2. Pull the base image once, so the first task does not wait for it. Use `ltsc2025` on a Server 2025 host.

   ```powershell
   docker pull mcr.microsoft.com/windows/servercore:ltsc2022
   ```

## 3. Stage the runner and Git

The stack mounts the host directory `C:\smr` read-only into every container, and mounts `C:\smr\git` at `C:\Program Files\Git`. The stock Server Core image therefore needs no changes. No entrypoint script exists on Windows, because `circleci-runner.exe` is the main process of the container.

| Path | Content |
|---|---|
| `C:\smr\bin\circleci-runner.exe` | Machine runner 3 binary |
| `C:\smr\git\` | Portable Git for Windows, with `git`, `bash`, `sh`, `tar`, `gzip`, and `ssh` |
| `C:\smr\VERSION` | The runner and Git versions |

The task agent runs `C:\Program Files\Git\usr\bin\tar.exe` for workspaces, and it runs steps with `bash`. MinGit has no `tar`, `gzip`, or `bash`, so the stack uses PortableGit. The download is about 60 MB, and the unpacked tree is about 406 MB in 9,600 files.

The task agent starts `tar.exe` with `--force-local`, from the root of the drive, and with forward-slash operands that are relative to that root. For example, it passes `foo/bar` for `C:\foo\bar`. A backslash operand makes the tar of Git fail with `Cannot stat`, so use the forward-slash form when you test `tar` by hand.

Run the following in an elevated PowerShell. It downloads each file, verifies its SHA-256 checksum, and fills `C:\smr`. The Git and 7-Zip checksums are the values pinned in `windows\Setup.ps1`, and the runner checksum comes from the CircleCI release manifest.

```powershell
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$smr = 'C:\smr'
$runnerVersion = '3.1.12'
$gitVersion = '2.56.0.2'
$gitTag = 'v2.56.0.windows.2'
$gitSha = '075e158ef8e1f0ab80b347e245405d3eca735c2dc88fd8e032e137d0ca61f61b'
$sevenZipVersion = '26.04'
$sevenZipSha = '256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282'
$work = Join-Path $env:TEMP 'smr-stage'
New-Item -ItemType Directory -Force "$smr\bin", "$smr\git", $work | Out-Null

function Get-Verified($uri, $file, $sha) {
  Invoke-WebRequest -Uri $uri -OutFile $file -UseBasicParsing
  if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $sha) { throw "SHA-256 mismatch for $uri" }
}

# Runner: the checksum comes from the CircleCI release manifest
$manifestUrl = 'https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/manifest.json'
$manifest = (Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing).Content | ConvertFrom-Json
$entry = $manifest.releases.$runnerVersion.windows.amd64
$runnerUrl = "https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/$runnerVersion/circleci-runner_windows_amd64.tar.gz"
Get-Verified $runnerUrl "$work\runner.tar.gz" $entry.sha256
& "$env:SystemRoot\System32\tar.exe" -xzf "$work\runner.tar.gz" -C "$smr\bin"

# Portable Git, unpacked with the standalone 7-Zip extractor
Get-Verified "https://github.com/ip7z/7zip/releases/download/$sevenZipVersion/7zr.exe" "$work\7zr.exe" $sevenZipSha
Get-Verified "https://github.com/git-for-windows/git/releases/download/$gitTag/PortableGit-$gitVersion-64-bit.7z.exe" "$work\pgit.exe" $gitSha
& "$work\7zr.exe" x -y "-o$smr\git" "$work\pgit.exe"

# Git's post-install scripts, once, so the tree is ready to mount read-only
& "$smr\git\usr\bin\bash.exe" --norc -c 'export PATH=/usr/bin:/ucrt64/bin:/mingw64/bin:/cmd:$PATH; export SYSCONFDIR=/etc; for p in $(export LC_COLLATE=C; echo /etc/post-install/*.post); do test -e "$p" && . "$p"; done'
Remove-Item "$smr\git\post-install.bat" -ErrorAction SilentlyContinue
Set-Content "$smr\VERSION" "runner=$runnerVersion", "git=$gitVersion" -Encoding ASCII
Remove-Item $work -Recurse -Force
```

The script uses the `tar.exe` in `System32` on purpose. A GNU `tar` from another Git on the `PATH` of the host reads `C:\smr\bin` as a remote host name.

A `PsExec64.exe` on the `PATH` of the host does not matter. The stack sets the `PATH` of the containers in full, so the host `PATH` never reaches them. Only an image build checks for it.

### Set the access rights on C:\smr

Containers with process isolation open the bind mounts as an identity that does not exist on the host. Microsoft says to grant access to Authenticated Users. `Setup.ps1` sets these rights, and you set them by hand as follows.

| Account | Right |
|---|---|
| `SYSTEM` | Full control |
| `Administrators` | Full control |
| `Authenticated Users` | Read and execute |

```powershell
icacls C:\smr /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-11:(OI)(CI)RX'
icacls 'C:\smr\*' /reset /T /C /Q
```

The first command sets the rights on the directory only, and cuts the inheritance from `C:\`. The second command resets every file below it to inherit them. Do not combine the two with `/T` in one call, because that leaves the files with an empty access list, and the container then fails with `Access is denied`.

A job cannot change the files. Authenticated Users can read and run them but not write, and the mounts are read-only. Hyper-V isolation opens bind mounts as `LocalSystem` instead, and this repository does not test it. Windows can bind-mount only directories, which is why `C:\smr` and `C:\smr\git` are directories and the runner config is a Swarm secret and not a mounted file.

Check the result. The first command prints the runner version, and the second prints the Git version.

```powershell
C:\smr\bin\circleci-runner.exe --version
C:\smr\git\cmd\git.exe --version
```

Repeat this step on every Windows host. The directory must exist on each host that can run a service.

## 4. Build the stop-timeout image

Docker stops a container by sending a shutdown event to it. The runner drains on that event: it accepts no new job and lets the running job finish. On Server Core, Windows waits only the time in the registry value `WaitToKillServiceTimeout` before it ends the processes of the container. The default is 5 seconds, whatever `docker stop -t` or `stop_grace_period` says. A stock container therefore exits about 5 seconds after any stop with the exit code 3221225786 (`0xC000013A`), and the running job dies with it.

The image `windows\images\stop-timeout` is the stock Server Core image plus that one registry value. Build it for each image tag that you run. The build context is the directory of the Dockerfile.

```powershell
docker build -f windows/images/stop-timeout/Dockerfile --build-arg WINDOWS_TAG=ltsc2022 `
  -t registry.example.com/ci/servercore-stop:ltsc2022 windows/images/stop-timeout
docker build -f windows/images/stop-timeout/Dockerfile --build-arg WINDOWS_TAG=ltsc2025 `
  -t registry.example.com/ci/servercore-stop:ltsc2025 windows/images/stop-timeout
```

The build argument `SHUTDOWN_TIMEOUT_SECONDS` sets the wait. The default is 18300 seconds, which is the 5 hours of `max_run_time` plus the 5 minutes of drain margin in `stop_grace_period`. The value must be at least the longest job that you allow plus the drain margin. If you lower `CIRCLECI_RUNNER_MAX_RUN_TIME` and `stop_grace_period`, you can lower the build argument to match. If you raise them, rebuild the image with a larger value.

Set `image:` of every stock-image service in your copy of the stack file to this image. On a single node, a locally built image works: deploy with `docker stack deploy --resolve-image never`, because the image is not in a registry. For several nodes, push the image to a registry that every Windows node can pull from, because Swarm does not share local images.

The baked image already includes the value. Refer to [Images](images.md#windows-the-baked-image). Nano Server images do not have this limit, but this repository does not support Nano Server.

> [!WARNING]
> Never use `New-Item -Force` on an existing registry key in an image build or in a running container. It replaces the key and deletes its values and subkeys. On `HKLM:\SYSTEM\CurrentControlSet\Services\cexecsvc`, it removes the definition of the container exec service, and the container fails to start with `hcs::System::Start: context deadline exceeded`. Use `reg add` or `Set-ItemProperty`, which set one value and leave the rest of the key alone.

## 5. Start Swarm and label the node

On the first host, start Swarm. Always pass `--advertise-addr` with the IPv4 address of the host. A plain `docker swarm init` fails on some hosts with `could not find the system's IP address`, and a host with several network adapters needs the address to pick the right one.

```powershell
docker swarm init --advertise-addr <host IPv4 address>
```

The network of the host drops for a few seconds after this command, so run it after steps 2 to 4. For more than one node, refer to [Multi-Node Clusters](multi-node.md).

Label the node with its Windows build. Use `ltsc2025` on Server 2025.

```powershell
docker node update --label-add windows.build=ltsc2022 <node name>
```

The optional classes need one more label each. Add it to the nodes that run them:

| Class | Label |
|---|---|
| `windows-docker-build` | `smr.docker-build=true` |
| `windows-persistent` | `smr.class.windows-persistent=true` |

## 6. Create the secrets

Create one secret for each service you deploy, including each optional class. The secret is the config file of the runner and holds only the token:

```yaml
api:
  auth_token: <token>
```

Swarm mounts the secret at `C:\ProgramData\Docker\secrets\circleci_runner_config.yaml`. The runner reads it with `--config`. Every other setting is a `CIRCLECI_RUNNER_*` environment variable in the stack file.

The following commands ask for the token with hidden input, write the file without a byte order mark, create the secret, and delete the file.

```powershell
$class = 'windows-default'
$secure = Read-Host -Prompt "Runner token for $class" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
$file = Join-Path $env:TEMP 'smr-runner-config.yaml'
[IO.File]::WriteAllText($file, "api:`n  auth_token: $token`n", (New-Object Text.UTF8Encoding($false)))
docker secret create "$class-token" $file
Remove-Item -LiteralPath $file -Force
```

Windows does not support the `uid`, `gid`, and `mode` options of secrets. Only administrators and `SYSTEM` can read the file inside the container, and jobs run as an administrator. Swarm also writes the secret in clear text to the disk of the container until the container stops, which is a Swarm limitation on Windows. Linux keeps the secret in memory. Enable BitLocker on the Docker volume. Refer to [Token model on each OS](security.md#token-model-on-each-os).

## 7. Review the stack file

Copy `windows\stack\runners.yaml`, and keep the copy under version control. Review these settings first. Refer to [Resource Classes](resource-classes.md) for the details.

| Service | File | Purpose |
|---|---|---|
| `windows-default` | `runners.yaml` | Stock Server Core image, two replicas |
| `windows-custom` | `custom-image.yaml` | Your own image on top of the baked runner image. Refer to [Images](images.md) |
| `windows-persistent` | `persistent.yaml` | A long-lived runner with a named volume. Refer to [Persistent mode](resource-classes.md#persistent-mode) |
| `windows-docker-build` | `docker-build.yaml` | Builds Windows images with the host engine. Refer to [Docker Builds](docker-builds.md) |

- Set `image:` of each stock-image service to your stop-timeout image from step 4.
- `runners.yaml` needs only the secret `windows-default-token`. Each overlay file needs its own `<service>-token` secret, and `custom-image.yaml` has a placeholder image that you replace with yours.
- For Server 2025 nodes, copy a service under a new name and resource class, use the `ltsc2025` image tag, and set the constraint `node.labels.windows.build == ltsc2025`.

The optional classes are overlay files. Add each with another `-c` flag, and pass the same set of files on every deploy. Each overlay repeats the anchors of `runners.yaml`, because an anchor does not reach into another file. When you change a common setting, change it in every file that you use.

Check that the files parse. This needs no running Swarm.

```powershell
docker stack config -c windows\stack\runners.yaml | Out-Null
docker stack config -c windows\stack\runners.yaml -c windows\stack\custom-image.yaml -c windows\stack\persistent.yaml -c windows\stack\docker-build.yaml | Out-Null
```

For the keys that Windows honours and the keys that it ignores, refer to [Stack keys on Windows](resource-classes.md#stack-keys-on-windows).

## 8. Deploy the stack

```powershell
docker stack deploy -c windows\stack\runners.yaml smr
```

To add the optional classes, pass their files after `runners.yaml` with more `-c` flags, for example your own image on top of the baked runner image:

```powershell
docker stack deploy -c windows\stack\runners.yaml -c windows\stack\custom-image.yaml smr
```

The bind source of the runner mount is `${SMR_DIR:-C:\smr}`. Set `SMR_DIR` before the deploy to use another directory, which [Upgrade the runner and images](operations.md#upgrade-the-runner-and-images) uses for rolling updates.

## Verify the deployment

1. List the services and tasks.

   ```powershell
   docker stack services smr
   docker stack ps smr --no-trunc
   ```

2. In the web app, select **Runners** and open the resource class. Each replica shows up in the inventory with a name of the form `<node hostname>-<service>-<slot>`.

3. Add a job to your config and run it twice.

   ```yaml
   version: 2.1

   jobs:
     build:
       machine: true
       resource_class: <namespace>/windows-default
       steps:
         - checkout
         - run: echo "computer $COMPUTERNAME, instance $SMR_INSTANCE_ID"

   workflows:
     main:
       jobs:
         - build
   ```

   The two runs print different values, because each job runs in a new container. The file [`examples/windows-job.yml`](../examples/windows-job.yml) has more steps.

## What jobs can use

- The default shell is Git Bash (`bash -eo pipefail`). Set `shell: powershell.exe -ExecutionPolicy Bypass` for Windows PowerShell 5.1, or `shell: cmd.exe`, per job or step.
- The working directory is `C:\cci\w`, and the task agent lives in `C:\cci\agent`.
- The `PATH` of the service reaches every step, because the runner passes its environment to the task agent and the task agent passes it to the steps.
- `checkout`, caches, test results, and artifacts need Git and outbound access. Workspaces use the `tar` and `gzip` from the mounted Git. Caches and test results use built-in code.
- OpenID Connect tokens need a writable `%TEMP%`.
- The stack enables Git long paths through the environment. The Windows registry value `LongPathsEnabled` is not set. A job that needs long paths for other tools sets the value itself, or runs on a baked image that sets it.
- Not supported: desktop or UI automation, Docker commands in jobs (except the opt-in docker-build class), and service containers.
- Not tested: `add_ssh_keys`, Hyper-V isolation, group managed service accounts, and proxies.
- The variables `SMR_JOB_SUDO` and `SMR_JOB_USER` of the Linux entrypoint do not exist on Windows, and Windows ignores them. There is no step-down.

## Optional: use the setup helper

`windows\Setup.ps1` stages `C:\smr`, starts Swarm on request, labels the node, creates the secrets, and deploys, with checks. It runs in an elevated Windows PowerShell 5.1 session and is safe to run again. It prints `CHECK <name> PASS` or `FAIL` for each preflight check: administrator, Windows Server build, Windows-container mode, and Swarm manager.

The helper always stages before it starts Swarm. It ignores a `PsExec64.exe` on the host `PATH`. It does not build the stop-timeout image, and it does not add the labels of the optional classes.

| Parameter | Effect |
|---|---|
| `-InstallDir` | Directory to stage. The default is `C:\smr` |
| `-RunnerVersion` | Runner version. The default is `3.1.12`. The checksum comes from the CircleCI release manifest |
| `-StageOnly` | Stops after staging. Needs no Docker |
| `-InitSwarm -AdvertiseAddr <ip>` | Creates a Swarm when none exists. The address is required, and the helper waits until the node is a manager |
| `-Class <name>,<name>` | Asks for each token with hidden input and creates the secret `<name>-token`. An existing secret stays unchanged |
| `-Deploy` | Runs `docker stack deploy` with `-StackFile` (one or more files, default `windows\stack\runners.yaml`) and `-StackName` (default `smr`) |
| `-Force` | Stages again even when the same versions are present |

The helper labels the node `windows.build=ltsc2022` or `ltsc2025` from the host build. It supports Server 2022 and 2025 only, so on Server 2019 use the manual steps.

Run it after you build the stop-timeout image. The example uses your copy of the stack file, because you set its `image:` to your stop-timeout image.

```powershell
.\windows\Setup.ps1 -InitSwarm -AdvertiseAddr 10.0.0.5 -Class windows-default -StackFile .\my-runners.yaml -Deploy
```

## Upgrade

Refer to [Upgrade the runner and images](operations.md#upgrade-the-runner-and-images). Do not overwrite `C:\smr` while containers use it, because Windows cannot replace files that are in use.

## Stop and uninstall

Refer to [Uninstall](operations.md#uninstall). Every stop of a service, including a scale down, a rolling update, and a node drain, ends the containers. The running jobs finish only on the stop-timeout image or on the baked image. Refer to [Windows drain](operations.md#windows-drain).

## Troubleshooting

Refer to [Troubleshooting](troubleshooting.md#windows). The most common problems are an image tag that does not match the host build, missing access rights on `C:\smr`, and a job that ends about 5 seconds after a stop. A task also stays pending when no node carries the `windows.build` label.

## Additional resources

- [Concepts](concepts.md)
- [Resource Classes](resource-classes.md)
- [Security](security.md)
- [Operations](operations.md)
- [Machine runner 3 on Windows](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-windows/)
