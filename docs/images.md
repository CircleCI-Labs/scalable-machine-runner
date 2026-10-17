---
page-title: Images
page-audience: admin
page-description: Run the runner in stock Linux and Windows images with a read-only mount, and bring your own image.
---

# Images

The stack files run stock images and mount the runner into them, so the image of a class is the environment its jobs see. Machine runner swarm publishes no class image. Its one image, the token proxy, holds the class tokens and is no environment for a job ([The token proxy image](install-linux.md#the-token-proxy-image)). This page covers the stock images and how to bring your own on each OS.

## Linux: stock images with the mounted runner

The statically linked runner lives in the per-node volume `runner-bin`, which the `runner-distributor` service fills. The stack mounts it read-only at `/opt/machine-runner-swarm` in every container, with `current` pointing to the active version. The entrypoint, a Swarm config mounted at `/circleci-runner-entrypoint`, starts as root, checks the runner against its SHA-256 record, prepares the users, and runs the runner as `circleci-runner`.

The image contains none of the runner, so a new runner version needs no image rebuild and no restart ([The runner distributor on Linux](concepts.md#the-runner-distributor-on-linux), [Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux)).

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
| `wget` or `curl`, `tar`, `awk`, `mktemp`, `mv`, `chown` | Only for a [microVM class](microvm.md#the-runner-in-a-vm), whose entrypoint downloads the runner |

The `cimg` images have everything. Alpine has only the BusyBox `su`, and UBI minimal has neither `sudo` nor `setpriv`. The tests run the entrypoint in `cimg/base`, `cimg/openjdk`, Alpine 3 (with sudo and with `setpriv`), and UBI 9 minimal. Add missing packages in a derived image:

| Base | Add |
|---|---|
| Debian and Ubuntu | `apt-get install sudo` |
| Alpine | `apk add sudo setpriv` |
| UBI minimal | `microdnf install sudo util-linux` (`util-linux-core` is not enough) |

The entrypoint exits with code 80 and names the missing packages. The end-to-end CI jobs run real jobs through the sudo path (default class) and the `setpriv --no-new-privs` path (hardened class).

The job user is `circleci` by default. Set `MACHINE_RUNNER_SWARM_JOB_USER` to another existing account. If the account does not exist, the entrypoint creates it with uid 2001, with passwordless sudo while `MACHINE_RUNNER_SWARM_JOB_SUDO` is `true` and the image has sudo. The image environment (`PATH`, `JAVA_HOME`, `LANG`, proxy variables) reaches the jobs. The runner token does not.

### Pin the image

Tags such as `21.0` move when the publisher rebuilds the image. Pin production services by digest and update them on a schedule:

```yaml
image: cimg/base:2026.10@sha256:<DIGEST>
```

```bash
docker buildx imagetools inspect cimg/base:2026.10
```

## Linux: bring your own image

Build an image when jobs need tools that you do not want to install in every job. This is also how a hardened class gets tools, because jobs there have no sudo.

[`linux/images/example/Dockerfile`](../linux/images/example/Dockerfile) starts from a `cimg` image and adds `postgresql-client`. Copy it and replace the packages.

```bash
docker build -t registry.example.com/ci/linux-pg:1 linux/images/example
docker push registry.example.com/ci/linux-pg:1
```

Then set the image of a service in your stack file:

```yaml
image: registry.example.com/ci/linux-pg:1
```

Every node that runs the service must be able to pull the image ([Registry needs](multi-node.md#registry-needs)). Rebuild when the base changes, for example once a month.

The Dockerfile adds tools and nothing of the runner. Its `USER circleci` only affects a plain `docker run`: the stack starts the container as root so that the entrypoint can create users.

## Windows: stock Server Core with mounts

The default Windows service runs the unmodified Microsoft Server Core image, for example `mcr.microsoft.com/windows/servercore:ltsc2022`. Two read-only mounts of the per-node volume `runner-bin`, which `runner-distributor-windows` fills, add what the runner needs:

| Volume path (`volume.subpath`) | Container path | Content |
|---|---|---|
| `current` | `C:\machine-runner-swarm` | `bin\circleci-runner.exe`, the record `SHA256`, and `VERSION` |
| `git\current` | `C:\Program Files\Git` | Portable Git for Windows: `git`, `bash`, `sh`, `tar`, `gzip`, `ssh` |

`current` and `git\current` are relative directory symbolic links, to `versions\<VERSION>` and to the pinned Git, which the distributor moves. Docker resolves a link when it creates a container, so a new runner version reaches the next container only, and a running job keeps its version. Docker refuses a junction or an absolute link in a subpath ([Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows)).

The runner is the main process: the service sets `entrypoint` to `C:\machine-runner-swarm\bin\circleci-runner.exe machine --config C:\ProgramData\Docker\secrets\circleci_runner_config.yaml`. It also sets the full `PATH`, because a `PATH` in the service environment replaces the one of the image. Git for Windows comes after the Windows directories, so the Windows `find`, `sort`, and `tar` stay first.

The Git mount is read-only, so the service sets Git options through the environment: `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_0`, and `GIT_CONFIG_VALUE_0` enable `core.longpaths`, and `GIT_TERMINAL_PROMPT=0` and `GCM_INTERACTIVE=never` stop prompts that nothing in a container can answer.

Pin the image with a digest, and redeploy when Microsoft republishes the tag (each Patch Tuesday).

```powershell
docker buildx imagetools inspect mcr.microsoft.com/windows/servercore:ltsc2022
```

Nano Server is not supported. Windows images must match the host build ([Image tags and host builds](install-windows.md#image-tags-and-host-builds)).

## Windows: bring your own image

Add tools in an image on top of stock Server Core. The host still provides the runner and Git through the mounts, and the stack file still sets `entrypoint` and the full `PATH`, so add the directory of your tool to that `PATH`.

[`windows/images/example/Dockerfile`](../windows/images/example/Dockerfile) adds Node.js from the official zip, pinned by version and SHA-256. Copy it and swap the tool, keeping the pattern:

1. Start `FROM` the stock Server Core image of your host's tag.
2. Download a pinned release, and verify its SHA-256 checksum before you use it.
3. Install the tool in a fixed directory, and add that directory to the `PATH` of the service in `windows\stack\custom-image.yaml`.
4. Check that the tool runs. Leave `USER` alone: the runner needs `ContainerAdministrator`, which creates symbolic links for the task agent.

Do not put `PsExec64.exe` on the `PATH` of the image or of the service: the task agent would switch to a desktop wrapper that containers cannot run.

Build the example from the root of the repository (the build context is the `windows` directory):

```powershell
docker build -f windows/images/example/Dockerfile --build-arg WINDOWS_TAG=ltsc2022 -t machine-runner-swarm-windows-example:ltsc2022 windows
```

Push the result to a registry that every Windows node can pull from, because Swarm does not share local images. Then set the image of the `windows-custom` service in the add-on stack file `windows\stack\custom-image.yaml`, create the resource class and the secret `windows-custom-token`, and deploy with `-c windows\stack\runners.yaml -c windows\stack\custom-image.yaml`. The file [`examples/windows-custom-image.yml`](../examples/windows-custom-image.yml) has a job on that class. Rebuild when the base image or a tool changes.

## Private certificate authorities

The runner, its task agent, and the job steps read the certificate store of the image of their class. To trust a private authority (an inspecting proxy, your CircleCI server, a private registry, or a package host), put it in an image of your own. The stack files need no change. This repository does not test it.

On Linux, add the certificate to the system store, in a Dockerfile on top of your image:

```dockerfile
FROM cimg/base:2026.10@sha256:<DIGEST>
USER root
COPY my-ca.crt /usr/local/share/ca-certificates/my-ca.crt
RUN update-ca-certificates
USER circleci
```

On Windows, add it to the `Root` store on top of stock Server Core. Go reads the Windows certificate store, so the runner needs the authority there:

```dockerfile
FROM mcr.microsoft.com/windows/servercore:ltsc2022
COPY my-ca.cer C:/ca/my-ca.cer
RUN certutil -addstore -f Root C:\ca\my-ca.cer
```

Some tools keep their own bundle: set `NODE_EXTRA_CA_CERTS` for Node.js, `REQUESTS_CA_BUNDLE` for Python `requests`, and the keystore of Java in the image too. On Unix, `SSL_CERT_FILE` replaces the roots of a Go program instead of adding to them, so point it at a bundle with the public roots and yours.

The image does not reach the other components that make TLS calls: the Docker engine of the node (image pulls), the token proxy, and the two runner distributors. [Proxies and certificate authorities, component by component](operations.md#proxies-and-certificate-authorities-component-by-component) lists what each needs, and what does not work.
