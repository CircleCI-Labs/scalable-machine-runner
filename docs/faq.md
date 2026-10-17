---
page-title: FAQ
page-audience: admin
page-description: Short answers about the Swarm runner stack: what it is, support, comparisons with official runners, scaling, unsupported jobs, and node loss.
---

# FAQ

## What is this repository?

Docker Swarm stack files, a Linux entrypoint, a service that keeps the runner on every node, optional setup helpers, and documentation. Together they run CircleCI machine runner 3 in containers, with one resource class for each Swarm service and a new container for every job. Refer to [Concepts](concepts.md).

## Does CircleCI support it?

No. It is part of CircleCI Labs, a pre-release `0.x` project, and CircleCI support does not cover it. Field engineering handles issues on a best-effort basis. Your normal CircleCI support covers the runner itself, the platform, and your resource classes. [What is tested](../README.md#what-is-tested) says how each claim is checked, and which are not.

## What must I build?

Nothing, with one optional exception on Windows. Swarm pulls one published image, the token proxy (`ccilabs/machine-runner-swarm-proxy`), and the release bundle names it by digest.

| | Needs | Optional |
|---|---|---|
| Linux | A Docker engine and a Swarm join. The `runner-distributor` service fills a per-node volume with the runner, and a stock image such as `cimg/base` runs it | A custom image when jobs need tools (it needs util-linux `setpriv`). Refer to [Images](images.md) |
| Windows | A Docker engine, the `ltsc2022` base image, and a Swarm join. The `runner-distributor-windows` service installs the runner and portable Git into a volume | A custom image, and a DIY image that lets a job finish after a stop. Refer to [Windows images](images.md#windows-bring-your-own-image) and [the stop-timeout image](operations.md#optional-an-image-that-lets-a-job-finish-after-a-stop-diy) |

## What do `sudo -niHu` and `setpriv` mean?

They are the two forms of the runner `command_prefix`, which makes a job run as another user ([reference](https://circleci.com/docs/guides/execution-runner/machine-runner-3-configuration-reference/#runner-command-prefix)). The entrypoint sets it in every Linux container, and the service environment cannot override it.

- `sudo -niHu circleci --` is the default class: never prompt, login shell, `HOME` of the target user, run as `circleci`. `/etc/sudoers.d/90-circleci-runner` allows only the runner user (uid 2000), and only to the job user.
- `setpriv` (util-linux) switches to the job user and clears every capability. The hardened class always uses it with `--no-new-privs`, so `sudo`, `su` or a setuid binary cannot lift a job to root. An image with no sudo uses it too.

`MACHINE_RUNNER_SWARM_JOB_SUDO` chooses between the two classes ([Users and the runner token on Linux](concepts.md#users-and-the-runner-token-on-linux)).

## Should I use the setup helper or the manual steps?

Either. Both give the same result, and every helper step is on the install pages ([Linux](install-linux.md#optional-use-the-setup-helper), [Windows](install-windows.md#optional-use-the-setup-helper)). A rerun is safe.

- **The helper does:** check the node, create a single-node Swarm, create secrets from hidden prompts, and deploy the stack files you name. On Windows it also labels the node with the image tags it can run.
- **It does not:** install Docker or the runner (the distributor does), create classes or tokens, edit the stack file, label or join other nodes, or build images.

## Why Swarm and not container runner or another runner?

Choose by what you already run and the isolation you need.

| You have or need | Use |
|---|---|
| Elastic capacity, nothing to host | CircleCI cloud executors |
| Kubernetes, jobs that fit a `docker:` executor | [Container runner](https://circleci.com/docs/guides/execution-runner/container-runner-installation/) |
| A boundary stronger than a container, privileged or KVM jobs, a full OS, autoscaling | [Machine runner orchestrator](https://circleci.com/docs/guides/execution-runner/machine-runner-orchestrator/): a VM for each job on Kubernetes with KubeVirt, and the token stays out of the VM ([comparison](security.md#compared-with-the-official-runner-installs)) |
| One host or a few, jobs that need the whole machine | [Machine runner 3 on a host](https://circleci.com/docs/guides/execution-runner/runner-overview/#choosing-a-runner-execution-environment): the simplest setup, nothing separates one job from the next |
| The same, in a container | [Machine runner 3 on Docker](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-docker/): the container is reused, so the environment is not clean |
| Docker hosts or Windows containers, no Kubernetes, a clean container for every job | This repository: replicas, placement, secrets and rolling updates. No CircleCI support, no autoscaling, no node creation, and containers share the host kernel |

The stack files use only core Swarm features. To move to the orchestrator or a plain machine runner later, keep the resource class names, and jobs with `machine: true` stay as they are. Container runner needs jobs that use a `docker:` executor.

The [microVM add-on](microvm.md) runs each job in a Kata Containers microVM on Swarm nodes with KVM. It is experimental: CI runs the real runner against a fake CircleCI API on nested virtualization on AWS (amd64), and no real CircleCI job, other cloud, or arm64 is tested in CI. One real CircleCI job ran by hand on a Kata Cloud Hypervisor class. If you need a hardware boundary today, use the orchestrator.

## Why not plain Docker Compose?

Compose restarts the same container, so files outside the working directory survive into the next job. Swarm creates a new task and container for every job, keeps the token in a Swarm secret instead of an environment file visible in `docker inspect`, and adds many nodes with placement, rolling updates and drain. The price is Swarm concepts, even on one node.

`linux/tests/ephemerality.sh` has a negative control: three jobs on `docker run --restart always` ran in one container, and two found files from an earlier job. To move off the old `docker-compose.yml`, refer to [Migrate from Docker Compose](migration.md).

## Is Docker Swarm a safe bet?

The project can state what it checks, and cannot promise the future of Swarm.

- **What it uses.** Core Swarm features only: services, secrets, configs, overlay networks, placement constraints, rolling updates.
- **Docker versions.** CI runs Docker 29.4.2 on Linux and 29.4.0 on Windows. The documented minimum is 24 on Linux and 28.0 on Windows ([Linux](install-linux.md#prerequisites), [Windows](install-windows.md#prerequisites)).
- **The way out.** Resource class names are CircleCI objects, so jobs with `machine: true` keep their class when you move it ([alternatives](#why-swarm-and-not-container-runner-or-another-runner)).
- **Support.** CircleCI Labs, `0.x`, best effort, no commitment on how long it is maintained.

## Does it support macOS?

No. Docker has no macOS containers, so Swarm cannot schedule macOS jobs. CircleCI documents machine runner 3 on a Mac directly, and offers hosted macOS executors.

## Which operating systems does it support?

| Platform | Status |
|---|---|
| Linux, Ubuntu LTS, amd64 | Tested in CI, including real jobs |
| Linux, Ubuntu LTS, arm64 | Every pipeline tests that the distributor installs the runner and that the stack starts. On `main` and `smr-swarm/*` branches, three probe jobs also run on a real arm64 runner |
| Linux, ppc64le and s390x | The distributor and token proxy are built for them. CI emulates them under QEMU: the distributor installs the runner of the right architecture, and the token proxy image runs. Nothing else runs there |
| Linux, RHEL 8 and later | Steps documented, not tested in CI |
| Windows Server 2025 and 2022 | Tested in CI, on amd64 |
| Windows on arm64 | The distributor is built for it. The token proxy has no `windows/arm64` image ([Windows](install-windows.md#the-token-proxy-image)). No arm64 host runs the stack in CI |
| Windows Server 2019 | Supported by machine runner 3. Untested here, and the stack files have no label for it |
| Windows Server 2016 and older | Not compatible with machine runner 3 |
| macOS | Out of scope |

## Which CircleCI plans and platforms work?

CircleCI cloud, on Linux and Windows. CircleCI server is not tested. To try server, change the `-upstream` argument of the `token-proxy` service to your server URL and keep `CIRCLECI_RUNNER_API_URL: http://token-proxy:8080` on the runners ([CircleCI server](security.md#circleci-server)).

Self-hosted runners need at least one credit on your account, although runner compute does not use credits ([Run jobs on self-hosted runners](https://circleci.com/docs/guides/execute/run-jobs-on-self-hosted-runners/)). Their concurrency is separate from hosted jobs and shared by every class of the organization (see the **Runner** tab). Config policies, which restrict classes to projects, need the Scale plan on cloud or server 4.2 or later ([Config policy management overview](https://circleci.com/docs/guides/config-policies/config-policy-management-overview/)).

## How do I scale up or down, and see how many jobs wait?

Swarm has no autoscaling, so you choose the number of replicas.

- **Permanent.** Edit `deploy.replicas` in your stack file and deploy again with the same files ([Choose replica counts](resource-classes.md#choose-replica-counts)). To go beyond one node, add nodes ([Multi-Node Clusters](multi-node.md)).
- **Quick.** `docker service scale runners_linux-default=4`. The next `docker stack deploy` resets it. A scale-down stops containers: on Linux a running job finishes first, and on Windows it is killed ([why](operations.md#stop-a-busy-windows-container)).
- **Queue depth.** Ask the runner API with a personal API token, not a resource class token:

  ```bash
  curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" "https://runner.circleci.com/api/v3/runner/tasks?resource-class=<NAMESPACE>/linux-default"
  curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" "https://runner.circleci.com/api/v3/runner/tasks/running?resource-class=<NAMESPACE>/linux-default"
  ```

  The first prints `{"unclaimed_task_count": 3}`, the second `{"running_runner_tasks": 2}`. Jobs wait while `unclaimed_task_count` stays above 0 and every replica is busy. Raise the replicas by that number if the nodes have room ([Monitor the cluster](operations.md#monitor-the-cluster)).

## Does it scale to zero, and what does idle capacity cost?

No. Capacity is fixed and you pay for the peak: an idle replica keeps its reserved CPU and memory on nodes that you run. Scale to zero is a manual `replicas: 0`, and a class with no runner queues jobs without limit and holds concurrency ([Capacity and concurrency](operations.md#capacity-and-concurrency)). Which replica a scale-down removes is not documented, and a scale-down while jobs run is not tested: assume it can remove a busy one (on Windows it kills the job). For elastic capacity, use the machine runner orchestrator or CircleCI cloud executors.

## Does it create or remove nodes?

No. You install Docker, join the node to the Swarm, and label it from a manager (a node cannot label itself), and a Windows node needs its base image before the first task. A terminated instance leaves a `Down` node until you run `docker node rm`. There is no cloud integration or machine image. If you create nodes with user data, do not leave the Swarm join token readable in it ([Cloud nodes: block the metadata address](security.md#cloud-nodes-block-the-metadata-address)). Refer to [Multi-Node Clusters](multi-node.md).

## Where are the tokens kept, and can I use my secrets manager?

Class tokens are Swarm secrets. There is no integration with an external secrets manager. Anyone in the `docker` group on a manager can read every token, and a Windows secret is stored in clear text on the disk of the proxy container ([Token model on each OS](security.md#token-model-on-each-os)). Rotation is manual and not tested in CI ([Rotate a runner token](operations.md#rotate-a-runner-token)).

## What is not in this release?

- Autoscaling and creation of nodes.
- Metrics export ([Monitor the cluster](operations.md#monitor-the-cluster)).
- An external secrets manager, and a tested rotation of tokens.
- A hardened Windows class, and Hyper-V isolation.
- CircleCI server and hosts without internet access: neither is tested ([What needs internet](security.md#what-needs-internet)).
- A one-command verification script. Use the commands of [Verify a release](install-linux.md#verify-a-release).

## Is there a delay between jobs?

About 10 seconds for the restart delay, plus container start and the task agent download, before a replica claims the next job. Other replicas keep working meanwhile. Refer to [Job lifecycle](concepts.md#job-lifecycle).

## Do I need to open inbound ports?

No. Runners connect outbound over HTTPS, and the shipped classes publish no ports. Only the optional SSH add-on publishes port 54782 ([Rerun job with SSH](resource-classes.md#rerun-job-with-ssh)). Multi-node clusters need the Swarm ports between nodes ([Inter-node ports](multi-node.md#inter-node-ports)).

## Can I run a long-lived runner with warm caches?

Yes, with a persistent class. It gives up the clean environment, so use it only for trusted projects. The shipped Linux persistent class gives jobs no sudo by default. Refer to [Persistent mode](resource-classes.md#persistent-mode).

## Can it run Docker executor jobs?

As a prototype, yes. The classes of this repository run jobs with `machine: true`. [Container mode](container-mode.md) adds a Swarm service on each opted-in Linux node that runs jobs with a `docker:` list and its service containers, as container runner does on Kubernetes. It has no SSH reruns and no Docker layer caching, and it has not yet run against the real CircleCI API. A resource class serves one mode, so give container mode its own classes and tokens. For production Docker executor jobs today, use container runner.

## Can I use Rerun job with SSH?

Yes, with the add-on file `ssh-rerun.yaml`, which defines `linux-default-ssh` (`windows-default-ssh` on Windows). A rerun uses the class of the original job, so the job to debug must run on that class. It is experimental: the Swarm side was proven by hand, no CI test logs in over SSH, and the Windows file is untested. Refer to [Rerun job with SSH](resource-classes.md#rerun-job-with-ssh).

## Can a job read the runner token?

Not in a single-task class, with or without sudo: the runner container holds only a made-up placeholder, and the [token proxy](security.md#the-token-proxy) holds the class token. On Windows no test asserts this, and a hostile job on the same host as the proxy can reach the token, because process isolation is not a security boundary ([Windows](security.md#windows)). In a persistent class the container holds the token: on Linux a job that uses sudo can read it (the shipped class disables sudo), and on Windows every job can. Use BitLocker and one token for each class and host. A holder of a token can run a rogue runner on that class, so rotate tokens ([how](operations.md#rotate-a-runner-token)). Refer to [Token model on each OS](security.md#token-model-on-each-os).

## What is the token proxy, and what happens when it is down?

The service `token-proxy` (`token-proxy-windows` on Windows) holds the class tokens so that runner containers and jobs never do. Runners hold a placeholder and send their API calls to the proxy, which adds the real token to the task claim, once for each container. Persistent classes do not use it. Refer to [The token proxy](concepts.md#the-token-proxy) and [Security](security.md#the-token-proxy).

When it is down, no runner can claim and jobs wait in CircleCI. Idle runners fail their claims and retry, and Swarm restarts a failed proxy after 5 seconds. A running job keeps its container, but its API calls (step output) also go through the proxy, so keep outages to a restart. A claim whose outcome is unknown is latched like a successful claim: that runner is refused until Swarm replaces it, so the proxy fails closed.

- **Placement.** The proxy runs on a manager by default. In a cluster, label its node `machine-runner-swarm.proxy=true`: runner services never run there ([Where the proxy runs, and when it moves](operations.md#where-the-proxy-runs-and-when-it-moves)).
- **Limits.** Each client address gets 50 requests a second (bursts of 200), and the proxy serves at most 512 requests at once.
- **Monitoring.** [Monitor the token proxy](operations.md#monitor-the-token-proxy).

## Why does a Windows job end when I update or stop a service?

Stopping a busy stock Server Core container from outside kills its job after about 5 seconds, whatever `stop_grace_period` says. Change services while the class is idle, or rerun the interrupted jobs. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

## Which runner version do the nodes run?

The `runner-distributor` service decides. The default is an exact pin, with the tarball SHA-256 values in the stack file: the newest runner version that CI tests, bumped by each release. Nodes keep it until you change it. To float, set `MACHINE_RUNNER_SWARM_RUNNER_VERSION` to `3.1`, `3` or `current`. Floating is weaker: the distributor trusts the manifest hash, and a newer runner can change the protocol that the proxy depends on, so the proxy fails closed and jobs wait. Pin an exact version in production. `runner-distributor-windows` works the same way. Refer to [The version policy](operations.md#the-version-policy) and [Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows).

## How does the runner version policy compare with machine runner 3, container runner and the orchestrator?

It follows them: machine runner 3 on a host has no auto-update, container runner and the orchestrator take the image tag from Helm values, and here it is a setting of the distributor, an exact pin by default. Refer to [How this compares](operations.md#how-this-compares-with-machine-runner-3-container-runner-and-the-orchestrator).

## How do I verify a release?

Each release has a `SHA256SUMS` file and a keyless cosign signature made with the CircleCI OIDC token. Run the single check block on [Verify a release](install-linux.md#verify-a-release) (or [on Windows](install-windows.md#verify-a-release)): it prints `RELEASE VERIFIED` only when the signature, the ref (`refs/heads/main`) and the checksums all pass. The runner binary is a separate download: the distributor verifies its SHA-256, and on Linux the entrypoint checks it at every container start ([Runner binary integrity on Linux](security.md#runner-binary-integrity-on-linux)).

## Can a fork pull request use these runners?

No. CircleCI does not make self-hosted runners available to a public project that has **Build forked pull requests** enabled. Keep that setting off for any project that uses these classes. For a private project, a collaborator's branch runs your code on the node, so restrict each class to the projects that need it ([CircleCI-side controls](security.md#circleci-side-controls)).

## Which jobs cannot run here?

Jobs run in unprivileged containers on a shared kernel, so some belong on another runner.

| Job needs | Here | Use instead |
|---|---|---|
| A privileged container, `/dev/kvm`, or host devices | No. Swarm ignores `privileged` and `devices`. The [microVM add-on](microvm.md) gives a job its own kernel, not host devices | The orchestrator, or a machine runner on a host |
| Docker-in-Docker, `setup_remote_docker`, or Docker commands in a job | No, except in the opt-in [docker-build class](docker-builds.md), which is root-equivalent on its node | The docker-build class, a daemonless builder, or a daemon in the VM of the [microVM add-on](microvm.md#run-docker-inside-the-vm) |
| A GPU | Not supported or tested | A machine runner on a GPU host |
| A `docker:` executor job, or service containers | Only in [container mode](container-mode.md), a prototype, in classes of its own | Container mode, or container runner |
| Desktop or UI automation on Windows | No. Windows jobs are headless | A machine runner on a host |

## Do proxies and custom certificate authorities work?

The stack sets nothing for them, and this repository does not test them.

- **Proxy.** Set `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` under `environment` of the service. Jobs inherit them. On Linux, also set `HTTPS_PROXY` on `token-proxy`, which calls `runner.circleci.com` for the runners, and add `NO_PROXY: token-proxy` to the runners. Test a checkout through the proxy before you roll out a class ([Egress hosts](security.md#egress-hosts)).
- **Certificate authority.** Add your CA to a custom image and run `update-ca-certificates`, or mount a CA bundle read-only and point `SSL_CERT_FILE` at it. Windows images need the CA in the image. On Linux, the token proxy needs the CA too when a proxy or your CircleCI server uses it: mount the bundle into `token-proxy` and set `SSL_CERT_FILE` there ([Images](images.md)).

## Does it work on hosts without internet access?

No, and it is not tested. Every runner needs outbound HTTPS to `runner.circleci.com`, and every new container downloads the task agent from `circleci-binary-releases.s3.amazonaws.com`. A host that reaches those names through an allow list or a proxy works. On Linux the distributor download can come from your own mirror: set `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` ([Run the downloads from a mirror](operations.md#run-the-downloads-from-a-mirror)). The mirror does not replace the task agent download, and the images must come from a registry the nodes reach ([Registry needs](multi-node.md#registry-needs)). [What needs internet](security.md#what-needs-internet) lists every download.

## Does it work with rootless Docker, user namespaces, or Podman?

- **Podman** cannot run Swarm, so it cannot run this stack.
- **Rootless Docker** and **`userns-remap`** are not tested. The stack assumes a root daemon: the entrypoint checks that the runner volume belongs to root, and the secret belongs to uid 2000. Swarm also ignores `userns_mode` in stack files.

## Does it work with SELinux on RHEL?

The RHEL steps are documented and not tested in CI. Keep SELinux enforcing. The runner is in a Docker volume, so no host directory needs a label. For a denial, refer to [Troubleshooting](troubleshooting.md#permission-denied-on-optmachine-runner-swarm-with-selinux).

## What happens to a job when a node dies?

The job is lost. CircleCI reports an infrastructure failure, and self-hosted runners do not retry, so rerun it. Swarm starts replacement runners on other matching nodes. A single manager that dies stops all replacements ([Managers and quorum](multi-node.md#managers-and-quorum)). Refer to [Node death](operations.md#node-death).

## How do I report a bug or a vulnerability?

Open a [GitHub issue](https://github.com/CircleCI-Labs/machine-runner-swarm/issues) for a bug. For a vulnerability, email [security@circleci.com](mailto:security@circleci.com) ([SECURITY.md](../SECURITY.md)).
