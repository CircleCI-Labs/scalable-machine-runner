---
page-title: Images
page-audience: admin
page-description: Run the runner in stock Linux and Windows images with a read-only mount, bring your own image, or bake the runner into a Windows image.
---

# Images

This repository publishes no images. The stack files run stock images and add the runner from the host, so the image of a class is the environment that its jobs see. This page describes the stock Linux images, how to bring your own image, and the Windows options, including the stop-timeout image that Windows stock-image services need.

## Linux: stock images with the mounted runner

The statically linked runner binary and `circleci-runner-entrypoint` live on the host in `/opt/machine-runner-swarm`. The stack mounts that directory read-only at the same path in every container, and sets `entrypoint: ["/opt/machine-runner-swarm/bin/circleci-runner-entrypoint"]` and `user: "0"`. The entrypoint starts as root, prepares the users, and then runs the runner as `circleci-runner`.

The result is that the image contains none of the runner. You can use `cimg/base` or `cimg/openjdk:21.0` unmodified, and a new runner version needs no image rebuild.

The shipped file uses these images:

| Service | Image |
|---|---|
| `linux-default` | `cimg/base:2026.10` |
| `linux-java` | `cimg/openjdk:21.0` |
| `linux-hardened` | `cimg/base:2026.10` |

### What an image needs

| Requirement | Why |
|---|---|
| Linux, any C library | The runner is statically linked. It runs unmodified in `cimg/base`, `cimg/openjdk`, Alpine, and UBI minimal |
| `sudo`, or util-linux `setpriv` | Steps each job down to the job user |
| `setpriv` or `su` | Starts the runner as `circleci-runner` |
| `useradd` or `adduser` | Creates `circleci-runner`, and the job user when the image has none |
| `sed`, `grep`, `stat`, `install`, `getent`, `id`, `cut`, `tr`, `chmod`, `env` | Used by the entrypoint. BusyBox and coreutils both provide them |

The `cimg` images have everything. Alpine has only the BusyBox `su`, and UBI minimal has neither `sudo` nor `setpriv`. The tests run the entrypoint in `cimg/base` 2026.10, `cimg/openjdk` 21.0, Alpine 3 (with sudo and with `setpriv`), and UBI 9 minimal. Add the packages in a derived image:

| Base | Add |
|---|---|
| Debian and Ubuntu | `apt-get install sudo` |
| Alpine | `apk add sudo setpriv` |
| UBI minimal | `microdnf install sudo util-linux`. The `util-linux-core` package is not enough |

The entrypoint exits with code 80 and a message that names the packages when the tools are missing. The unit tests of the entrypoint cover the `setpriv` path. The end-to-end CI jobs run real jobs through the sudo path only, because the CI image has sudo.

The job user is `circleci` by default. Set `MACHINE_RUNNER_SWARM_JOB_USER` to another existing account, such as the default account of a different image. If the account does not exist, the entrypoint creates it with uid 2001, and gives it passwordless sudo while `MACHINE_RUNNER_SWARM_JOB_SUDO` is `true` and the image has sudo. The image environment variables, such as `PATH`, `JAVA_HOME`, `LANG`, and proxy variables, reach the jobs. The runner token does not.

### Pin the image

Tags such as `21.0` move when the publisher rebuilds the image. Pin production services by digest and update them on a schedule:

```yaml
image: cimg/base:2026.10@sha256:<digest>
```

```console
$ docker buildx imagetools inspect cimg/base:2026.10
```

## Linux: bring your own image

Build an image when jobs need tools that you do not want to install in every job. This is also the way to run a hardened class, because jobs there have no sudo.

The file [`linux/images/example/Dockerfile`](../linux/images/example/Dockerfile) starts from a `cimg` image and adds `postgresql-client`. Copy it and replace the packages.

```console
$ docker build -t registry.example.com/ci/linux-pg:1 linux/images/example
$ docker push registry.example.com/ci/linux-pg:1
```

Then set the image of a service in your stack file:

```yaml
image: registry.example.com/ci/linux-pg:1
```

Every node that runs the service must be able to pull the image. Refer to [Registry needs](multi-node.md#registry-needs). Rebuild the image when its base changes, for example once a month.

The Dockerfile ends with `USER circleci`, which only affects a plain `docker run` of the image. The stack starts the container as root so that the entrypoint can create users.

### The baked variant

The target `baked` puts the runner and the entrypoint inside the image, for hosts where you cannot mount `/opt/machine-runner-swarm`. Build it from the root of the repository, because it copies `linux/setup.sh` and `linux/entrypoint/circleci-runner-entrypoint`:

```console
$ docker build -f linux/images/example/Dockerfile --target baked \
    -t registry.example.com/ci/linux-pg:1-baked .
```

The build downloads the runner and verifies its SHA-256 checksum, as `setup.sh` does on a host. A service that uses the baked image keeps the same `entrypoint`, and needs no `/opt/machine-runner-swarm` volume. The trade-off is a rebuild for every runner version.

## Windows: stock Server Core with mounts

The default Windows service runs the unmodified Microsoft Server Core image, for example `mcr.microsoft.com/windows/servercore:ltsc2022`. Two read-only mounts from the host add what the runner needs:

| Host path | Container path | Content |
|---|---|---|
| `C:\machine-runner-swarm` | `C:\machine-runner-swarm` | `bin\circleci-runner.exe` and `VERSION` |
| `C:\machine-runner-swarm\git` | `C:\Program Files\Git` | Portable Git for Windows: `git`, `bash`, `sh`, `tar`, `gzip`, `ssh` |

The runner is the main process of the container. The service sets `entrypoint` to `C:\machine-runner-swarm\bin\circleci-runner.exe machine --config C:\ProgramData\Docker\secrets\circleci_runner_config.yaml`. The service also sets the full `PATH`, because a `PATH` in the service environment replaces the one of the image. Git for Windows appears after the Windows directories, so the Windows `find`, `sort`, and `tar` stay first. The runner passes its environment to the task agent, and the task agent passes it to every step, so jobs see this `PATH`.

The system Git configuration is in the read-only Git mount, so the service sets Git options through the environment: `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_0`, and `GIT_CONFIG_VALUE_0` enable `core.longpaths`. `GIT_TERMINAL_PROMPT=0` and `GCM_INTERACTIVE=never` stop the prompts of the Git Credential Manager, which nothing in a container can answer.

Pin the image with a digest, and rebuild or redeploy when Microsoft republishes the tag. Microsoft updates the tags each Patch Tuesday.

```console
$ docker buildx imagetools inspect mcr.microsoft.com/windows/servercore:ltsc2022
```

Nano Server is not supported. Windows images must match the host build. Refer to [Image tags and host builds](install-windows.md#image-tags-and-host-builds).

## Windows: the stop-timeout image

> [!IMPORTANT]
> Use the stop-timeout image for every stock-image Windows service. A plain Server Core container ends about 5 seconds after any stop, so a rolling update, a scale down, or a node drain kills the running job. The container exits with the code 3221225786 (`0xC000013A`).

When Docker stops a container, Windows sends the shutdown event to it, and the runner drains on that event. On Server Core, Windows then waits only the time in the registry value `HKLM\SYSTEM\CurrentControlSet\Control\WaitToKillServiceTimeout` before it ends the processes. The default is 5 seconds, whatever `docker stop -t` or `stop_grace_period` says. No setting in the stack file changes this limit, so the fix is in the image.

The image `windows/images/stop-timeout` is the stock Server Core image plus that one value. Everything else stays stock, so the service still mounts `C:\machine-runner-swarm` and Git and sets its `PATH`. Build it for each tag that you run. The build context is the directory of the Dockerfile.

```powershell
docker build -f windows/images/stop-timeout/Dockerfile --build-arg WINDOWS_TAG=ltsc2022 `
  -t registry.example.com/ci/servercore-stop:ltsc2022 windows/images/stop-timeout
docker build -f windows/images/stop-timeout/Dockerfile --build-arg WINDOWS_TAG=ltsc2025 `
  -t registry.example.com/ci/servercore-stop:ltsc2025 windows/images/stop-timeout
```

| Build argument | Default | Purpose |
|---|---|---|
| `WINDOWS_TAG` | `ltsc2022` | The Server Core tag. It must match the host build. You can pass `ltsc2022@sha256:<digest>` |
| `BASE_IMAGE` | `mcr.microsoft.com/windows/servercore:${WINDOWS_TAG}` | Another Server Core based image |
| `SHUTDOWN_TIMEOUT_SECONDS` | `18300` | How long Windows waits at shutdown. The image stores it in milliseconds. Use at least `max_run_time` plus the drain margin. The default is 5 hours plus 5 minutes, the same as `stop_grace_period` |

Set `image:` of each stock-image service to the result, then push it to a registry that every Windows node can pull from. A single node can use the local image with `docker stack deploy --resolve-image never`. Rebuild the image when Microsoft republishes the base tag. The baked image sets the same value, and an image that you derive from the baked image keeps it. Nano Server images do not have this limit, but this repository does not support Nano Server.

> [!WARNING]
> Never use `New-Item -Force` on an existing registry key when you build an image. It replaces the key and deletes its values and subkeys. On `HKLM:\SYSTEM\CurrentControlSet\Services\cexecsvc`, it removes the definition of the container exec service, and the container fails to start with `hcs::System::Start: context deadline exceeded`. Use `reg add` or `Set-ItemProperty`, which set one value and leave the rest of the key alone.

For how stops and rolling updates behave, and for what to do on the plain image, refer to [Windows drain](operations.md#windows-drain).

## Windows: the baked image

The baked image holds the runner and Git inside the image, at the same paths as the mounts. Use it when you want one self-contained artifact, when you add tools on top, or when a host cannot hold `C:\machine-runner-swarm`. The runner is its `ENTRYPOINT` with the same `--config` path, so a service that uses it needs no mounts, no `PATH`, and no `entrypoint`. The build puts Git on the machine `PATH`, enables `core.longpaths` in the system Git configuration, and removes the credential helper.

Build it from the root of the repository. The build context is the `windows` directory.

```powershell
docker build -f windows/images/servercore/Dockerfile --build-arg WINDOWS_TAG=ltsc2022 -t machine-runner-swarm-windows-servercore:ltsc2022 windows
```

| Build argument | Default | Purpose |
|---|---|---|
| `WINDOWS_TAG` | `ltsc2022` | The Server Core tag. It must match the host build. You can pass `ltsc2022@sha256:<digest>` |
| `BASE_IMAGE` | `mcr.microsoft.com/windows/servercore:${WINDOWS_TAG}` | Another Server Core based image. It needs Windows PowerShell 5.1 and `tar.exe` |
| `RUNNER_VERSION`, `RUNNER_SHA256` | `3.1.12` and its checksum | The runner build |
| `GIT_VERSION`, `GIT_RELEASE_TAG`, `GIT_SHA256` | Pinned in the file | The portable Git build |
| `SEVENZIP_VERSION`, `SEVENZIP_SHA256` | Pinned in the file | The extractor for portable Git |
| `SHUTDOWN_TIMEOUT_SECONDS` | `18300` | How long Windows waits for processes at container shutdown, so a stop lets a running job finish. Refer to [the stop-timeout image](#windows-the-stop-timeout-image) |

The image runs as `ContainerAdministrator`. The runner creates a symbolic link when it installs the task agent, and an account without that privilege makes the runner retry the download forever. Never change `USER` in a derived image.

The build fails with `PsExec64.exe must not be on PATH in the image` when the base image has `PsExec64.exe` on its `PATH`. With it, the task agent switches to a desktop wrapper that containers cannot run. Use a base image without it. A `PsExec64.exe` on the `PATH` of the host does not matter.

### Add your own tools

The file [`windows/images/example/Dockerfile`](../windows/images/example/Dockerfile) is a generic example. It starts from the baked image and adds Node.js from the official zip, pinned by version and SHA-256. Copy it and swap the tool. Keep the pattern:

1. Start `FROM` the baked image. It has the runner as `ENTRYPOINT` and Git on the `PATH`.
2. Download a pinned release, and verify its SHA-256 checksum before you use it.
3. Add the tool to the machine `PATH`.
4. Check that the tool runs. Leave `USER` and `ENTRYPOINT` alone.

Build the baked image first, then the example:

```powershell
docker build -f windows/images/servercore/Dockerfile --build-arg WINDOWS_TAG=ltsc2022 -t machine-runner-swarm-windows-servercore:ltsc2022 windows
docker build -f windows/images/example/Dockerfile --build-arg BASE_IMAGE=machine-runner-swarm-windows-servercore:ltsc2022 -t machine-runner-swarm-windows-example:ltsc2022 windows
```

Push the result to a registry that every Windows node can pull from, because Swarm does not share local images. Then set the image of the `windows-custom` service in `windows\stack\custom-image.yaml`, an optional overlay file, and create the resource class and the secret `windows-custom-token` for it. Deploy it with `-c windows\stack\runners.yaml -c windows\stack\custom-image.yaml`. The file [`examples/windows-custom-image.yml`](../examples/windows-custom-image.yml) shows a job on that class. Rebuild the image when the base image or a tool changes.
