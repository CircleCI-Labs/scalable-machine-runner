---
page-title: Install on Linux with Docker Swarm
page-audience: admin
page-description: Deploy CircleCI machine runner 3 as a Docker Swarm stack on Ubuntu or RHEL, with one clean container for every job.
---

# Install on Linux with Docker Swarm

This page describes how to deploy CircleCI machine runner 3 as a Docker Swarm stack on Linux. The steps cover a single node, and [Multi-Node Clusters](multi-node.md) extends them to several nodes.

> [!NOTE]
> If you can run Kubernetes, CircleCI recommends [container runner](https://circleci.com/docs/guides/execution-runner/container-runner-installation/) for containerized jobs. CircleCI documents a plain [machine runner 3 on Docker](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-docker/) setup too. This page is a sibling of those pages for teams that run Docker Swarm and want a clean container for every job.

The manual steps come first and use ordinary `docker` commands. Nothing is installed on a node by hand: the stack has a service that installs the runner on every node, and `docker stack deploy` is the whole install. The optional [setup helper](#optional-use-the-setup-helper) runs the same steps. For a first run, [Quickstart on Linux](quickstart-linux.md) is shorter.

## Prerequisites

- A CircleCI cloud organization and a user who is an organization admin.
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, signed in. The commands on this page use its syntax (`circleci --version` prints the version). Pass `--org <org>`, the organization slug such as `gh/my-org` or its UUID: without it the CLI takes the organization of the git remote of the current directory, which in a clone of this repository is not yours.
- One or more Linux nodes with a supported operating system:

  | Operating system | Architecture | Status in this repository |
  |---|---|---|
  | Ubuntu LTS | amd64, arm64 | Tested in CI on Ubuntu 26.04. On arm64, CI checks that the stack installs the runner and starts, and the end-to-end jobs run on amd64 |
  | RHEL 8 and later, and compatible distributions | amd64, arm64 | Steps documented, not tested in CI |

- Docker Engine 24 or later, running, with Swarm mode available. Podman cannot run Swarm.
- Root access, or membership of the `docker` group. Docker and a Swarm join are all that a node needs: no runner, entrypoint, or tool is installed on a node.
- A node clock that is synchronized with NTP. TLS to CircleCI fails silently when the clock drifts.
- Outbound HTTPS access from each node to the hosts in [Egress hosts](security.md#egress-hosts), which include the release bucket of CircleCI (the runner download) and the registries that serve the stock image `alpine` (the distributor) and the token proxy image (Docker Hub). No inbound access is required. For nodes without internet access, refer to [Run the downloads from a mirror](operations.md#run-the-downloads-from-a-mirror).
- Enough CPU and memory for the services. The shipped file reserves 4 CPUs and 8 GB of memory in total, and replicas that do not fit stay pending.

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
| `machine-runner-swarm-<version>.tar.gz` | The bundle for Linux: the stack files, the entrypoint, the runner-distributor script, the setup scripts, the documentation, and the examples, without the tests |
| `machine-runner-swarm-<version>.zip` | The same bundle for Windows |
| `SHA256SUMS` | The SHA-256 checksum of both bundles |
| `SHA256SUMS.sigstore.json` | A keyless [cosign](https://docs.sigstore.dev/cosign/overview/) signature of `SHA256SUMS` |

The bundle has a top-level `VERSION` file with the release number and a `CHANGELOG.md` with the notes of every release.

A release is the recommended source, because its stack files name the token proxy image of that release by tag and digest. A `git clone` of a tag or of the default branch, or a "Download ZIP", works too: the stack files there name the image tag `latest`, which only a release moves and which is not a pin. Refer to [The token proxy image](#the-token-proxy-image).

### The token proxy image

The token proxy is the one container that holds your class tokens ([The token proxy](concepts.md#the-token-proxy)). It is a published image, `ccilabs/machine-runner-swarm-proxy` on Docker Hub, and the stack file pulls it when you deploy. You install nothing for it. It is a static Go binary in a minimal base, runs as a non-root user with a read-only root file system, and one tag covers `linux/amd64`, `linux/arm64`, `linux/ppc64le` and `linux/s390x`, so the node that runs it can have any of them. Windows nodes get the Windows image from the same tag ([Windows](install-windows.md#the-token-proxy-image)).

| Tag | What it is |
|---|---|
| `X.Y.Z` | The image of a release. It never changes: pin this one |
| `X.Y`, `X` | The newest release of that minor or major line |
| `latest` | The newest release. It is the default of the stack files in a checkout, and only a release moves it |
| `edge` | The newest commit of the main branch that passed the end-to-end tests. Use it to test `main`, not to run jobs that matter |
| `sha-<12 characters>` | The image of one commit of the main branch, published before its tests have run |

The stack file reads the image from `MACHINE_RUNNER_SWARM_PROXY_IMAGE`. A release bundle has the default `ccilabs/machine-runner-swarm-proxy:<version>@sha256:<digest>` (the tag, and the digest that Docker pulls), a checkout has `ccilabs/machine-runner-swarm-proxy:latest`. To use another image, set the variable in the environment of `docker stack deploy`: a digest for a pin, a registry of your own for an air gap, or a local build for development.

```bash
# development: build the image from the checkout, and name it
docker build -t machine-runner-swarm-proxy:dev proxy/
sudo env MACHINE_RUNNER_SWARM_PROXY_IMAGE=machine-runner-swarm-proxy:dev docker stack deploy -c deploy/runners.yaml runners
```

The image must be on the node that runs the proxy (a manager by default, or the node that you pin it to). A local build exists only on the node where you built it: build it there, or copy it with `docker save machine-runner-swarm-proxy:dev | ssh <node> docker load`. Docker pulls a published image by itself. [Verify the token proxy image](security.md#verify-the-token-proxy-image) shows how to check its signature, and [Upgrade the token proxy](operations.md#upgrade-the-token-proxy) how to change its tag.

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

1. Check the ref in the certificate. The identity is the same for every branch, and a job of any branch can sign with it, so the certificate must also say that the job ran for `refs/heads/main`. `cosign` has no flag for that extension, so the command reads it: the long hex string is the OID `1.3.6.1.4.1.57264.1.14` followed by the value `refs/heads/main`, and the pattern starts on a byte boundary. It prints `signed for refs/heads/main`.

   ```bash
   jq -r '.verificationMaterial | (.certificate // .x509CertificateChain.certificates[0]).rawBytes' SHA256SUMS.sigstore.json | base64 -d \
     | od -An -v -tx1 | tr -d ' \n' | grep -Eq '^([0-9a-f]{2})*2b0601040183bf30010e0411(0c|13)0f726566732f68656164732f6d61696e' \
     && echo "signed for refs/heads/main" || echo "NOT signed for refs/heads/main: do not use this release"
   ```

1. Check the bundle against `SHA256SUMS`. The command prints `OK` for the file you downloaded and skips the other bundle.

   ```bash
   sha256sum -c SHA256SUMS --ignore-missing
   ```

Do not use a bundle if a command fails. Refer to the notes below to understand the values.

- The identity is the CircleCI project (`7bbdbb66-...`) and the pipeline definition (`8b2a66db-...`) that run this repository's pipeline. The issuer `https://oidc.circleci.com` is the CircleCI OIDC issuer. Sigstore records every signature in a public transparency log.
- The identity does not name a branch, which is why the ref check above exists. To see the ref of a certificate, print it. The last line of the output ends with the ref, and a release comes from `refs/heads/main`.

  ```bash
  jq -r '.verificationMaterial.certificate.rawBytes' SHA256SUMS.sigstore.json | base64 -d \
    | openssl x509 -inform DER -noout -text | grep -A1 '1.3.6.1.4.1.57264.1.14:'
  ```

- If the project or its pipeline definition is ever re-created, the definition ID changes, and this page gives the new value.

## 1. Create the resource classes

Create a namespace if your organization has none. Each organization can have one namespace, and orbs use the same one.

```console
$ circleci namespace create <namespace> --org <org>
```

Create one resource class for each service in the stack file. The class name must equal the service name. The shipped file `linux/stack/runners.yaml` has one service, `linux-default`. For a first run, keep this name. To rename it, edit your copy of the file first ([step 5](#5-review-the-stack-file)), and then create the class and the secret under the new name. More classes come later, one resource class each, from the add-on stack files of step 5 or from [Resource Classes](resource-classes.md#define-a-class).

```console
$ circleci runner resource-class create <namespace>/linux-default --org <org> --generate-token
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

3. Keep SELinux enforcing. The runner is in a Docker volume and not in a host directory, so no directory needs a label for it.

> [!NOTE]
> CI does not run on RHEL, so these steps follow Docker's documentation and have not been exercised in this repository.

## 3. Start Swarm

On a single node, start Swarm so that it listens on the loopback address only. Nothing is exposed to the network.

```console
$ docker swarm init --advertise-addr 127.0.0.1 --listen-addr 127.0.0.1:2377
$ docker swarm update --task-history-limit 2
```

The second command keeps fewer stopped containers on the node (`setup.sh --swarm-init` does both). The node is a manager, and the token proxy runs on a manager by default, with no label. In a cluster with several managers, you can pin it to one: refer to [Where the proxy runs, and when it moves](operations.md#where-the-proxy-runs-and-when-it-moves). Each finished job leaves a stopped container until Swarm prunes its task, and every stopped container keeps its writable layer on disk.

A node that listens on the loopback address cannot accept other nodes. For several nodes, initialize Swarm with a routable address instead. Refer to [Multi-Node Clusters](multi-node.md#create-the-swarm). A node that joins needs nothing else, because the distributor service starts on it by itself.

## 4. Create the secrets

Create one secret for each service in the stack file. The secret is a runner config file and holds only the token:

```yaml
api:
  auth_token: <token>
```

The token proxy mounts these secrets at `/run/secrets/<service>-token`, owned by uid 65534 with mode `0400`, and the runners never see them. The runners read one more secret, `runner-placeholder-token`, with a made-up token: create it once, with any value, in the same format. The stack mounts it at `/run/secrets/circleci_runner_config.yaml`, owned by the runner user (uid 2000) with mode `0400`, and the runner reads it with `--config`. Only the persistent class mounts its own token in the runner. Every other setting is a `CIRCLECI_RUNNER_*` environment variable in the stack file.

Create the secrets with a hidden prompt, so that the token does not reach your shell history or the process list. This loop uses only POSIX features, so it works in bash, zsh, and dash. Do not replace it with `read -rsp`: that form is bash only, and zsh reads `-p` as a coprocess and fails, which leaves `TOKEN` empty and creates a secret without a token. The loop stops at an empty token.

```sh
for class in linux-default; do   # one class; add the names of the other classes you deploy
  printf 'Token for %s (hidden): ' "$class"
  stty -echo; IFS= read -r TOKEN; stty echo; echo
  [ -n "$TOKEN" ] || { echo "no token entered for $class" >&2; break; }
  printf 'api:\n  auth_token: %s\n' "$TOKEN" | docker secret create "$class-token" -
done
unset TOKEN
printf 'api:\n  auth_token: machine-runner-swarm-placeholder\n' | docker secret create runner-placeholder-token -
```

Run every `docker` command in these steps with `sudo`, or as a user in the `docker` group. Without either, `docker` cannot reach the daemon. The setup helper below does the same in one command: `sudo linux/setup.sh --secret linux-default`, and then `printf %s machine-runner-swarm-placeholder | sudo linux/setup.sh --secret runner-placeholder` for the placeholder.

The secret name is the service name plus `-token`. `docker stack deploy` fails with `secret not found` when a service references a secret that does not exist. Create every secret that the file references, or delete the services you do not need from your copy of the file. Each optional class in step 5 needs its own secret.

`docker stack config` prints the mode `0400` as `256`, its decimal value.

## 5. Review the stack file

Copy the directory `linux/stack` to a directory of your own, `deploy/`, and keep it under version control. From here on you check and deploy your copy and never the shipped files, so an edit never touches the shipped files. For a first run, change nothing: the copy works as it is, and you review it later.

```console
$ cp -r linux/stack deploy
```

The directory holds the stack files and the two scripts that they ship as Swarm configs, `circleci-runner-entrypoint` and `runner-distributor.sh`. The stack files name the scripts relative to themselves (`file: circleci-runner-entrypoint`), so keep the scripts in the same directory as the stack files. If you delete the add-on stack files that you do not use, keep `runners.yaml` and the two scripts.

Keep the service `runner-distributor` and the top-level `configs:` and `volumes:` in your copy: every class needs them. A Swarm config cannot change, so its name carries the first 12 hex digits of the SHA-256 of its file. If you edit the entrypoint or the distributor script, rename its config the same way: `sha256sum <file> | cut -c1-12`. Review these settings first. Refer to [Resource Classes](resource-classes.md) for the details.

| Setting | Default | Change it to |
|---|---|---|
| Service name | `linux-default` | Your resource class name |
| `image` | `cimg/base:2026.10` | Your image, pinned by digest. Refer to [Images](images.md) |
| `deploy.replicas` | 2 | The number of concurrent jobs you need |
| `deploy.resources` | 2 CPUs and 4 GB | The size of one runner. Limits and reservations are equal |
| `placement.constraints` | `node.platform.os == linux` | Add architecture or zone constraints |
| `x-distributor-env` | An exact runner version (an exact pin: `3.1.13` in this release) with the SHA-256 values of its tarballs, major version 3, a check every 24 hours | Nothing for a first run. A newer pin or a floating version, or a mirror, are variables of `docker stack deploy` and need no edit. Refer to [Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux) |

Check that the file parses. This needs no running Swarm.

```console
$ docker stack config -c deploy/runners.yaml > /dev/null
```

The optional classes are separate add-on stack files. Add each with another `-c` flag, and pass the same list of files on every deploy ([how the files merge](concepts.md#add-on-stack-files-and-how-they-merge)). Each add-on stack file needs its own resource class and its own secret `<service>-token`.

| File | Service | Purpose |
|---|---|---|
| `linux/stack/classes-extra.yaml` (in `deploy/` after the copy) | `linux-java`, `linux-hardened` | An image swap (`cimg/openjdk`) and a hardened class without sudo. They show how to add a class. Reserves 6 more CPUs and 12 GB. Refer to [Resource Classes](resource-classes.md#define-a-class) |
| `linux/stack/docker-build.yaml` (in `deploy/` after the copy) | `linux-docker-build` | Builds images with the host Docker engine. Needs a labeled worker node. Refer to [Docker Builds](docker-builds.md) |
| `linux/stack/microvm.yaml` (in `deploy/` after the copy) | `linux-microvm`, `linux-microvm-docker`, and the DNS forwarder `microvm-dns` | Runs each job in a Kata Containers microVM. Needs KVM and a node setup. Refer to [MicroVM jobs](microvm.md) |
| `linux/stack/persistent.yaml` (in `deploy/` after the copy) | `linux-persistent` | A long-lived runner with a named volume. Needs the node name edited in the file. Refer to [Persistent mode](resource-classes.md#persistent-mode) |
| `linux/stack/ssh-rerun.yaml` (in `deploy/` after the copy) | `linux-default-ssh` | A class that supports Rerun job with SSH. Publishes port 54782 on the node. Refer to [Rerun job with SSH](resource-classes.md#rerun-job-with-ssh) |

An add-on stack file repeats the common service settings of `runners.yaml`, because YAML anchors do not cross files. That includes the four keys that a class needs for the runner: `user: "0"`, the `entrypoint`, the config `entrypoint`, and the volume `runner-bin` mounted read-only. It repeats the top-level `configs:` and `volumes:` too, so it also loads alone. When you change a common setting, such as `stop_grace_period` or the logging options, change it in every file that you use.

## 6. Deploy the stack

Deploy your copy of the file from step 5. The command returns before the replicas run, because `docker stack deploy` does not wait.

```console
$ docker stack deploy -c deploy/runners.yaml runners
```

To add the optional classes, pass your copies of their files with more `-c` flags, and pass the same list on every later deploy:

```console
$ docker stack deploy -c deploy/runners.yaml -c deploy/persistent.yaml runners
```

This command is the whole install. The service `runner-distributor` starts on every Linux node, also on a node that joins later (not on a microVM node: its classes download their own runner). It downloads the runner of CircleCI (the exact version that the stack file pins, the newest that CI tests), checks its SHA-256 against the values that the stack file carries for that version, and puts it in the volume `runner-bin` of the node. The service `token-proxy` pulls its image from Docker Hub. A runner container that starts first waits up to 120 seconds for it. To deploy with other distributor settings, for example a floating version such as `3.1` (which also needs `MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest`, because the SHA-256 list of the stack file names the pinned version only), set them as variables of this command. A host with `sudo` drops the environment, so write `sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1 MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest docker stack deploy ...`, or run the command as a user in the `docker` group. Refer to [Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux).

## Verify the deployment

1. List the services. Each shows the running and desired replicas.

   ```console
   $ docker stack services runners
   ID             NAME                        MODE         REPLICAS   IMAGE
   ...            runners_linux-default       replicated   2/2        cimg/base:2026.10
   ...            runners_runner-distributor  global       1/1        alpine:3
   ...            runners_token-proxy         replicated   1/1        ccilabs/machine-runner-swarm-proxy:...
   ```

   The distributor shows one task for each Linux node (a microVM node has none), so `1/1` on a single node and `3/3` on three.

2. Check the tasks of a service. A task in the `Running` state is a runner that polls CircleCI.

   ```console
   $ docker service ps runners_linux-default
   ```

3. Check that the distributor installed the runner. Its log has a line such as `runner-distributor: [ ok ] current -> versions/3.1.13: circleci-runner 3.1.13 linux/amd64` for each node. Refer to [See what runs](operations.md#see-what-runs).

   ```console
   $ docker service logs --tail 20 runners_runner-distributor
   ```

4. Check that the runners connected. `circleci runner instance list --org <org> --resource-class <namespace>/linux-default` lists each replica with the status `online`, and the web app shows the same under **Runners**. A replica has a name of the form `<node hostname>-<service>-<slot>`, for example `node1-linux-default-1`.

5. Run a job. Use [`examples/linux-hello.yml`](../examples/linux-hello.yml): it is a complete config, and the [quickstart](quickstart-linux.md#steps) shows it. Run the workflow twice. After each job, Swarm shows a new task for the slot. The file [`examples/linux-jobs.yml`](../examples/linux-jobs.yml) has a job named `clean-check` that fails if anything from an earlier job is still present.

## Optional: use the setup helper

`linux/setup.sh` performs the steps above with checks. It never prints the token, and every step is idempotent. It needs bash 4.4 or later. It installs nothing on a node: the service `runner-distributor` of the stack installs the runner.

| Step | Effect |
|---|---|
| `--check` | Preflight: Linux, amd64, arm64, ppc64le or s390x, Docker running and 24 or later, Swarm state, NTP |
| `--swarm-init` | Runs `docker swarm init` on the loopback address unless Swarm is active, and sets the task history limit to 2. The node is a manager, which is where the token proxy runs |
| `--secret <service>` | Creates the secret `<service>-token` from a token read on stdin |
| `--deploy` | Runs `docker stack deploy` with each `--stack-file`. Without one it deploys the shipped `linux/stack/runners.yaml`, so pass your copy from step 5 |

With no step, it runs `--check`. The steps always run in the order of the table, whatever order you type them, and the hint after every run starts with `Next:` and names only the steps that are still to do (the Swarm, the secrets `linux-default-token` and `runner-placeholder-token`, the stack), read from Docker. When nothing is left it starts with `Check:` and names the commands that show the runners start. Options are `--stack-file` (repeatable) and `--stack-name`.

```bash
sudo linux/setup.sh --check --swarm-init
sudo linux/setup.sh --secret linux-default   # a hidden prompt asks for the token
sudo linux/setup.sh --deploy --stack-file deploy/runners.yaml
```

Create one secret for every service of the stack files you deploy. `--deploy` fails with `secret not found` when one is missing. Every command needs `sudo` or membership of the `docker` group, because each one talks to the Docker daemon. The helper is a bash script with a `#!/usr/bin/env bash` line, so it runs from any shell, including zsh. To script one secret, pipe the token: `printf %s "$TOKEN" | sudo linux/setup.sh --secret linux-default`. Several `--secret` values need a terminal, because stdin carries one token.

The distributor reads its settings from the environment of `--deploy`: `MACHINE_RUNNER_SWARM_RUNNER_VERSION`, `MACHINE_RUNNER_SWARM_RUNNER_MAJOR`, `MACHINE_RUNNER_SWARM_CHECK_INTERVAL`, `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL`, and `MACHINE_RUNNER_SWARM_RUNNER_SHA256`, and for the token proxy the variables `MACHINE_RUNNER_SWARM_PROXY_*`. A host with `sudo` drops the environment, so to deploy with these variables, run `sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1 MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest linux/setup.sh --deploy`, or run `docker stack deploy` as a user in the `docker` group. Refer to [Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux).

The helper accepts a token that has only letters, digits, `.`, `_`, and `-`, and it keeps an existing secret unchanged. To replace a token, refer to [Rotate a runner token](operations.md#rotate-a-runner-token). The preflight warns when the clock is not NTP-synchronized. The helper does not label nodes. For a docker-build class, run `docker node update --label-add machine-runner-swarm.docker-build=true <worker node>` yourself.

## Upgrade

With the default settings, the nodes run the exact runner version that the stack file pins, and a new release of the runner changes nothing until you change the pin or deploy a release of this repository that carries a newer one. Refer to [Upgrade the runner and images](operations.md#upgrade-the-runner-and-images) to pin or roll back the runner version, or to move to a new image or a new release of this repository.

## Stop and uninstall

Refer to [Uninstall](operations.md#uninstall).

## Troubleshooting

Refer to [Troubleshooting](troubleshooting.md). The most common problems on a first install are a missing secret, a node whose distributor cannot download the runner, and a task that stays pending because no node matches its constraints.

## Additional resources

- [Concepts](concepts.md)
- [Resource Classes](resource-classes.md)
- [Security](security.md)
- [Operations](operations.md)
- [Machine runner 3 configuration reference](https://circleci.com/docs/guides/execution-runner/machine-runner-3-configuration-reference/)
