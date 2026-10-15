---
page-title: Images
page-audience: admin
page-description: Run the runner in stock Linux and Windows images with a read-only mount, and bring your own image.
---

# Images

This repository publishes no class images. (It publishes one image, the token proxy, which holds the class tokens and is no environment for a job: [The token proxy image](install-linux.md#the-token-proxy-image).) The stack files run stock images and mount the runner into them, so the image of a class is the environment that its jobs see. This page describes the stock Linux images, the stock Windows image, and how to bring your own image on each OS.

## Linux: stock images with the mounted runner

The statically linked runner binary lives in the per-node volume `runner-bin`, which the `runner-distributor` service fills. In the volume, the link `current` points to the active version, `versions/<version>/bin/circleci-runner`. The stack mounts the volume read-only at `/opt/machine-runner-swarm` in every container. The entrypoint, `circleci-runner-entrypoint`, is a Swarm config that the stack mounts at `/circleci-runner-entrypoint` with the mode `0555`. The service sets `entrypoint: ["/circleci-runner-entrypoint"]` and `user: "0"`. The entrypoint starts as root, checks the runner against its SHA-256 record, prepares the users, and then runs the runner as `circleci-runner`.

The result is that the image contains none of the runner. You can use `cimg/base` or `cimg/openjdk:21.0` unmodified, and a new runner version needs no image rebuild and no restart of a runner service. Refer to [The runner distributor on Linux](concepts.md#the-runner-distributor-on-linux) and [Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux).

The shipped file uses these images:

| Service | File | Image |
|---|---|---|
| `linux-default` | `runners.yaml` | `cimg/base:2026.10` |
| `linux-java` | `classes-extra.yaml` | `cimg/openjdk:21.0` |
| `linux-hardened` | `classes-extra.yaml` | `cimg/base:2026.10` |

### What an image needs

| Requirement | Why |
|---|---|
| Linux, any C library | The runner is statically linked. It runs unmodified in `cimg/base`, `cimg/openjdk`, Alpine, and UBI minimal |
| `sudo`, or util-linux `setpriv` | Steps each job down to the job user. The hardened class (`MACHINE_RUNNER_SWARM_JOB_SUDO=false`) needs util-linux `setpriv` with `--no-new-privs`, even when the image has sudo |
| `setpriv` or `su` | Starts the runner as `circleci-runner` |
| `useradd` or `adduser` | Creates `circleci-runner`, and the job user when the image has none |
| `sed`, `grep`, `stat`, `install`, `getent`, `id`, `cut`, `tr`, `chmod`, `env`, `sha256sum`, `readlink`, `sleep` | Used by the entrypoint. BusyBox and coreutils both provide them |
| `wget` or `curl`, `tar`, `awk`, `mktemp`, `mv`, `chown` | Only for a [microVM class](microvm.md#the-runner-in-a-vm), whose entrypoint downloads the runner into the container. The `cimg` images have them |

The `cimg` images have everything. Alpine has only the BusyBox `su`, and UBI minimal has neither `sudo` nor `setpriv`. The tests run the entrypoint in `cimg/base` 2026.10, `cimg/openjdk` 21.0, Alpine 3 (with sudo and with `setpriv`), and UBI 9 minimal. Add the packages in a derived image:

| Base | Add |
|---|---|
| Debian and Ubuntu | `apt-get install sudo` |
| Alpine | `apk add sudo setpriv` |
| UBI minimal | `microdnf install sudo util-linux`. The `util-linux-core` package is not enough |

The entrypoint exits with code 80 and a message that names the packages when the tools are missing. The unit tests of the entrypoint cover the `setpriv` path, and the token test runs the hardened step-down against the real runner. The end-to-end CI jobs run real jobs through the sudo path in the default class and through the `setpriv --no-new-privs` path in the hardened class.

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

The Dockerfile has one target. It adds tools to a stock image and nothing of the runner, so the image needs no rebuild for a new runner version. It ends with `USER circleci`, which only affects a plain `docker run` of the image. The stack starts the container as root so that the entrypoint can create users.

## Windows: stock Server Core with mounts

The default Windows service runs the unmodified Microsoft Server Core image, for example `mcr.microsoft.com/windows/servercore:ltsc2022`. Two read-only mounts of the per-node volume `runner-bin`, which the service `runner-distributor-windows` fills, add what the runner needs:

| Volume path (`volume.subpath`) | Container path | Content |
|---|---|---|
| `current` | `C:\machine-runner-swarm` | `bin\circleci-runner.exe`, the record `SHA256`, and `VERSION` |
| `git\current` | `C:\Program Files\Git` | Portable Git for Windows: `git`, `bash`, `sh`, `tar`, `gzip`, `ssh` |

`current` and `git\current` are relative directory symbolic links, to `versions\<version>` and to the pinned Git, which the distributor moves. Docker resolves a link when it creates a container, so a new runner version reaches the next container only, and a running job keeps its version. Docker refuses a junction or an absolute link in a subpath. Refer to [Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows).

The runner is the main process of the container. The service sets `entrypoint` to `C:\machine-runner-swarm\bin\circleci-runner.exe machine --config C:\ProgramData\Docker\secrets\circleci_runner_config.yaml`. The service also sets the full `PATH`, because a `PATH` in the service environment replaces the one of the image. Git for Windows appears after the Windows directories, so the Windows `find`, `sort`, and `tar` stay first. The runner passes its environment to the task agent, and the task agent passes it to every step, so jobs see this `PATH`.

The system Git configuration is in the read-only Git mount, so the service sets Git options through the environment: `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_0`, and `GIT_CONFIG_VALUE_0` enable `core.longpaths`. `GIT_TERMINAL_PROMPT=0` and `GCM_INTERACTIVE=never` stop the prompts of the Git Credential Manager, which nothing in a container can answer.

Pin the image with a digest, and rebuild or redeploy when Microsoft republishes the tag. Microsoft updates the tags each Patch Tuesday.

```console
$ docker buildx imagetools inspect mcr.microsoft.com/windows/servercore:ltsc2022
```

Nano Server is not supported. Windows images must match the host build. Refer to [Image tags and host builds](install-windows.md#image-tags-and-host-builds).

## Windows: bring your own image

Add tools in an image on top of stock Server Core. The image holds the tools only. The host still provides the runner and Git through the mounts, and the stack file still sets `entrypoint` and the full `PATH`, so add the directory of your tool to that `PATH`.

The file [`windows/images/example/Dockerfile`](../windows/images/example/Dockerfile) is a generic example. It starts from stock Server Core and adds Node.js from the official zip, pinned by version and SHA-256. Copy it and swap the tool. Keep the pattern:

1. Start `FROM` the stock Server Core image of your host's tag.
2. Download a pinned release, and verify its SHA-256 checksum before you use it.
3. Install the tool in a fixed directory, and add that directory to the `PATH` of the service in `windows\stack\custom-image.yaml`.
4. Check that the tool runs. Leave `USER` alone: the runner needs `ContainerAdministrator`, which creates symbolic links for the task agent.

Do not put `PsExec64.exe` on the `PATH` of the image or of the service. With it, the task agent switches to a desktop wrapper that containers cannot run. A `PsExec64.exe` on the `PATH` of the host does not matter, because the stack sets the `PATH` of the container in full.

Build the example from the root of the repository. The build context is the `windows` directory.

```powershell
docker build -f windows/images/example/Dockerfile --build-arg WINDOWS_TAG=ltsc2022 -t machine-runner-swarm-windows-example:ltsc2022 windows
```

Push the result to a registry that every Windows node can pull from, because Swarm does not share local images. Then set the image of the `windows-custom` service in `windows\stack\custom-image.yaml`, an add-on stack file, and create the resource class and the secret `windows-custom-token` for it. Deploy it with `-c windows\stack\runners.yaml -c windows\stack\custom-image.yaml`. The file [`examples/windows-custom-image.yml`](../examples/windows-custom-image.yml) shows a job on that class. Rebuild the image when the base image or a tool changes.

A stop of a busy Windows container kills its job after about 5 seconds, with stock images and with your own. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container), which also shows an optional image that lifts the limit.
