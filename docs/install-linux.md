---
page-title: Install on Linux with Docker Swarm
page-audience: admin
page-description: Deploy CircleCI machine runner 3 as a Docker Swarm stack on Ubuntu or RHEL, with one clean container for every job.
---

# Install on Linux with Docker Swarm

This page describes how to deploy CircleCI machine runner 3 as a Docker Swarm stack on Linux. The steps cover a single node, and [Multi-Node Clusters](multi-node.md) extends them to several nodes.

> [!NOTE]
> If you can run Kubernetes, CircleCI recommends [container runner](https://circleci.com/docs/guides/execution-runner/container-runner-installation/) for containerized jobs. CircleCI documents a plain [machine runner 3 on Docker](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-docker/) setup too. This page is a sibling of those pages for teams that run Docker Swarm and want a clean container for every job.

The manual steps come first and need nothing from this repository except two files. The optional [setup helper](#optional-use-the-setup-helper) runs the same steps.

## Prerequisites

- A CircleCI cloud organization and a user who is an organization admin.
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/), signed in.
- One or more Linux nodes with a supported operating system:

  | Operating system | Architecture | Status in this repository |
  |---|---|---|
  | Ubuntu LTS | amd64, arm64 | Tested in CI on Ubuntu 26.04. On arm64, CI checks the install and the start of the stack, and the end-to-end jobs run on amd64 |
  | RHEL 8 and later, and compatible distributions | amd64, arm64 | Steps documented, not tested in CI |

- Docker Engine 24 or later, running, with Swarm mode available. Podman cannot run Swarm.
- Root access, and the tools `curl`, `tar`, `sha256sum`, and `install` for the manual steps.
- A node clock that is synchronized with NTP. TLS to CircleCI fails silently when the clock drifts.
- Outbound HTTPS access from each node to the hosts in [Egress hosts](security.md#egress-hosts). No inbound access is required.
- Enough CPU and memory for the services. The shipped file reserves 10 CPUs and 20 GB of memory in total, and replicas that do not fit stay pending.

Membership of the `docker` group is equivalent to root on the node. Limit it to administrators.

### Self-hosted runner terms agreement

If you install self-hosted runners through the web app, an organization admin must agree to the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/) at **Org** > **Runners**. If you install and use self-hosted runners through the CLI, you agree to the CircleCI Runner Terms.

## Get the files

Use a release, or clone the repository at a release tag. The paths on this page are relative to the root of the repository or of the extracted release bundle.

```bash
git clone --branch <release-tag> https://github.com/CircleCI-Labs/scalable-machine-runner.git
cd scalable-machine-runner
```

Each [GitHub release](https://github.com/CircleCI-Labs/scalable-machine-runner/releases) carries these files, where `<version>` is the release number without the `v`:

| File | Content |
|---|---|
| `machine-runner-swarm-<version>.tar.gz` | The bundle for Linux: the stack files, the entrypoint, the setup scripts, the documentation, and the examples, without the tests |
| `machine-runner-swarm-<version>.zip` | The same bundle for Windows |
| `SHA256SUMS` | The SHA-256 checksum of both bundles |
| `SHA256SUMS.sigstore.json` | A keyless [cosign](https://docs.sigstore.dev/cosign/overview/) signature of `SHA256SUMS` |

The bundle has a top-level `VERSION` file with the release number and a `CHANGELOG.md` with the notes of every release.

### Verify a release

CircleCI signs `SHA256SUMS` with the OIDC token of the CircleCI job that makes the release. No signing key is stored anywhere. The signature proves that a job of this CircleCI project made the file, and the checksums prove that your download is the file the job made. You need [cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 2.4 or later. On Windows, refer to [Verify a release](install-windows.md#verify-a-release).

1. Download the bundle and the two verification files. Set `version` to the release you want.

   ```bash
   version=0.1.0
   base="https://github.com/CircleCI-Labs/scalable-machine-runner/releases/download/v${version}"
   curl -fsSLO "${base}/machine-runner-swarm-${version}.tar.gz"
   curl -fsSLO "${base}/SHA256SUMS"
   curl -fsSLO "${base}/SHA256SUMS.sigstore.json"
   ```

1. Verify the signature of `SHA256SUMS`. The command prints `Verified OK` when the CircleCI project and pipeline definition below signed the file.

   ```bash
   cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json \
     --certificate-identity "https://circleci.com/api/v2/projects/7bbdbb66-6ba8-4f6c-982e-d4fb401ec257/pipeline-definitions/8b2a66db-3f28-5c80-88e4-03f4694b5b60" \
     --certificate-oidc-issuer "https://oidc.circleci.com"
   ```

1. Check the bundle against `SHA256SUMS`. The command prints `OK` for the file you downloaded and skips the other bundle.

   ```bash
   sha256sum -c SHA256SUMS --ignore-missing
   ```

Do not use a bundle if a command fails. Refer to the notes below to understand the values.

- The identity is the CircleCI project (`7bbdbb66-...`) and the pipeline definition (`8b2a66db-...`) that run this repository's pipeline. The issuer `https://oidc.circleci.com` is the CircleCI OIDC issuer. Sigstore records every signature in a public transparency log.
- The identity does not name a branch. To see which branch the job ran for, read the source repository ref in the certificate. The last line of the output ends with the ref, and a release comes from `refs/heads/main`.

  ```bash
  jq -r '.verificationMaterial.certificate.rawBytes' SHA256SUMS.sigstore.json | base64 -d \
    | openssl x509 -inform DER -noout -text | grep -A1 '1.3.6.1.4.1.57264.1.14:'
  ```

- If the project or its pipeline definition is ever re-created, the definition ID changes, and this page gives the new value.

## 1. Create the resource classes

Create a namespace if your organization has none. Each organization can have one namespace, and orbs use the same one.

```console
$ circleci namespace create <namespace> --org-id <organization-id>
```

Create one resource class for each service in the stack file. The class name must equal the service name. The shipped file `linux/stack/runners.yaml` has the services `linux-default`, `linux-java`, and `linux-hardened`.

```console
$ circleci runner resource-class create <namespace>/linux-default --generate-token
$ circleci runner resource-class create <namespace>/linux-java --generate-token
$ circleci runner resource-class create <namespace>/linux-hardened --generate-token
```

Each command prints a token once. Store each token in your secret manager. If you lose a token, create a new one with `circleci runner token create <namespace>/<class> --nickname <nickname>`.

## 2. Prepare each node

Run these steps on every node that runs services.

### Ubuntu

1. Install Docker Engine from Docker's repository by following [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/).
2. Confirm the engine runs.

   ```console
   $ sudo systemctl enable --now docker
   $ docker version
   ```

3. Confirm the clock is synchronized. The command prints `yes`.

   ```console
   $ timedatectl show -p NTPSynchronized --value
   ```

A single node needs no firewall change. Multi-node clusters open the ports in [Inter-node ports](multi-node.md#inter-node-ports).

### RHEL

1. Install Docker Engine from Docker's repository by following [Install Docker Engine on RHEL](https://docs.docker.com/engine/install/rhel/). The Podman packages that RHEL ships cannot run Swarm.
2. Enable the service, and confirm the engine and the clock.

   ```console
   $ sudo systemctl enable --now docker
   $ docker version
   $ timedatectl show -p NTPSynchronized --value
   ```

3. Keep SELinux enforcing. If SELinux denies the container access to `/opt/machine-runner-swarm`, refer to [Permission denied on /opt/machine-runner-swarm with SELinux](troubleshooting.md#permission-denied-on-optmachine-runner-swarm-with-selinux).

> [!NOTE]
> CI does not run on RHEL, so these steps follow Docker's documentation and have not been exercised in this repository.

## 3. Install the runner and the entrypoint

The stack mounts the host link `/opt/machine-runner-swarm/current` read-only at `/opt/machine-runner-swarm` in every container. The link points to the directory of the installed version, which holds the statically linked runner and the entrypoint, so a stock image needs no rebuild when the runner version changes. A new version goes into its own directory, and the link moves to it: refer to [Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux).

| Path | Content |
|---|---|
| `/opt/machine-runner-swarm/<version>/bin/circleci-runner` | Machine runner 3 binary |
| `/opt/machine-runner-swarm/<version>/bin/circleci-runner-entrypoint` | Entrypoint script from `linux/entrypoint/circleci-runner-entrypoint` |
| `/opt/machine-runner-swarm/<version>/VERSION` | Runner version |
| `/opt/machine-runner-swarm/current` | A link to the version directory that the stack mounts |

Run the following as root from the root of the repository. It downloads the runner, verifies its SHA-256 checksum against the file that CircleCI publishes, and installs both files.

```bash
repo=$PWD
v=3.1.12
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) echo "unsupported architecture" >&2; exit 1 ;;
esac
base=https://circleci-binary-releases.s3.amazonaws.com/circleci-runner
cd "$(mktemp -d)"
curl -fsSLO --proto '=https' --tlsv1.2 "$base/$v/circleci-runner_linux_$arch.tar.gz"
curl -fsSL --proto '=https' --tlsv1.2 "$base/$v/checksums.txt" \
  | grep "circleci-runner_linux_$arch.tar.gz" | sha256sum -c -
tar -xzf "circleci-runner_linux_$arch.tar.gz" --no-same-owner circleci-runner
./circleci-runner --version
d=/opt/machine-runner-swarm
install -d -m 0755 -o root -g root "$d" "$d/$v" "$d/$v/bin"
install -m 0755 -o root -g root circleci-runner "$repo/linux/entrypoint/circleci-runner-entrypoint" "$d/$v/bin/"
echo "$v" > "$d/$v/VERSION"
ln -s "$v" "$d/.current.new"
mv -T "$d/.current.new" "$d/current"
```

The last two commands make the link `current`: a new link under a temporary name, and then one atomic rename over the old one, so a container is never created while the link is missing.

Inside the container the link appears as `/opt/machine-runner-swarm`. The entrypoint refuses to start a container when that directory, its `bin` directory, or the runner binary is not owned by root or is writable by the group or others. Use runner version 3.1.12 or later, which fixes the enforcement of `max_run_time`.

Repeat this step on every node. The directory must exist on each node that can run a service, otherwise the task fails with `bind source path does not exist`. Install the build that matches the architecture of the node.

## 4. Start Swarm

On a single node, start Swarm so that it listens on the loopback address only. Nothing is exposed to the network.

```console
$ docker swarm init --advertise-addr 127.0.0.1 --listen-addr 127.0.0.1:2377
$ docker swarm update --task-history-limit 2
```

The second command keeps fewer stopped containers on the node. Each finished job leaves a stopped container until Swarm prunes its task, and every stopped container keeps its writable layer on disk.

A node that listens on the loopback address cannot accept other nodes. For several nodes, initialize Swarm with a routable address instead. Refer to [Multi-Node Clusters](multi-node.md#create-the-swarm).

## 5. Create the secrets

Create one secret for each service in the stack file. The secret is the config file of the runner and holds only the token:

```yaml
api:
  auth_token: <token>
```

The stack mounts the secret at `/run/secrets/circleci_runner_config.yaml`, owned by the runner user (uid 2000) with mode `0400`. The runner reads it with `--config`. Every other setting is a `CIRCLECI_RUNNER_*` environment variable in the stack file.

Create the secrets with a hidden prompt, so that the token does not reach your shell history or the process list.

```bash
for class in linux-default linux-java linux-hardened; do
  read -rsp "Token for $class: " TOKEN; echo
  printf 'api:\n  auth_token: %s\n' "$TOKEN" | docker secret create "$class-token" -
done
unset TOKEN
```

The secret name is the service name plus `-token`. `docker stack deploy` fails with `secret not found` when a service references a secret that does not exist. Create every secret that the file references, or delete the services you do not need from your copy of the file. Each optional class in step 6 needs its own secret.

`docker stack config` prints the mode `0400` as `256`, its decimal value.

## 6. Review the stack file

Copy `linux/stack/runners.yaml` and keep your copy under version control. Review these settings first. Refer to [Resource Classes](resource-classes.md) for the details.

| Setting | Default | Change it to |
|---|---|---|
| Service names | `linux-default`, `linux-java`, `linux-hardened` | Your resource class names |
| `image` | `cimg/base:2026.10`, `cimg/openjdk:21.0` | Your image, pinned by digest. Refer to [Images](images.md) |
| `deploy.replicas` | 2, 1, 1 | The number of concurrent jobs you need |
| `deploy.resources` | 2 CPUs and 4 GB, or 4 CPUs and 8 GB | The size of one runner. Limits and reservations are equal |
| `placement.constraints` | `node.platform.os == linux` | Add architecture or zone constraints |

Check that the file parses. This needs no running Swarm.

```console
$ docker stack config -c linux/stack/runners.yaml > /dev/null
```

The optional classes are separate overlay files. Add them with another `-c` flag, and always pass the same set of files on every deploy. Each overlay needs its own resource class and its own secret `<service>-token`.

| File | Service | Purpose |
|---|---|---|
| `linux/stack/docker-build.yaml` | `linux-docker-build` | Builds images with the host Docker engine. Needs a labeled worker node. Refer to [Docker Builds](docker-builds.md) |
| `linux/stack/persistent.yaml` | `linux-persistent` | A long-lived runner with a named volume. Needs the node name edited in the file. Refer to [Persistent mode](resource-classes.md#persistent-mode) |

An overlay file repeats the common service settings of `runners.yaml`, because YAML anchors do not cross files. When you change a common setting, such as `stop_grace_period` or the logging options, change it in every file that you use.

## 7. Deploy the stack

```console
$ docker stack deploy -c linux/stack/runners.yaml runners
```

To add the optional classes, pass their files with more `-c` flags:

```console
$ docker stack deploy -c linux/stack/runners.yaml -c linux/stack/persistent.yaml runners
```

## Verify the deployment

1. List the services. Each shows the running and desired replicas.

   ```console
   $ docker stack services runners
   ID             NAME                 MODE         REPLICAS   IMAGE
   ...            runners_linux-default    replicated   2/2        cimg/base:2026.10
   ...            runners_linux-java       replicated   1/1        cimg/openjdk:21.0
   ...            runners_linux-hardened   replicated   1/1        cimg/base:2026.10
   ```

2. Check the tasks of a service. A task in the `Running` state is a runner that polls CircleCI.

   ```console
   $ docker service ps runners_linux-default
   ```

3. In the web app, select **Runners** and open the resource class. Each replica shows up in the inventory with a name of the form `<node hostname>-<service>-<slot>`, for example `node1-linux-default-1`.

4. Add a job to your config and run it.

   ```yaml
   version: 2.1

   jobs:
     build:
       machine: true
       resource_class: <namespace>/linux-default
       steps:
         - checkout
         - run: echo "runner $CIRCLECI_RUNNER_NAME"

   workflows:
     main:
       jobs:
         - build
   ```

   Run the workflow twice. After each job, Swarm shows a new task for the slot. The file [`examples/linux-jobs.yml`](../examples/linux-jobs.yml) has a job named `clean-check` that fails if anything from an earlier job is still present.

## Optional: use the setup helper

`linux/setup.sh` performs the steps above with checks. It never prints the token, and every step is idempotent. It needs bash 4.4 or later and the tools `curl`, `tar`, `sha256sum`, and `install`.

| Step | Effect |
|---|---|
| `--check` | Preflight: Linux, amd64 or arm64, Docker running and 24 or later, Swarm state, NTP |
| `--swarm-init` | Runs `docker swarm init` on the loopback address unless Swarm is active, and sets the task history limit to 2 |
| `--install` | Downloads the runner, verifies the SHA-256 checksum, installs the runner and entrypoint into `--prefix/<version>` (default prefix `/opt/machine-runner-swarm`), and points `--prefix/current` at it. Another `--version` installs next to the others and moves the link, and an installed version is only switched to, which is the rollback. Needs root |
| `--secret <service>` | Creates the secret `<service>-token` from a token read on stdin |
| `--deploy` | Runs `docker stack deploy` with each `--stack-file` (default `linux/stack/runners.yaml`) |

With no step, it runs `--check --install`. Options are `--version`, `--sha256`, `--prefix`, `--stack-file` (repeatable), and `--stack-name`.

```bash
sudo linux/setup.sh --check --swarm-init --install
sudo linux/setup.sh --secret linux-default --secret linux-java --secret linux-hardened   # a hidden prompt asks for each token
sudo linux/setup.sh --deploy
```

Create one secret for every service of the stack files you deploy. `--deploy` fails with `secret not found` when one is missing, and `linux-hardened` is in `runners.yaml` too. Every command needs `sudo` or membership of the `docker` group, because each one talks to the Docker daemon, and `--install` needs root. The helper is a bash script with a `#!/usr/bin/env bash` line, so it runs from any shell, including zsh. To script one secret, pipe the token: `printf %s "$TOKEN" | sudo linux/setup.sh --secret linux-default`. Several `--secret` values need a terminal, because stdin carries one token.

The helper pins the SHA-256 checksums of runner version 3.1.12 for amd64 and arm64. For another version, pass `--version X.Y.Z --sha256 <hash>` with the hash from the `checksums.txt` of that release. The helper does not look up the latest version. It installs a pinned version, so that it knows the checksum before the download. Set `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` to an HTTPS mirror for hosts without internet access. The mirror must use the same layout: `<base>/<version>/circleci-runner_linux_<arch>.tar.gz`.

The helper accepts a token that has only letters, digits, `.`, `_`, and `-`, and it keeps an existing secret unchanged. To replace a token, refer to [Rotate a runner token](operations.md#rotate-a-runner-token). The preflight warns when the clock is not NTP-synchronized. The helper does not label nodes. For a docker-build class, run `docker node update --label-add machine-runner-swarm.docker-build=true <worker node>` yourself.

To install the runner without any other step, source the script:

```bash
. linux/setup.sh && swarm_install_runner 3.1.12 /opt/machine-runner-swarm
```

## Upgrade

Refer to [Upgrade the runner and images](operations.md#upgrade-the-runner-and-images) to move to a new runner version, a new image, or a new release of this repository.

## Stop and uninstall

Refer to [Uninstall](operations.md#uninstall).

## Troubleshooting

Refer to [Troubleshooting](troubleshooting.md). The most common problems on a first install are a missing secret, a missing `/opt/machine-runner-swarm` on a node, and a task that stays pending because no node matches its constraints.

## Additional resources

- [Concepts](concepts.md)
- [Resource Classes](resource-classes.md)
- [Security](security.md)
- [Operations](operations.md)
- [Machine runner 3 configuration reference](https://circleci.com/docs/guides/execution-runner/machine-runner-3-configuration-reference/)
