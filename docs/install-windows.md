---
page-title: Install on Windows Server with Docker Swarm
page-audience: admin
page-description: Deploy CircleCI machine runner 3 as a Docker Swarm stack on Windows Server 2022 or 2025, with one clean container for every job.
---

# Install on Windows Server with Docker Swarm

This page describes how to deploy CircleCI machine runner 3 as a Docker Swarm stack on Windows Server. Every job runs in a new Windows Server Core container, and Swarm replaces the container after the job.

> [!NOTE]
> If you can run Kubernetes, CircleCI recommends [container runner](https://circleci.com/docs/guides/execution-runner/container-runner-installation/) for containerized jobs. This page is for teams that run Docker Swarm and need a clean Windows container for every job.

The manual steps come first. The optional [setup helper](#optional-use-the-setup-helper) runs most of the same steps. For a first run, [Quickstart on Windows Server](quickstart-windows.md) is shorter.

> [!IMPORTANT]
> The services run the stock Server Core image, and no image is built. A job that finishes ends its container cleanly. Stopping a busy container from outside kills its job after about 5 seconds, with the exit code 3221225786. This happens on a deploy or update, a scale-down, a node drain, `docker stack rm`, and a restart of Docker. Roll out changes while the class is idle, or rerun the interrupted jobs. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

## Prerequisites

- A CircleCI cloud organization and a user who is an organization admin.
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, signed in. It can run on your workstation. The commands on this page use its syntax (`circleci --version` prints the version). Pass `--org <org>`, the organization slug such as `gh/my-org` or its UUID: without it the CLI takes the organization of the git remote of the current directory, which in a clone of this repository is not yours.
- One or more Windows Server hosts. Machine runner 3 supports these versions:

  | Windows Server | Machine runner 3 | Status in this repository |
  |---|---|---|
  | 2025 | Compatible | Tested in CI, image tag `ltsc2025` |
  | 2022 | Compatible | Tested in CI, image tag `ltsc2022` |
  | 2019 | Compatible | Untested here: the stack files have no label or placement for it, so this page does not cover it |
  | 2016 and older | Not compatible | Not supported |

  The host cannot be a domain controller.

- Docker Engine in Windows-container mode, with the Windows Containers feature. The `Install-DockerCE` script in the `helpful_tools` directory of the [Microsoft Windows Containers repository](https://github.com/microsoft/Windows-Containers) installs both.
- An elevated Windows PowerShell 5.1 session.
- A host clock that is synchronized with NTP. TLS to CircleCI fails silently when the clock drifts.
- Outbound HTTPS access from each host to the hosts in [Egress hosts](security.md#egress-hosts). During setup, the host also needs `github.com` and `release-assets.githubusercontent.com` for Git and 7-Zip, and `mcr.microsoft.com` for the base image.
- Disk space for the base image. The `servercore` image is about 2.2 GB compressed. Each container shows 20 GB free on `C:` by default. Add `"storage-opts": ["size=60GB"]` to `C:\ProgramData\docker\config\daemon.json` to raise the limit.

### Image tags and host builds

With process isolation, the image build must be the host build or an older one. Label every node with the image tags it can run, and the stack places each service on a node that carries the label of the service's image tag.

| Host | Images it can run | Node labels |
|---|---|---|
| Windows Server 2022 | `ltsc2022` only | `machine-runner-swarm.windows-ltsc2022=true` |
| Windows Server 2025 | `ltsc2025` and `ltsc2022` | `machine-runner-swarm.windows-ltsc2022=true` and `machine-runner-swarm.windows-ltsc2025=true` |

A service requires the label that names its image tag. The shipped services use `ltsc2022` images, so they run on 2022 and 2025 nodes alike. A service on an `ltsc2025` image requires `machine-runner-swarm.windows-ltsc2025 == true`, so it runs on 2025 nodes only. A mismatch that the labels do not catch fails with the error `0xc0370101`. Server 2019 is untested and has no label.

### Self-hosted runner terms agreement

If you install self-hosted runners through the web app, an organization admin must agree to the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/) at **Org** > **Runners**. If you install and use self-hosted runners through the CLI, you agree to the CircleCI Runner Terms.

## Get the files

Clone the repository at a release tag, or extract a release bundle. Paths on this page are relative to the root of either. The [GitHub release](https://github.com/CircleCI-Labs/scalable-machine-runner/releases) has the `machine-runner-swarm-<version>.zip` bundle for Windows, and the Linux page lists [every file of a release](install-linux.md#get-the-files).

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
   foreach ($file in "machine-runner-swarm-$version.zip", 'SHA256SUMS', 'SHA256SUMS.sigstore.json') {
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
   $zip = "machine-runner-swarm-$version.zip"
   $expected = ((Select-String -Path SHA256SUMS -Pattern ([regex]::Escape($zip))).Line -split '\s+')[0]
   $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
   if ($actual -ne $expected) { throw "SHA-256 mismatch for $zip" } else { "$zip OK" }
   ```

Do not use a bundle if a command fails.

## 1. Create the resource classes

Create a namespace if your organization has none.

```console
$ circleci namespace create <namespace> --org <org>
```

Create one resource class for each service in the stack files. The class name must equal the service name. The shipped file `windows\stack\runners.yaml` has the service `windows-default` and deploys on its own. The optional add-on stack files in the same directory add `windows-custom` (`custom-image.yaml`), `windows-persistent` (`persistent.yaml`), and `windows-docker-build` (`docker-build.yaml`). Create the classes you plan to use.

```console
$ circleci runner resource-class create <namespace>/windows-default --org <org> --generate-token
```

The command prints the token once. Store it in your secret manager.

## 2. Prepare each host

Run these steps in an elevated PowerShell on every host. Do them before you start Swarm. The network of the host drops for a few seconds after `docker swarm init`, and the downloads and pulls need it.

1. Confirm that Docker runs Windows containers. The command prints `windows`.

   ```powershell
   docker info --format '{{.OSType}}'
   ```

2. Pull the base image of the shipped services once, so the first task does not wait for it. A Server 2025 host runs `ltsc2022` images too, so this is the image for both hosts. Pull `ltsc2025` as well only for a service that you put on that image.

   ```powershell
   docker pull mcr.microsoft.com/windows/servercore:ltsc2022
   ```

## 3. Stage the runner and Git

The stack mounts the host directory `C:\machine-runner-swarm` read-only into every container, and mounts `C:\machine-runner-swarm\git` at `C:\Program Files\Git`. The stock Server Core image therefore needs no changes. No entrypoint script exists on Windows, because `circleci-runner.exe` is the main process of the container.

| Path | Content |
|---|---|
| `C:\machine-runner-swarm\bin\circleci-runner.exe` | Machine runner 3 binary |
| `C:\machine-runner-swarm\git\` | Portable Git for Windows, with `git`, `bash`, `sh`, `tar`, `gzip`, and `ssh` |
| `C:\machine-runner-swarm\VERSION` | The runner and Git versions |

The task agent runs `C:\Program Files\Git\usr\bin\tar.exe` for workspaces, and it runs steps with `bash`. MinGit has no `tar`, `gzip`, or `bash`, so the stack uses PortableGit. The download is about 60 MB, and the unpacked tree is about 406 MB in 9,600 files.

The task agent starts `tar.exe` with `--force-local`, from the root of the drive, and with forward-slash operands that are relative to that root. For example, it passes `foo/bar` for `C:\foo\bar`. A backslash operand makes the tar of Git fail with `Cannot stat`, so use the forward-slash form when you test `tar` by hand.

Run the following in an elevated PowerShell. It downloads each file, verifies its SHA-256 checksum, and fills `C:\machine-runner-swarm\<runner version>`, and then points the junction `C:\machine-runner-swarm\current` at that directory. The stack mounts the junction, so a new version later goes next to this one, and the junction moves. The Git and 7-Zip checksums are the values pinned in `windows\Setup.ps1`, and the runner checksum comes from the CircleCI release manifest.

```powershell
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$swarm = 'C:\machine-runner-swarm'
$runnerVersion = '3.1.12'
$dir = "$swarm\$runnerVersion"
$gitVersion = '2.56.0.2'
$gitTag = 'v2.56.0.windows.2'
$gitSha = '075e158ef8e1f0ab80b347e245405d3eca735c2dc88fd8e032e137d0ca61f61b'
$sevenZipVersion = '26.04'
$sevenZipSha = '256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282'
$work = Join-Path $env:TEMP 'swarm-stage'
New-Item -ItemType Directory -Force "$dir\bin", "$dir\git", $work | Out-Null

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
& "$env:SystemRoot\System32\tar.exe" -xzf "$work\runner.tar.gz" -C "$dir\bin"

# Portable Git, unpacked with the standalone 7-Zip extractor
Get-Verified "https://github.com/ip7z/7zip/releases/download/$sevenZipVersion/7zr.exe" "$work\7zr.exe" $sevenZipSha
Get-Verified "https://github.com/git-for-windows/git/releases/download/$gitTag/PortableGit-$gitVersion-64-bit.7z.exe" "$work\pgit.exe" $gitSha
& "$work\7zr.exe" x -y "-o$dir\git" "$work\pgit.exe"

# Git's post-install scripts, once, so the tree is ready to mount read-only
& "$dir\git\usr\bin\bash.exe" --norc -c 'export PATH=/usr/bin:/ucrt64/bin:/mingw64/bin:/cmd:$PATH; export SYSCONFDIR=/etc; for p in $(export LC_COLLATE=C; echo /etc/post-install/*.post); do test -e "$p" && . "$p"; done'
Remove-Item "$dir\git\post-install.bat" -ErrorAction SilentlyContinue
Set-Content "$dir\VERSION" "runner=$runnerVersion", "git=$gitVersion" -Encoding ASCII
Remove-Item $work -Recurse -Force
```

The script uses the `tar.exe` in `System32` on purpose. A GNU `tar` from another Git on the `PATH` of the host reads `C:\machine-runner-swarm\3.1.12\bin` as a remote host name.

A `PsExec64.exe` on the `PATH` of the host does not matter. The stack sets the `PATH` of the containers in full, so the host `PATH` never reaches them.

### Set the access rights and the junction

Containers with process isolation open the bind mounts as an identity that does not exist on the host. Microsoft says to grant access to Authenticated Users. `Setup.ps1` sets these rights, and you set them by hand as follows.

| Account | Right |
|---|---|
| `SYSTEM` | Full control |
| `Administrators` | Full control |
| `Authenticated Users` | Read and execute |

```powershell
$rights = '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-11:(OI)(CI)RX'
icacls $swarm /inheritance:r /grant:r $rights
icacls $dir /inheritance:r /grant:r $rights
icacls "$dir\*" /reset /T /C /Q
if (Test-Path "$swarm\current") { cmd /c rmdir "$swarm\current" }
New-Item -ItemType Junction -Path "$swarm\current" -Target $dir | Out-Null
```

The first two `icacls` commands set the rights on a directory only, and cut the inheritance from `C:\`. The first one protects `C:\machine-runner-swarm`, so nobody else can replace the junction. The third command resets every file below the version directory to inherit them. Do not combine the second and the third with `/T` in one call, because that leaves the files with an empty access list, and the container then fails with `Access is denied`. `cmd /c rmdir` removes the junction and never the directory behind it.

A job cannot change the files. Authenticated Users can read and run them but not write, and the mounts are read-only. Hyper-V isolation opens bind mounts as `LocalSystem` instead, and this repository does not test it. Windows can bind-mount only directories, which is why the junction and `git` are directories and the runner config is a Swarm secret and not a mounted file.

Check the result. The first command prints the runner version, and the second prints the Git version.

```powershell
C:\machine-runner-swarm\current\bin\circleci-runner.exe --version
C:\machine-runner-swarm\current\git\cmd\git.exe --version
```

Repeat this step on every Windows host. The directory must exist on each host that can run a service.

## 4. Start Swarm and label the node

On the first host, start Swarm. Always pass `--advertise-addr` with the IPv4 address of the host. A plain `docker swarm init` fails on some hosts with `could not find the system's IP address`, and a host with several network adapters needs the address to pick the right one.

```powershell
docker swarm init --advertise-addr <host IPv4 address>
```

The network of the host drops for a few seconds after this command, so run it after steps 2 to 4. For more than one node, refer to [Multi-Node Clusters](multi-node.md).

Label the node with the image tags it can run. A Server 2022 node gets one label, and a Server 2025 node gets both.

```powershell
docker node update --label-add machine-runner-swarm.windows-ltsc2022=true <node name>
docker node update --label-add machine-runner-swarm.windows-ltsc2025=true <node name>   # Server 2025 only
```

The optional classes need one more label each. Add it to the nodes that run them:

| Class | Label |
|---|---|
| `windows-docker-build` | `machine-runner-swarm.docker-build=true` |
| `windows-persistent` | `machine-runner-swarm.class.windows-persistent=true` |

## 5. Create the secrets

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
$file = Join-Path $env:TEMP 'circleci-runner-config.yaml'
[IO.File]::WriteAllText($file, "api:`n  auth_token: $token`n", (New-Object Text.UTF8Encoding($false)))
docker secret create "$class-token" $file
Remove-Item -LiteralPath $file -Force
```

Windows does not support the `uid`, `gid`, and `mode` options of secrets. Only administrators and `SYSTEM` can read the file inside the container, and jobs run as an administrator. Swarm also writes the secret in clear text to the disk of the container until the container stops, which is a Swarm limitation on Windows. Linux keeps the secret in memory. Enable BitLocker on the Docker volume. Refer to [Token model on each OS](security.md#token-model-on-each-os).

## 6. Review the stack file

Copy the stack files that you deploy into a directory of your own, `deploy\`, and keep it under version control. From here on, you check and deploy your copies and never the files under `windows\stack`, so an edit never touches the shipped files. For a first run, change nothing: the copy of `runners.yaml` works as it is, and you review it later.

```powershell
New-Item -ItemType Directory -Force deploy | Out-Null
Copy-Item windows\stack\runners.yaml deploy\runners.yaml
```

The stack files use absolute host paths, so they work from any directory. Copy each optional file that you use the same way, for example `Copy-Item windows\stack\custom-image.yaml deploy\`. Review these settings first. Refer to [Resource Classes](resource-classes.md) for the details.

| Service | File | Purpose |
|---|---|---|
| `windows-default` | `runners.yaml` | Stock Server Core image, two replicas |
| `windows-custom` | `custom-image.yaml` | Your own image on top of stock Server Core. Refer to [Images](images.md#windows-bring-your-own-image) |
| `windows-persistent` | `persistent.yaml` | A long-lived runner with a named volume. Refer to [Persistent mode](resource-classes.md#persistent-mode) |
| `windows-docker-build` | `docker-build.yaml` | Builds Windows images with the host engine. Refer to [Docker Builds](docker-builds.md) |

- `runners.yaml` needs only the secret `windows-default-token`. Each add-on stack file needs its own `<service>-token` secret, and `custom-image.yaml` has a placeholder image that you replace with yours.
- A Server 2025 node runs the shipped `ltsc2022` services. For a class on the `ltsc2025` image, copy a service under a new name and resource class, use the `ltsc2025` image tag, and set the constraint `node.labels.machine-runner-swarm.windows-ltsc2025 == true`.

The optional classes are add-on stack files. Add each with another `-c` flag, and pass the same list of files on every deploy ([how the files merge](concepts.md#add-on-stack-files-and-how-they-merge)). Each add-on stack file repeats the anchors of `runners.yaml`, because an anchor does not reach into another file. When you change a common setting, change it in every file that you use.

Check that your copies parse. This needs no running Swarm.

```powershell
docker stack config -c deploy\runners.yaml | Out-Null
```

With the optional files, pass them all, in the same order as you deploy them:

```powershell
docker stack config -c deploy\runners.yaml -c deploy\custom-image.yaml -c deploy\persistent.yaml -c deploy\docker-build.yaml | Out-Null
```

For the keys that Windows honours and the keys that it ignores, refer to [Stack keys on Windows](resource-classes.md#stack-keys-on-windows).

## 7. Deploy the stack

Deploy your copy of the file from step 6:

```powershell
docker stack deploy -c deploy\runners.yaml runners
```

To add the optional classes, pass your copies of their files after `runners.yaml` with more `-c` flags, for example your own image on top of stock Server Core:

```powershell
docker stack deploy -c deploy\runners.yaml -c deploy\custom-image.yaml runners
```

The bind source of the runner mount is the junction `C:\machine-runner-swarm\current`. A new runner version needs no deploy: refer to [Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows).

## Verify the deployment

1. List the services and tasks.

   ```powershell
   docker stack services runners
   docker stack ps runners --no-trunc
   ```

2. Check that the runners connected. `circleci runner instance list --org <org> --resource-class <namespace>/windows-default` lists each replica with the status `online`, and the web app shows the same under **Runners**. A replica has a name of the form `<node hostname>-<service>-<slot>`.

3. Run a job. The [quickstart](quickstart-windows.md#steps) has a complete config, and [`examples/windows-job.yml`](../examples/windows-job.yml) has more steps. Run the workflow twice. The two runs print different values for `$MACHINE_RUNNER_SWARM_INSTANCE_ID`, because each job runs in a new container.

## What jobs can use

- The default shell is Git Bash (`bash -eo pipefail`). Set `shell: powershell.exe -ExecutionPolicy Bypass` for Windows PowerShell 5.1, or `shell: cmd.exe`, per job or step.
- The working directory is `C:\cci\w`, and the task agent lives in `C:\cci\agent`.
- The `PATH` of the service reaches every step, because the runner passes its environment to the task agent and the task agent passes it to the steps.
- `checkout`, caches, test results, and artifacts need Git and outbound access. Workspaces use the `tar` and `gzip` from the mounted Git. Caches and test results use built-in code.
- OpenID Connect tokens need a writable `%TEMP%`.
- The stack enables Git long paths through the environment. The Windows registry value `LongPathsEnabled` is not set. A job that needs long paths for other tools sets the value itself, or sets it in its own image.
- Not supported: desktop or UI automation, Docker commands in jobs (except the opt-in docker-build class), and service containers.
- Not tested: `add_ssh_keys`, Hyper-V isolation, group managed service accounts, and proxies.
- The variables `MACHINE_RUNNER_SWARM_JOB_SUDO` and `MACHINE_RUNNER_SWARM_JOB_USER` of the Linux entrypoint do not exist on Windows, and Windows ignores them. There is no step-down.

## Optional: use the setup helper

`windows\Setup.ps1` stages `C:\machine-runner-swarm\<version>` and the `current` junction, starts Swarm on request, labels the node, creates the secrets, and deploys, with checks. It runs in an elevated Windows PowerShell 5.1 session and is safe to run again. It prints `CHECK <name> PASS` or `FAIL` for each preflight check: administrator, Windows Server build, Windows-container mode, and Swarm manager.

The helper always stages before it starts Swarm. It does not add the labels of the optional classes.

| Parameter | Effect |
|---|---|
| `-InstallDir` | The directory of the versions and of the `current` junction. The default is `C:\machine-runner-swarm`. The helper stages `<InstallDir>\<RunnerVersion>` |
| `-RunnerVersion` | Runner version. The default is `3.1.12`. The checksum comes from the CircleCI release manifest. A run with another version stages it next to the others and moves `current` to it, and a run with an installed version only moves `current` back |
| `-StageOnly` | Stops after staging. Needs no Docker |
| `-InitSwarm -AdvertiseAddr <ip>` | Creates a Swarm when none exists. The address is required, and the helper waits until the node is a manager |
| `-Class <name>,<name>` | Asks for each token with hidden input and creates the secret `<name>-token`. An existing secret stays unchanged |
| `-Deploy` | Runs `docker stack deploy` with `-StackFile` (one or more files, `runners.yaml` first) and `-StackName` (default `runners`). Without `-StackFile` it deploys the shipped `windows\stack\runners.yaml` as it is, which suits a first run. Once you keep copies as in step 6, pass them. The helper prints the files that it deploys |
| `-Force` | Stages again even when the same versions are present |

The helper labels the node from the host build: `machine-runner-swarm.windows-ltsc2022=true` on Server 2022, and both `windows-ltsc2022=true` and `windows-ltsc2025=true` on Server 2025. It supports Server 2022 and 2025 only. Server 2019 is untested and gets no label.

The first example is a first run: it deploys the shipped `runners.yaml` unchanged. The second deploys your copy from step 6, with its optional file.

```powershell
.\windows\Setup.ps1 -InitSwarm -AdvertiseAddr 10.0.0.5 -Class windows-default -Deploy
.\windows\Setup.ps1 -Class windows-default,windows-custom -StackFile .\deploy\runners.yaml,.\deploy\custom-image.yaml -Deploy
```

## Upgrade

Refer to [Upgrade the runner and images](operations.md#upgrade-the-runner-and-images). Stage a new version in its own directory next to the others. Never overwrite a version directory while containers use it, because Windows cannot replace files that are in use.

## Stop and uninstall

Refer to [Uninstall](operations.md#uninstall). Every stop of a service, including a scale down, a rolling update, and a node drain, ends the containers. A running job is killed after about 5 seconds. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

## Troubleshooting

Refer to [Troubleshooting](troubleshooting.md#windows). The most common problems are an image tag that does not match the host build, missing access rights on `C:\machine-runner-swarm`, and a job that ends about 5 seconds after a stop. A task also stays pending when no node carries the `machine-runner-swarm.windows-ltsc2022` label (or `windows-ltsc2025`, for a service on an `ltsc2025` image).

## Additional resources

- [Concepts](concepts.md)
- [Resource Classes](resource-classes.md)
- [Security](security.md)
- [Operations](operations.md)
- [Machine runner 3 on Windows](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-windows/)
