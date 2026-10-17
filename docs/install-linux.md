---
page-title: Install on Linux with Docker Swarm
page-audience: admin
page-description: Deploy CircleCI machine runner 3 as a Docker Swarm stack on Ubuntu or RHEL, with one clean container for every job.
---

# Install on Linux with Docker Swarm

This page deploys CircleCI machine runner 3 as a Docker Swarm stack on Linux: one service for each resource class, and a clean container for every job. The steps cover one node ([Multi-node clusters](multi-node.md) adds more). For a first run, [Quickstart on Linux](quickstart-linux.md) is shorter.

> [!NOTE]
> If you can run Kubernetes, CircleCI recommends [container runner](https://circleci.com/docs/guides/execution-runner/container-runner-installation/) for containerized jobs, and documents a plain [machine runner 3 on Docker](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-docker/) setup. This page is for teams that run Docker Swarm and want a clean container for every job.

**Status.** This is a CircleCI Labs project, `0.x`, and CircleCI support does not cover it. It is tested against CircleCI cloud only: [What is tested](../README.md#what-is-tested) says how. Replicas are fixed: the stack does not add or remove nodes, and it does not scale to the queue.

Nothing is installed on a node by hand: a service of the stack installs the runner on every node, so `docker stack deploy` is the whole install. The optional [setup helper](#optional-use-the-setup-helper) runs the same steps.

## Prerequisites

- A CircleCI cloud organization and a user who is an organization admin. CircleCI server is not tested: [CircleCI server](security.md#circleci-server) says what is known.
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, signed in. Pass `--org <ORG>` (a slug such as `gh/my-org`, or a UUID): without it the CLI uses the organization of the git remote of the current directory, which in a clone of this repository is not yours.
- Docker Engine 24 or later, running, with Swarm mode (Podman cannot run Swarm). Root access or membership of the `docker` group, which is equivalent to root: limit it to administrators.
- A node clock synchronized with NTP. TLS to CircleCI fails silently when the clock drifts.
- Outbound HTTPS from each node to the hosts in [Egress hosts](security.md#egress-hosts): the release bucket of CircleCI (the runner), and the registries of the `alpine` image (the distributor) and the token proxy image (Docker Hub). No inbound access is needed. [What needs internet](security.md#what-needs-internet) lists everything. Not tested without internet access: [Run the downloads from a mirror](operations.md#run-the-downloads-from-a-mirror).
- CPU and memory: the shipped file reserves 4 CPUs and 8 GB in total, and replicas that do not fit stay pending ([Size the limits](resource-classes.md#size-the-limits)).
- Runner concurrency in your CircleCI plan for your replicas ([Capacity and concurrency](operations.md#capacity-and-concurrency)).

| Operating system | Architecture | Status in this repository |
|---|---|---|
| Ubuntu LTS | amd64, arm64 | Tested in CI on Ubuntu 26.04. On arm64, every pipeline checks that the stack installs the runner and starts, and probe jobs run on a real arm64 runner on `main` and `smr-swarm/*` branches |
| RHEL 8 and later, and compatible distributions | amd64, arm64 | Steps documented, not tested in CI |
| Any of the above | ppc64le, s390x | CI only starts the distributor and the token proxy image under emulation: no job has run on them |

### Self-hosted runner terms agreement

An organization admin must agree to the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/) before you install self-hosted runners through the web app. Through the CLI, you agree by installing and using them ([details](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-linux/#self-hosted-runner-terms-agreement)). Whether the token proxy between your runners and CircleCI is covered is for your own review: this project does not give legal advice.

## Get the files

Use a release (recommended) or clone the repository at a release tag. Paths on this page are relative to the root of the repository or of the extracted bundle.

```bash
git clone --branch <RELEASE_TAG> https://github.com/CircleCI-Labs/machine-runner-swarm.git
cd machine-runner-swarm
```

A release is recommended because its stack files name the token proxy image of that release by tag and digest. A clone names the tag `latest`, which is not a pin ([The token proxy image](#the-token-proxy-image)). Each [GitHub release](https://github.com/CircleCI-Labs/machine-runner-swarm/releases) carries four files, with `<VERSION>` the release number without the `v`:

| File | Content |
|---|---|
| `machine-runner-swarm-<VERSION>.tar.gz` | The Linux bundle: stack files, scripts, documentation and examples, without the tests, plus `VERSION` and `CHANGELOG.md` |
| `machine-runner-swarm-<VERSION>.zip` | The same bundle for Windows |
| `SHA256SUMS` | The SHA-256 checksum of both bundles |
| `SHA256SUMS.sigstore.json` | A keyless [cosign](https://docs.sigstore.dev/cosign/overview/) signature of `SHA256SUMS` |

### Verify a release

CircleCI signs `SHA256SUMS` with the OIDC token of the CircleCI job that makes the release. No signing key is stored anywhere. The signature proves that a job of this CircleCI project made the file, and the checksums prove that your download is the file the job made. You need [cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 3.1.3 or a later 3.x (CI signs and verifies with 3.1.3, and earlier versions are not tested), `curl`, `jq`, and GNU coreutils, in a bash shell. On Windows, refer to [Verify a release](install-windows.md#verify-a-release).

Set `version` once to the number of the [latest release](https://github.com/CircleCI-Labs/machine-runner-swarm/releases/latest) without the `v`, and read its notes. The download fails while the placeholder is unchanged.

```bash
version=X.Y.Z
```

Then paste this block. It runs in a subshell and stops at the first failing check. Only a bundle that passes the signature, the ref and the checksum is unpacked.

```bash
(
  set -euo pipefail
  base="https://github.com/CircleCI-Labs/machine-runner-swarm/releases/download/v${version}"
  curl -fsSLO "${base}/machine-runner-swarm-${version}.tar.gz" \
       -O "${base}/SHA256SUMS" \
       -O "${base}/SHA256SUMS.sigstore.json"

  # 1. the signature: the CircleCI project and pipeline definition of this repository signed SHA256SUMS
  cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json \
    --certificate-identity "https://circleci.com/api/v2/projects/7bbdbb66-6ba8-4f6c-982e-d4fb401ec257/pipeline-definitions/8b2a66db-3f28-5c80-88e4-03f4694b5b60" \
    --certificate-oidc-issuer "https://oidc.circleci.com"

  # 2. the ref: a job of any branch can sign with that identity, so the certificate must also say that the job ran for refs/heads/main
  #    (the long string is the OID 1.3.6.1.4.1.57264.1.14 followed by the value refs/heads/main)
  hex=$(jq -r '.verificationMaterial | (.certificate // .x509CertificateChain.certificates[0]).rawBytes' SHA256SUMS.sigstore.json \
    | base64 -d | od -An -v -tx1 | tr -d ' \n')
  grep -Eq '^([0-9a-f]{2})*2b0601040183bf30010e0411(0c|13)0f726566732f68656164732f6d61696e' <<< "${hex}" \
    && echo "signed for refs/heads/main" || { echo "NOT signed for refs/heads/main: stop"; exit 1; }

  # 3. the file: its checksum is in the signed list
  sha256sum -c SHA256SUMS --ignore-missing

  # only a verified bundle is unpacked
  tar -xzf "machine-runner-swarm-${version}.tar.gz"
  echo "RELEASE VERIFIED"
)
```

Continue only when the last line is `RELEASE VERIFIED`. Anything else, an error message or no output at all, means that the release is not verified: delete the downloaded files, and start again or ask in an issue. The ref check exists because the signing identity is the same for every branch, so the block reads the certificate extension `1.3.6.1.4.1.57264.1.14` (the OID in the long string) and fails unless its value is `refs/heads/main`. The pattern starts on a byte boundary, and ASN.1 tag `0c` or `13` is the string type of the value.

Then change into the bundle:

```bash
cd "machine-runner-swarm-${version}"
```

The token proxy image has its own signature: [Verify the token proxy image](security.md#verify-the-token-proxy-image) has the commands.

The checks establish less than a review does. A valid signature and `refs/heads/main` mean that a job of this CircleCI project ran for the `main` branch and made these files. Whether anyone can change `main` without a review is a setting of the organization that owns the repository, which this page cannot check ([A ruleset for main](https://github.com/CircleCI-Labs/machine-runner-swarm/blob/main/docs/ci.md#a-ruleset-for-main) says what the project asks for).

- The identity is the CircleCI project (`7bbdbb66-...`) and the pipeline definition (`8b2a66db-...`) that run this repository's pipeline. The issuer `https://oidc.circleci.com` is the CircleCI OIDC issuer. Sigstore records every signature in a public transparency log.
- To see the ref of a certificate, print it. The last line ends with the ref, and a release comes from `refs/heads/main`.

  ```bash
  jq -r '.verificationMaterial.certificate.rawBytes' SHA256SUMS.sigstore.json | base64 -d \
    | openssl x509 -inform DER -noout -text | grep -A1 '1.3.6.1.4.1.57264.1.14:'
  ```

- If the project or its pipeline definition is ever re-created, the definition ID changes, and this page gives the new value.

### The token proxy image

The token proxy is the one container that holds your class tokens ([The token proxy](concepts.md#the-token-proxy)). It is the image `ccilabs/machine-runner-swarm-proxy` on Docker Hub (`ccilabs` is the Docker Hub organization of CircleCI Labs), which the stack file pulls on deploy. The name is not the trust root: the signature check of [Verify the token proxy image](security.md#verify-the-token-proxy-image) is. It is a static Go binary that runs as a non-root user with a read-only root file system, and one tag covers `linux/amd64`, `linux/arm64`, `linux/ppc64le` and `linux/s390x`. Windows nodes get the Windows image from the same tag ([Windows](install-windows.md#the-token-proxy-image)).

| Tag | What it is |
|---|---|
| `X.Y.Z` | The image of a release. It never changes: pin this one |
| `X.Y`, `X` | The newest release of that minor or major line |
| `latest` | The newest release. The default of the stack files in a checkout, and only a release moves it |
| `edge` | The newest commit of the main branch that passed the end-to-end tests. For testing `main`, not for jobs that matter |
| `sha-<12 characters>` | One commit of the main branch, published before its tests have run |

The stack file reads the image from `MACHINE_RUNNER_SWARM_PROXY_IMAGE`. A release bundle defaults to `ccilabs/machine-runner-swarm-proxy:<VERSION>@sha256:<DIGEST>`, a checkout to `ccilabs/machine-runner-swarm-proxy:latest` (`linux/setup.sh --deploy` warns when the variable is not pinned by digest). To use another image (a digest for a pin, a registry of your own for an air gap, a local build for development), set the variable in the environment of `docker stack deploy`. The image must be on the node that runs the proxy, so build a local one there, or copy it with `docker save`.

```bash
docker build -t machine-runner-swarm-proxy:dev proxy/
sudo env MACHINE_RUNNER_SWARM_PROXY_IMAGE=machine-runner-swarm-proxy:dev docker stack deploy -c deploy/runners.yaml runners
```

[Upgrade the token proxy](operations.md#upgrade-the-token-proxy) says how to change its tag.

## 1. Create the resource classes

1. Create a namespace if your organization has none. An organization has one namespace, and orbs use the same one.

   ```bash
   circleci namespace create <NAMESPACE> --org <ORG>
   ```

2. Create one resource class for each service in the stack file. The class name must equal the service name. The shipped `linux/stack/runners.yaml` has one service, `linux-default`: keep that name for a first run.

   ```bash
   circleci runner resource-class create <NAMESPACE>/linux-default --org <ORG> --generate-token
   ```

The command prints a token once: store it in your secret manager. If you lose it, run `circleci runner token create <NAMESPACE>/<CLASS> --nickname <NICKNAME>`. To rename the service, edit your copy of the file first ([step 5](#5-review-the-stack-file)), then create the class and the secret under the new name. More classes: [Resource classes](resource-classes.md#define-a-class).

## 2. Prepare each node

Run these steps on every node that runs services. A single node needs no firewall change. Multi-node clusters open the ports in [Inter-node ports](multi-node.md#inter-node-ports).

### Ubuntu

1. Install Docker Engine from Docker's repository: [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/).
2. Start the engine and confirm it runs.

   ```bash
   sudo systemctl enable --now docker
   docker version
   ```

3. Confirm the clock is synchronized. The command prints `yes`.

   ```bash
   timedatectl show -p NTPSynchronized --value
   ```

### RHEL

1. Install Docker Engine from Docker's repository: [Install Docker Engine on RHEL](https://docs.docker.com/engine/install/rhel/). The Podman packages of RHEL cannot run Swarm.
2. Do steps 2 and 3 of Ubuntu.
3. Keep SELinux enforcing. The runner is in a Docker volume, so no host directory needs a label.

> [!NOTE]
> CI does not run on RHEL, so these steps follow Docker's documentation and have not been exercised in this repository.

## 3. Start Swarm

Run every `docker` command in these steps with `sudo`, or as a user in the `docker` group. On a single node, start Swarm on the loopback address only, so nothing is exposed to the network.

```bash
docker swarm init --advertise-addr 127.0.0.1 --listen-addr 127.0.0.1:2377
docker swarm update --task-history-limit 2
```

The second command keeps fewer stopped containers on the node (each finished job leaves one until Swarm prunes its task). `setup.sh --swarm-init` runs both.

The node is a manager, and the token proxy runs on a manager by default. On a single node, set no proxy label. In a cluster, label the node that runs the proxy: runner services never run on a node with this label, so a job never shares a node with the proxy.

```bash
docker node update --label-add machine-runner-swarm.proxy=true <MANAGER_NAME>
```

With several managers, also pin the proxy to one ([Where the proxy runs, and when it moves](operations.md#where-the-proxy-runs-and-when-it-moves)). A loopback node cannot accept other nodes: for a cluster, use a routable address ([Multi-node clusters](multi-node.md#create-the-swarm)).

## 4. Create the secrets

Create one secret for each service in the stack file, named `<SERVICE>-token`. It is a runner config file that holds only the token:

```yaml
api:
  auth_token: <TOKEN>
```

The token proxy mounts these secrets at `/run/secrets/<SERVICE>-token` (uid 65534, mode `0400`), and the runners never see them. The runners read one more secret, `runner-placeholder-token`, with a dummy token in the same format, mounted at `/run/secrets/circleci_runner_config.yaml` (runner user, uid 2000, mode `0400`). Only the persistent class mounts its own token in the runner. Every other runner setting is a `CIRCLECI_RUNNER_*` variable in the stack file.

Set `classes` to every class you deploy. The loop asks for each token with a hidden prompt, so the token does not reach your shell history or the process list. It works in bash, zsh and dash and stops at an empty token. Do not use `read -rsp`: zsh reads `-p` as a coprocess, which leaves `TOKEN` empty and creates a secret without a token.

```sh
classes="linux-default"
for class in $classes; do
  printf 'Token for %s (hidden): ' "$class"
  stty -echo; IFS= read -r TOKEN; stty echo; echo
  [ -n "$TOKEN" ] || { echo "no token entered for $class" >&2; break; }
  printf 'api:\n  auth_token: %s\n' "$TOKEN" | docker secret create "$class-token" -
done
unset TOKEN
printf 'api:\n  auth_token: machine-runner-swarm-placeholder\n' | docker secret create runner-placeholder-token -
```

`docker stack deploy` fails with `secret not found` when a service references a missing secret: create every secret the file references, or delete the services you do not need from your copy. `docker stack config` prints the mode `0400` as `256`.

## 5. Review the stack file

Copy `linux/stack` to a directory of your own, `deploy/`, and keep it under version control. From here on you check and deploy your copy and never the shipped files. For a first run, change nothing.

```bash
cp -r linux/stack deploy
```

Check that the file parses. This needs no running Swarm.

```bash
docker stack config -c deploy/runners.yaml > /dev/null
```

The directory holds the stack files and the two scripts that they ship as Swarm configs, `circleci-runner-entrypoint` and `runner-distributor.sh`. Keep the scripts next to the stack files, and keep the service `runner-distributor` and the top-level `configs:` and `volumes:`. A Swarm config cannot change, so its name carries the first 12 hex digits of the SHA-256 of its file: if you edit a script, rename its config the same way (`sha256sum <FILE> | cut -c1-12`).

Review these settings first ([Resource classes](resource-classes.md) has the details):

| Setting | Default | Change it to |
|---|---|---|
| Service name | `linux-default` | Your resource class name |
| `image` | `cimg/base:2026.10` | Your image, pinned by digest ([Images](images.md)) |
| `deploy.replicas` | 2 | The number of concurrent jobs you need |
| `deploy.resources` | 2 CPUs and 4 GB | The size of one runner. Limits and reservations are equal |
| `placement.constraints` | `node.platform.os == linux` | Add architecture or zone constraints |
| `x-distributor-env` | An exact runner version (`3.1.13` in this release) with the SHA-256 values of its tarballs, major version 3, a check every 24 hours | Nothing for a first run. A newer pin, a floating version or a mirror are variables of `docker stack deploy` ([Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux)) |

The optional classes are add-on files in `deploy/`. Add each with another `-c` flag, and pass the same list on every deploy ([how the files merge](concepts.md#add-on-stack-files-and-how-they-merge)). Each needs its own resource class and secret `<SERVICE>-token`.

| File | Services | Purpose |
|---|---|---|
| `classes-extra.yaml` | `linux-java`, `linux-hardened` | Examples: an image swap, and a class without sudo. Reserves 6 more CPUs and 12 GB ([Define a class](resource-classes.md#define-a-class)) |
| `docker-build.yaml` | `linux-docker-build` | Builds images with the host engine. Needs a labeled worker ([Docker builds](docker-builds.md)) |
| `microvm.yaml` | `linux-microvm`, `linux-microvm-docker`, `microvm-dns` | Each job in a Kata Containers microVM. Needs KVM ([MicroVM jobs](microvm.md)) |
| `persistent.yaml` | `linux-persistent` | A long-lived runner. Needs the node name edited in the file ([Persistent mode](resource-classes.md#persistent-mode)) |
| `ssh-rerun.yaml` | `linux-default-ssh` | Rerun job with SSH. Publishes port 54782 ([Rerun job with SSH](resource-classes.md#rerun-job-with-ssh)) |

An add-on file repeats the common settings of `runners.yaml` (YAML anchors do not cross files), so it also loads alone. Change a common setting, such as `stop_grace_period` or the logging options, in every file that you use.

## 6. Deploy the stack

Deploy your copy from step 5. The command returns before the replicas run, because `docker stack deploy` does not wait.

```bash
docker stack deploy -c deploy/runners.yaml runners
```

To add optional classes, pass your copies with more `-c` flags, and pass the same list on every later deploy:

```bash
docker stack deploy -c deploy/runners.yaml -c deploy/persistent.yaml runners
```

This is the whole install. The service `runner-distributor` starts on every Linux node, also on a node that joins later (not on a microVM node: its classes download their own runner). It downloads the runner version the stack file pins (the newest that CI tests), checks its SHA-256 against the values the stack file carries, and puts it in the volume `runner-bin` of the node. The service `token-proxy` pulls its image from Docker Hub. A runner container that starts first waits up to 120 seconds for the runner.

Other distributor settings, such as a floating version like `3.1` (weaker: the distributor trusts the manifest and ignores the default SHA-256 list), are variables of this command. `sudo` drops the environment: write `sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1 docker stack deploy ...` ([Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux)).

## Verify the deployment

1. List the services. Each shows the running and desired replicas.

   ```bash
   docker stack services runners
   ```

   ```text
   ID             NAME                        MODE         REPLICAS   IMAGE
   ...            runners_linux-default       replicated   2/2        cimg/base:2026.10
   ...            runners_runner-distributor  global       1/1        alpine:3
   ...            runners_token-proxy         replicated   1/1        ccilabs/machine-runner-swarm-proxy:...
   ```

   The distributor has one task for each Linux node (a microVM node has none): `1/1` on one node, `3/3` on three.

2. Check the tasks. A task in the `Running` state is a runner that polls CircleCI.

   ```bash
   docker service ps runners_linux-default
   ```

3. Check that the distributor installed the runner. Its log has a line such as `runner-distributor: [ ok ] current -> versions/3.1.13: circleci-runner 3.1.13 linux/amd64` for each node ([See what runs](operations.md#see-what-runs)).

   ```bash
   docker service logs --tail 20 runners_runner-distributor
   ```

4. Check that the runners connected. Each replica is listed as `online`, named `<NODE_HOSTNAME>-<SERVICE>-<SLOT>` (for example `node1-linux-default-1`). The web app shows the same under **Runners**.

   ```bash
   circleci runner instance list --org <ORG> --resource-class <NAMESPACE>/linux-default
   ```

5. Run a job with [`examples/linux-hello.yml`](../examples/linux-hello.yml) (the [quickstart](quickstart-linux.md#steps) shows it), twice. After each job, Swarm shows a new task for the slot. The job `clean-check` in [`examples/linux-jobs.yml`](../examples/linux-jobs.yml) fails if anything from an earlier job is still present.

## Optional: use the setup helper

`linux/setup.sh` runs the steps above with checks. It never prints the token, every step is idempotent, and it needs bash 4.4 or later. It installs nothing on a node: the service `runner-distributor` installs the runner.

| Step | Effect |
|---|---|
| `--check` | Preflight: Linux on amd64, arm64, ppc64le or s390x, Docker running and 24 or later, Swarm state, NTP |
| `--swarm-init` | Runs `docker swarm init` on the loopback address unless Swarm is active, and sets the task history limit to 2 |
| `--secret <SERVICE>` | Creates the secret `<SERVICE>-token` from a token read on stdin |
| `--deploy` | Runs `docker stack deploy` with each `--stack-file`. Without one it deploys the shipped `linux/stack/runners.yaml`, so pass your copy from step 5. It warns when `MACHINE_RUNNER_SWARM_PROXY_IMAGE` is not pinned by digest |

With no step it runs `--check`. Steps run in the order of the table. Options are `--stack-file` (repeatable) and `--stack-name`. Each run ends with `Next:` and the steps still to do, or `Check:` and the commands that show the runners start.

```bash
sudo linux/setup.sh --check --swarm-init
sudo linux/setup.sh --secret linux-default
printf %s machine-runner-swarm-placeholder | sudo linux/setup.sh --secret runner-placeholder
sudo linux/setup.sh --deploy --stack-file deploy/runners.yaml
```

- `--secret` asks for the token with a hidden prompt. To script it, pipe the token (`printf %s "$TOKEN" | sudo linux/setup.sh --secret linux-default`). Several `--secret` values need a terminal. A token has only letters, digits, `.`, `_` and `-`, and an existing secret stays unchanged ([Rotate a runner token](operations.md#rotate-a-runner-token)). Create a secret for every service you deploy.
- The helper does not label nodes. For a docker-build class, run `docker node update --label-add machine-runner-swarm.docker-build=true <WORKER_NODE>`.
- The distributor reads `MACHINE_RUNNER_SWARM_RUNNER_VERSION`, `MACHINE_RUNNER_SWARM_RUNNER_MAJOR`, `MACHINE_RUNNER_SWARM_CHECK_INTERVAL`, `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` and `MACHINE_RUNNER_SWARM_RUNNER_SHA256` from the environment of `--deploy`, and the token proxy reads `MACHINE_RUNNER_SWARM_PROXY_*`. `sudo` drops the environment: use `sudo env VAR=value linux/setup.sh --deploy` ([Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux)).

## Upgrade

The nodes keep the runner version that the stack file pins until you change it: [Upgrade the runner and images](operations.md#upgrade-the-runner-and-images) covers versions, images and rollback.

A new release of this repository changes the shipped stack files, and your copy `deploy/` is not updated by itself. To merge:

1. Read the notes of the release and the [changelog](../CHANGELOG.md): entries marked `[BREAKING]` say what to change. This is a `0.x` project, so a minor release can change the files.
2. Verify and unpack the new release beside the old one ([Verify a release](#verify-a-release)). The old directory is the base of the merge (for a cloned tag, use `git worktree` or a second clone).
3. See what changed between the two releases.

   ```bash
   diff -ru "machine-runner-swarm-${old}/linux/stack" "machine-runner-swarm-${new}/linux/stack"
   ```

4. Merge each file that differs into your copy. The command edits the file in place, marks conflicts with `<<<<<<<` lines, and exits with the number of conflicts.

   ```bash
   git merge-file deploy/runners.yaml \
     "machine-runner-swarm-${old}/linux/stack/runners.yaml" \
     "machine-runner-swarm-${new}/linux/stack/runners.yaml"
   ```

   Repeat for the other files you copied. Take the entrypoint and the distributor script of the new release unless you edited them, and rename their Swarm configs as [Upgrade to a new release of this repository](operations.md#upgrade-to-a-new-release-of-this-repository) says.
5. Check `deploy.replicas`, `image`, `deploy.placement.constraints` and `deploy.resources`, the runner version pin with its SHA-256 values (a release changes them together), and the token proxy image (a release names it by digest).
6. Check the result.

   ```bash
   docker stack config -c deploy/runners.yaml > /dev/null
   ```

7. Deploy with the same list of `-c` files as before.

   ```bash
   docker stack deploy -c deploy/runners.yaml runners
   ```

Swarm replaces the token proxy and updates the runner services one replica at a time. While the proxy is replaced, no new job is claimed, and every runner that had already claimed stays refused ([Restart the proxy](operations.md#restart-the-proxy)). To roll back, deploy the previous copy.

## Stop and uninstall

Refer to [Uninstall](operations.md#uninstall).

## Troubleshooting

Refer to [Troubleshooting](troubleshooting.md). The most common problems on a first install are a missing secret, a node whose distributor cannot download the runner, and a task that stays pending because no node matches its constraints.

## Additional resources

- [Concepts](concepts.md)
- [Resource classes](resource-classes.md)
- [Security](security.md)
- [Operations](operations.md)
- [Machine runner 3 configuration reference](https://circleci.com/docs/guides/execution-runner/machine-runner-3-configuration-reference/)
