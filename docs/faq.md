---
page-title: FAQ
page-audience: admin
page-description: Common questions about the Swarm runner stack: what to build, comparisons with official runners, scaling, unsupported jobs, and node loss.
---

# FAQ

## What is this repository?

It is a set of Docker Swarm stack files, a small Linux entrypoint, a Linux service that keeps the runner on every node (except the nodes of the microVM add-on, which have their own copy), optional setup helpers, and documentation. Together they run CircleCI machine runner 3 in containers, with one resource class for each Swarm service and a new container for every job. Refer to [Concepts](concepts.md).

## Does CircleCI support it?

No. This repository is part of CircleCI Labs. Engineers at CircleCI created it, but CircleCI support does not cover it, and it is a pre-release `0.x` project. Field engineering handles issues on a best-effort basis. The runner itself, the CircleCI platform, and your resource classes are covered by your normal CircleCI support. [What is tested](../README.md#what-is-tested) says how each claim of this documentation is checked, and which are not.

## What must I build?

Nothing, with one optional exception on Windows.

| | You build | Optional |
|---|---|---|
| Linux | Nothing. The stack mounts the runner from a per-node volume, which its `runner-distributor` service fills, and the entrypoint from a Swarm config, into a stock image such as `cimg/base`. `docker stack deploy` is the whole install | A custom image when jobs need tools, because the hardened class cannot install packages at run time. It needs util-linux `setpriv`. Refer to [Images](images.md) |
| Windows | Nothing. The service `runner-distributor-windows` of the stack installs the runner and portable Git into a volume that the stack mounts into the stock Server Core image | A custom image for your tools, and a DIY image that lets a job finish after a stop. Refer to [Windows images](images.md#windows-bring-your-own-image) and [the stop-timeout image](operations.md#optional-an-image-that-lets-a-job-finish-after-a-stop-diy) |

You build no image. This repository publishes one, the token proxy (`ccilabs/machine-runner-swarm-proxy` on Docker Hub), which Swarm pulls when you deploy the stack, and the release bundle names the image of its release by digest. A Linux node needs a Docker engine and a Swarm join, and nothing else. A Windows node needs a Docker engine, the `ltsc2022` base image, and a Swarm join, and nothing else.

## What do `sudo -niHu` and `setpriv` mean?

They are the two forms of the runner's `command_prefix`, the setting that wraps the task agent so that a job runs as another user. CircleCI documents the setting in the [machine runner 3 configuration reference](https://circleci.com/docs/guides/execution-runner/machine-runner-3-configuration-reference/#runner-command-prefix). The entrypoint sets it in every Linux container, and a value in the service environment does not override it.

- `sudo -niHu circleci --` is the default class. The flags are `-n` (never prompt: fail instead), `-i` (run a login shell), `-H` (set `HOME` to the home directory of the target user), and `-u circleci` (the target user). `--` ends the options, and the task agent follows. The file `/etc/sudoers.d/90-circleci-runner` allows only the runner user (uid 2000) to do this, and only to the job user.
- `setpriv` is the form without sudo. It comes from util-linux, switches to the job user, and clears every capability before it starts the task agent. The hardened class always uses it with `--no-new-privs`, which makes the job and everything it starts ignore the setuid bit, so `sudo`, `su`, or a vulnerable setuid binary cannot lift a job to root. An image that has no sudo uses `setpriv` too, whatever the setting.

The setting `MACHINE_RUNNER_SWARM_JOB_SUDO` chooses between the default and the hardened class. It is not the prefix itself. Refer to [Users and the runner token on Linux](concepts.md#users-and-the-runner-token-on-linux).

## Should I use the setup helper or the manual steps?

Both give the same result. The helper is optional, and every step of it is on the install pages.

| | `setup.sh` or `Setup.ps1` does | It does not |
|---|---|---|
| Linux | Checks the node, creates a single-node Swarm on the loopback address, creates secrets from hidden prompts, and deploys the stack files you name | Install Docker, install the runner (the `runner-distributor` service does that on every node), create resource classes or tokens, edit or copy the stack file, label or join nodes, or build images |
| Windows | Creates the Swarm, labels the node with the image tags it can run, creates secrets, and deploys | Install Docker or Windows features, create classes or tokens, edit or copy the stack file, add the labels of the optional classes, join other nodes, or build images |

The steps run in a fixed order, and a rerun is safe. The helper installs no runner on either OS: the distributor service of the stack does. Refer to [Optional: use the setup helper](install-linux.md#optional-use-the-setup-helper) and [the Windows helper](install-windows.md#optional-use-the-setup-helper).

## Why Swarm and not container runner or another runner?

Choose by what you already run and by the isolation that you need.

| You have or need | Use | Why |
|---|---|---|
| Elastic capacity, and nothing to host | CircleCI cloud executors | CircleCI runs and scales them. Choose them when your jobs do not need your own network, hardware, or data location |
| Kubernetes, and jobs that fit a `docker:` executor | [Container runner](https://circleci.com/docs/guides/execution-runner/container-runner-installation/) | CircleCI documents it, it scales pods, and it uses convenience images. Choose it when you have Kubernetes |
| A boundary stronger than a container, privileged or KVM jobs, a full OS, or autoscaling | [Machine runner orchestrator](https://circleci.com/docs/guides/execution-runner/machine-runner-orchestrator/) | A virtual machine for each job on Kubernetes with KubeVirt, and the token stays out of the VM. Refer to [Compared with the official runner installs](security.md#compared-with-the-official-runner-installs) |
| One host or a few, jobs that need the whole machine, or no containers at all | [Machine runner 3 on a host](https://circleci.com/docs/guides/execution-runner/runner-overview/#choosing-a-runner-execution-environment) | The simplest setup. Jobs share the host, and nothing separates one job from the next |
| The same, but in a container | [Machine runner 3 on Docker](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-docker/) | It runs the runner with `docker run`. The container is reused for more jobs until you stop it, so the environment is not clean |
| Docker hosts or Windows containers, no Kubernetes, and a clean container for every job | This repository | Swarm creates a new container for every job, and adds replicas, placement, secrets, and rolling updates. It has no support from CircleCI, no autoscaling, and no creation of nodes, and the containers share the host kernel |

Swarm mode is part of Docker Engine, and the stack files use only its core features: services, secrets, constraints, and rolling updates. To move to the orchestrator or to a plain machine runner later, keep the resource class names, and the jobs with `machine: true` stay as they are. Container runner needs the jobs to change to a `docker:` executor. CircleCI lists its own options in the [runner overview](https://circleci.com/docs/guides/execution-runner/runner-overview/).

The [microVM add-on](microvm.md) of this repository runs each job in a Kata Containers microVM on Swarm nodes that have KVM. It is experimental: CI runs the real runner against a fake CircleCI API on nested virtualization on AWS (amd64), and no real CircleCI job, other cloud, or arm64 is tested. If you need a hardware boundary today, the orchestrator is the documented route.

## Why not plain Docker Compose?

The earlier version of this repository used Docker Compose. Compose is simple, but it has a flaw that matters for clean environments.

| | Plain Compose | Docker Swarm |
|---|---|---|
| Restart | `restart: unless-stopped` restarts the same container | `restart_policy: any` creates a new task and a new container |
| Clean environment | No. Files outside the working directory survive a restart | Yes, for every job |
| Token storage | Environment file, visible in `docker inspect` | Swarm secret, mounted as a file |
| Hosts | One host | Many nodes, Linux and Windows, with placement |
| Updates and drain | Manual | Rolling update, and each busy runner drains (finishes its job) first |
| Setup | Nothing to learn beyond Compose | Swarm concepts, even on a single node |

The test `linux/tests/ephemerality.sh` includes a negative control that shows the flaw. Three jobs on `docker run --restart always` ran in one container, and two of them found files from an earlier job. A script can recreate containers in a Compose setup, but that is custom code that this repository avoids. If you use the old `docker-compose.yml`, refer to [Migrate from Docker Compose](migration.md).

## Is Docker Swarm a safe bet?

This project can state what it checks, and cannot promise the future of Swarm.

- **What it uses.** Only core Swarm features: services, secrets, configs, overlay networks, placement constraints, and rolling updates. It uses no add-on, and no plugin.
- **Which Docker versions.** The CI of this repository runs Docker 29.4.2 on Linux and 29.4.0 on Windows. The documented minimum is 24 on Linux and 28.0 on Windows ([Prerequisites](install-linux.md#prerequisites), [Windows](install-windows.md#prerequisites)).
- **The way out.** The resource class names are CircleCI objects, not Swarm objects. Jobs with `machine: true` keep their class when you move the class to the machine runner orchestrator or to a machine runner 3 on a host. [Why Swarm and not container runner or another runner?](#why-swarm-and-not-container-runner-or-another-runner) says what to use instead.
- **The support.** This is a CircleCI Labs project, `0.x`, with best-effort support and no commitment on how long it is maintained.

## Does it support macOS?

No. Docker has no macOS containers, so Swarm cannot schedule macOS jobs. Apple's licence also limits macOS to Apple hardware, so running macOS in a container on other hardware is not an option. CircleCI documents how to run machine runner 3 directly on a Mac, and CircleCI offers hosted macOS executors.

## Which operating systems does it support?

| Platform | Status |
|---|---|
| Linux, Ubuntu LTS, amd64 | Tested in CI, including real jobs |
| Linux, Ubuntu LTS, arm64 | Every pipeline tests that the distributor installs the runner and that the stack starts. On `main` and `smr-swarm/*` branches, three probe jobs also run on a real arm64 runner. |
| Linux, ppc64le and s390x | CircleCI publishes the runner for them, and the distributor and the token proxy are built for them. CI emulates them under QEMU: the distributor installs the runner of the right architecture, and the token proxy image runs on both. Nothing else runs there in CI |
| Linux, RHEL 8 and later | Steps documented, not tested in CI |
| Windows Server 2025 and 2022 | Tested in CI, on amd64 |
| Windows on arm64 | The distributor is built for it, and CI checks the file names. The token proxy has no `windows/arm64` image ([Windows](install-windows.md#the-token-proxy-image)). No Windows arm64 host runs the stack in CI |
| Windows Server 2019 | Supported by machine runner 3. Untested here, and the stack files have no label for it |
| Windows Server 2016 and older | Not compatible with machine runner 3 |
| macOS | Out of scope |

## Which CircleCI plans and platforms work?

The stack is tested against CircleCI cloud, on Linux and Windows. CircleCI server is not tested. CircleCI documents machine runner 3 for server 4.4 and later, and an install on server sets the runner API URL. This stack points the runners at the token proxy (`CIRCLECI_RUNNER_API_URL: http://token-proxy:8080`), so to try server you change the `-upstream` argument of the `token-proxy` service to the URL of your server, and keep the runner variable as it is. Nothing here shows that this works with your server version, and [CircleCI server](security.md#circleci-server) says what is known.

Self-hosted runners need at least one credit on your account, although runner compute does not use credits ([Run jobs on self-hosted runners](https://circleci.com/docs/guides/execute/run-jobs-on-self-hosted-runners/)). Their concurrency is separate from the concurrency of hosted jobs and is shared by every class of the organization: CircleCI can tell you your limit, and the **Runner** tab of your organization shows it. Config policies, which restrict classes to projects, need the Scale plan on cloud or server 4.2 or later ([Config policy management overview](https://circleci.com/docs/guides/config-policies/config-policy-management-overview/)).

## How do I scale up or down, and see how many jobs wait?

Swarm has no autoscaling, so you choose the number of replicas.

- **Permanent change.** Edit `deploy.replicas` in your stack file and deploy again with the same list of files. Refer to [Choose replica counts](resource-classes.md#choose-replica-counts). To add capacity beyond one node, add nodes. Refer to [Multi-Node Clusters](multi-node.md).
- **Quick change.** `docker service scale runners_linux-default=4`. The next `docker stack deploy` resets the count to the value in the file. A scale-down stops containers: on Linux a running job finishes first, and on Windows it is killed ([why](operations.md#stop-a-busy-windows-container)).
- **Queue depth.** The runner API reports the tasks that wait for a runner of a class. Use a personal API token, not a resource class token.

  ```console
  $ curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" \
      "https://runner.circleci.com/api/v3/runner/tasks?resource-class=<namespace>/linux-default"
  {"unclaimed_task_count": 3}
  $ curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" \
      "https://runner.circleci.com/api/v3/runner/tasks/running?resource-class=<namespace>/linux-default"
  {"running_runner_tasks": 2}
  ```

  Jobs wait while `unclaimed_task_count` stays above 0 and every replica is busy. Raise the replicas by that number, if the nodes have room. Refer to [Monitor the cluster](operations.md#monitor-the-cluster).

## Does it scale to zero, and what does idle capacity cost?

No. Capacity is fixed: the replicas are numbers in your stack file, and you pay for the peak. An idle replica keeps its reserved CPU and memory (reservations equal limits), on nodes that you run, so the cost of an idle class is the cost of its nodes. Scale to zero is a manual `replicas: 0`, and a class with no runner queues jobs without limit and holds concurrency ([Capacity and concurrency](operations.md#capacity-and-concurrency)). This documentation does not say which replica a scale-down removes, and a scale-down while jobs run is not tested: assume that it can remove a busy replica. On Windows it kills the job. If you need elastic capacity, use the machine runner orchestrator or CircleCI cloud executors. A script that reads the queue depth (below) and runs `docker service scale` is possible, and this repository does not ship one.

## Does it create or remove nodes?

No. The nodes are yours. You install Docker, join the node to the Swarm, and label it from a manager (a node cannot label itself), and a Windows node needs its base image before the first task. A terminated instance leaves a `Down` node in the Swarm until you run `docker node rm`. This repository has no cloud integration, no machine image, and no example of user data. If you create nodes with user data, do not leave the Swarm join token readable in it ([Cloud nodes: block the metadata address](security.md#cloud-nodes-block-the-metadata-address)). Refer to [Multi-Node Clusters](multi-node.md).

## Where are the tokens kept, and can I use my secrets manager?

Class tokens are Swarm secrets, and nothing else: the stack has no integration with an external secrets manager. Anyone in the `docker` group on a manager can read every token, and a Windows secret is stored in clear text on the disk of the container of the proxy ([Token model on each OS](security.md#token-model-on-each-os)). Rotation is a manual procedure that CI does not test ([Rotate a runner token](operations.md#rotate-a-runner-token)). If you need tokens in a secrets manager, that is outside this repository.

## What is not in this release?

- Autoscaling and creation of nodes.
- Metrics export. The stack exposes no metrics endpoint ([Monitor the cluster](operations.md#monitor-the-cluster)).
- An external secrets manager, and a tested rotation of tokens.
- A hardened Windows class, and Hyper-V isolation.
- CircleCI server and hosts without internet access: neither is tested ([What needs internet](security.md#what-needs-internet)).
- A one-command verification script. A release is checked with the commands of [Verify a release](install-linux.md#verify-a-release).

## Is there a delay between jobs?

A replica needs about 10 seconds for the restart delay, plus the start-up time of the container and the download of the task agent, before it claims the next job. Other replicas of the class keep working during that time. Refer to [Job lifecycle](concepts.md#job-lifecycle).

## Do I need to open inbound ports?

No. Runners connect outbound over HTTPS, and the shipped classes publish no ports. Only the optional SSH add-on publishes port 54782, for [Rerun job with SSH](resource-classes.md#rerun-job-with-ssh). Multi-node clusters need the Swarm ports between the nodes. Refer to [Inter-node ports](multi-node.md#inter-node-ports).

## Can I run a long-lived runner with warm caches?

Yes, with a persistent class. It gives up the clean environment, so use it only for trusted projects. The shipped Linux persistent class gives jobs no sudo by default. Refer to [Persistent mode](resource-classes.md#persistent-mode).

## Can I use Rerun job with SSH?

Yes, with the add-on stack file `ssh-rerun.yaml`. It defines the class `linux-default-ssh` (`windows-default-ssh` on Windows), which sets `CIRCLECI_RUNNER_SSH_ADVERTISE_ADDR`, publishes port 54782 in host mode, and runs at most one replica on each node. A rerun uses the class of the original job, so the job that you debug must run on that class. The Swarm side was proven by hand with a real runner. No CI test logs in over SSH, and the Windows file is untested. Refer to [Rerun job with SSH](resource-classes.md#rerun-job-with-ssh).

## Can a job read the runner token?

Not from its own container in a single-task class, with or without sudo: the runner container holds only a made-up placeholder, and the [token proxy](security.md#the-token-proxy) holds the class token. On Windows, no test asserts this, and a hostile job on the same host as the proxy can reach the token, because process isolation is not a security boundary ([Windows](security.md#windows)). In a persistent class the container holds the token: on Linux a job that uses sudo can read it (the shipped persistent class disables sudo by default), and every job can on Windows. Swarm also stores a Windows secret in clear text on the container disk, so use BitLocker and one token for each class and host. Refer to [Token model on each OS](security.md#token-model-on-each-os) and to the [comparison with the official installs](security.md#compared-with-the-official-runner-installs). A holder of a token can run a rogue runner on that class and claim its jobs, so rotate tokens ([how](operations.md#rotate-a-runner-token)).

## What is the token proxy, and what happens when it is down?

It is the service `token-proxy` in the Linux `runners.yaml` (`token-proxy-windows` in the Windows one). It holds the resource class tokens, so that the runner containers and their jobs never do. The runners hold a made-up placeholder and send their API calls to the proxy, which adds the real token to the task claim of a runner that Swarm lists in the DNS set of its class, once for each container. Refer to [Concepts](concepts.md#the-token-proxy) and [Security](security.md#the-token-proxy).

When it is down, no runner can claim, and the jobs wait in CircleCI. Idle runners fail their claims and try again. They send nothing to CircleCI on their own, because they hold no token. Swarm restarts a failed proxy after 5 seconds. A claim whose outcome is unknown (the request reached CircleCI and the answer was lost, or the upstream sent no response headers within 60 seconds) is latched like a successful claim: that runner is refused until Swarm replaces it, so the proxy fails closed. A job that already runs keeps its container, but its API calls, such as step output, go through the proxy too, so keep outages to a restart. Refer to [Monitor the token proxy](operations.md#monitor-the-token-proxy), including what a restart does to idle runners. The proxy runs on a manager by default. On a single node it needs no label. In a cluster, label the node that runs it `machine-runner-swarm.proxy=true`: runner services never run on a node with that label. Refer to [Where the proxy runs, and when it moves](operations.md#where-the-proxy-runs-and-when-it-moves) for what happens when it moves to another node. The proxy limits every client address to 50 requests a second (bursts of 200) and serves at most 512 requests at once, so one runner or job cannot use it up alone, and it logs a summary line a minute ([The token proxy](security.md#the-token-proxy)). The persistent classes do not use the proxy.

## Why does a Windows job end when I update or stop a service?

Stopping a busy stock Server Core container from outside kills its job after about 5 seconds, whatever `stop_grace_period` says, and a finished job ends its container cleanly. Roll out changes while the class is idle, or rerun the interrupted jobs. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

## Which runner version do the nodes run?

The `runner-distributor` service of the stack decides, and the setup helper installs nothing. The default is an exact pin with the tarball SHA-256 values in the stack file: the newest runner version that the CI of this repository tests, which each release of this repository bumps. The nodes keep it until you change it. To float instead, set `MACHINE_RUNNER_SWARM_RUNNER_VERSION` to `3.1` (the newest `3.1.x`), `3` (the newest `3.x.y`) or `current` (CircleCI's current release); the distributor then trusts the manifest's hash (weaker), and looks again every 24 hours. Floating is supported and is the weaker choice: the manifest comes from the same bucket as the tarball, and a newer runner can change the protocol that the token proxy depends on (the claim and scale calls), in which case the proxy fails closed and jobs wait. Pin an exact version in production. No second setting is needed to float. To go back, pin an older version. Refer to [The version policy](operations.md#the-version-policy).

On Windows, `runner-distributor-windows` decides in the same way, with the same variables. Refer to [Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows).

## How does the runner version policy compare with machine runner 3, container runner and the orchestrator?

It follows them. Machine runner 3 on a host has no auto-update: you update the package. Container runner takes the image tag from the Helm values that you set, and publishes a floating tag for each major and minor version next to a fixed tag for each patch release. The orchestrator takes its pool image from the Helm chart, with a floating default tag and a dated tag that pins it. Here the version is a setting of the distributor service: an exact pin by default, and `3.1`, `3` or `current` when you want the newest release of a line. Refer to [How this compares](operations.md#how-this-compares-with-machine-runner-3-container-runner-and-the-orchestrator).

## How do I verify a release?

Each release has a `SHA256SUMS` file and a keyless cosign signature that was made with the CircleCI OIDC token. Refer to [Verify a release](install-linux.md#verify-a-release), or [Verify a release](install-windows.md#verify-a-release) on Windows. Those pages run the signature check, the ref check (`refs/heads/main` in the certificate), and the checksum check in one block that prints `RELEASE VERIFIED` only when all three pass. The runner binary is a separate download. On Linux, the distributor verifies its SHA-256 and the entrypoint checks it at every container start. Refer to [Runner binary integrity on Linux](security.md#runner-binary-integrity-on-linux).

## Can a fork pull request use these runners?

No. CircleCI does not make self-hosted runners available to a public project that has **Build forked pull requests** enabled, because untrusted code on your machines is a significant risk. Keep that setting off for any project that uses these classes. For a private project, a collaborator's branch runs your code on the node, so restrict each class to the projects that need it. Refer to [CircleCI-side controls](security.md#circleci-side-controls).

## Which jobs cannot run here?

The jobs run in unprivileged containers on a shared kernel, so some jobs belong on another runner.

| Job needs | Here | Use instead |
|---|---|---|
| A privileged container, `/dev/kvm`, or other host devices | No. Swarm ignores `privileged` and `devices`. The [microVM add-on](microvm.md) gives a job its own kernel, not host devices | The machine runner orchestrator, or a machine runner on a host |
| Docker-in-Docker | No, because it needs a privileged container | The opt-in [docker-build class](docker-builds.md), a daemonless builder, or a daemon inside the VM of the [microVM add-on](microvm.md#run-docker-inside-the-vm) |
| `setup_remote_docker` | No. It belongs to the Docker executor | The docker-build class, or a daemonless builder |
| Docker commands in a job | Only in the docker-build class, which is root-equivalent on its node | [Docker Builds](docker-builds.md) |
| A GPU | Not supported or tested. The stack files declare no generic resources | A machine runner on a GPU host |
| Service containers (`docker:` secondary images) | No. Jobs use `machine: true` | Install the service in the image, or use container runner |
| Desktop or UI automation on Windows | No. Windows jobs are headless | A machine runner on a host |
| A `docker:` executor job | No. Jobs use `machine: true`, and the image of the service is the environment of the job | Container runner |

## Do proxies and custom certificate authorities work?

The stack sets nothing for them, and this repository does not test them.

- **Proxy.** Set `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` under `environment` of the service. The runner is a Go program that reads them, and jobs inherit them. Test a checkout through the proxy before you roll out a class. Refer to [Egress hosts](security.md#egress-hosts). On Linux, also set `HTTPS_PROXY` under `environment` of the `token-proxy` service, because it makes the call to `runner.circleci.com` for the runners, and add `NO_PROXY: token-proxy` to the runners, so that their calls to it stay on the overlay network.
- **Certificate authority.** Add your CA to a custom image and run `update-ca-certificates`, or mount a CA bundle read-only and point `SSL_CERT_FILE` at it. Windows images need the CA in the image too. On Linux, the token proxy needs the CA too when a proxy or your CircleCI server uses it: mount the bundle into `token-proxy` and set `SSL_CERT_FILE` there. Refer to [Images](images.md).

## Does it work on hosts without internet access?

No, and it is not tested. A host without internet access is not supported by this release. Every runner needs outbound HTTPS to `runner.circleci.com`, and every new container downloads the task agent from `circleci-binary-releases.s3.amazonaws.com`. A host that reaches those names through an allow list or a proxy works. On Linux, the runner download of the distributor can come from a mirror of your own: set `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` to an internal HTTP server that holds `manifest.json` and the tarballs. Refer to [Run the downloads from a mirror](operations.md#run-the-downloads-from-a-mirror). The mirror does not replace the task agent download. Pull the images, including `alpine` for the distributor, from a registry that the nodes can reach. Refer to [Registry needs](multi-node.md#registry-needs). [What needs internet](security.md#what-needs-internet) lists every download.

## Does it work with rootless Docker, user namespaces, or Podman?

- **Podman** cannot run Swarm, so it cannot run this stack.
- **Rootless Docker** and **`userns-remap`** are not tested. The stack assumes a root daemon: the entrypoint checks that the runner volume belongs to root, and the secret belongs to uid 2000. Whether these checks hold under a remap is untested. Swarm also ignores `userns_mode` in stack files.

## Does it work with SELinux on RHEL?

The RHEL steps are documented and not tested in CI. Keep SELinux enforcing. The runner is in a Docker volume and not in a host directory, so no directory needs a label for it.

## What happens to a job when a node dies?

The job is lost. CircleCI reports it as failed because of an infrastructure problem, and self-hosted runners do not retry a job automatically, so rerun it. Swarm detects the lost node, and starts replacement runners on other nodes that match the constraints, which restores the capacity. A single manager that dies stops all replacements, and the quorum rules of [Managers and quorum](multi-node.md#managers-and-quorum) apply. Refer to [Node death](operations.md#node-death).

## How do I report a bug or a vulnerability?

Open a [GitHub issue](https://github.com/CircleCI-Labs/scalable-machine-runner/issues) for a bug. For a vulnerability, email [security@circleci.com](mailto:security@circleci.com). Refer to [SECURITY.md](../SECURITY.md).
