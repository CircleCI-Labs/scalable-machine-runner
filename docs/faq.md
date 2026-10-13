---
page-title: FAQ
page-audience: admin
page-description: Answers to common questions about the Docker Swarm runner stack, including what to build, how it compares with the official runners, scaling, unsupported jobs, and node loss.
---

# FAQ

## What is this repository?

It is a set of Docker Swarm stack files, a small Linux entrypoint, optional setup helpers, and documentation. Together they run CircleCI machine runner 3 in containers, with one resource class for each Swarm service and a new container for every job. Refer to [Concepts](concepts.md).

## Does CircleCI support it?

No. This repository is part of CircleCI Labs. CircleCI field engineers created it and real customers use it, but CircleCI support does not cover it. Field engineering handles issues on a best-effort basis. The runner itself, the CircleCI platform, and your resource classes are covered by your normal CircleCI support.

## What must I build?

Nothing, with one optional exception on Windows.

| | You build | Optional |
|---|---|---|
| Linux | Nothing. The stack mounts the runner and the entrypoint from the host into a stock image such as `cimg/base`. You install them with a few commands or with `linux/setup.sh` | A custom image when jobs need tools, because the hardened class cannot install packages at run time. It needs util-linux `setpriv`. Refer to [Images](images.md) |
| Windows | Nothing. The stack mounts the runner and portable Git from `C:\machine-runner-swarm` into the stock Server Core image. `windows\Setup.ps1` stages them | A custom image for your tools, and a DIY image that lets a job finish after a stop. Refer to [Windows images](images.md#windows-bring-your-own-image) and [the stop-timeout image](operations.md#optional-an-image-that-lets-a-job-finish-after-a-stop-diy) |

This repository publishes no images. The Linux and Windows hosts need the files from the install pages and a Docker engine, and that is all.

## What do `sudo -niHu` and `setpriv` mean?

They are the two forms of the runner's `command_prefix`, the setting that wraps the task agent so that a job runs as another user. CircleCI documents the setting in the [machine runner 3 configuration reference](https://circleci.com/docs/guides/execution-runner/machine-runner-3-configuration-reference/#runner-command-prefix). The entrypoint sets it in every Linux container, and a value in the service environment does not override it.

- `sudo -niHu circleci --` is the default class. The flags are `-n` (never prompt: fail instead), `-i` (run a login shell), `-H` (set `HOME` to the home directory of the target user), and `-u circleci` (the target user). `--` ends the options, and the task agent follows. The file `/etc/sudoers.d/90-circleci-runner` allows only the runner user (uid 2000) to do this, and only to the job user.
- `setpriv` is the form without sudo. It comes from util-linux, switches to the job user, and clears every capability before it starts the task agent. The hardened class always uses it with `--no-new-privs`, which makes the job and everything it starts ignore the setuid bit, so `sudo`, `su`, or a vulnerable setuid binary cannot lift a job to root. An image that has no sudo uses `setpriv` too, whatever the setting.

The setting `MACHINE_RUNNER_SWARM_JOB_SUDO` chooses between the default and the hardened class. It is not the prefix itself. Refer to [Users and the runner token on Linux](concepts.md#users-and-the-runner-token-on-linux).

## Should I use the setup helper or the manual steps?

Both give the same result. The manual steps are about 18 commands, and the helper runs the common ones in 3 invocations. The helper is optional, and every step of it is on the install pages.

| | `setup.sh` or `Setup.ps1` does | It does not |
|---|---|---|
| Linux | Checks the node, creates a single-node Swarm on the loopback address, downloads and verifies the runner, installs it with the entrypoint, creates secrets from hidden prompts, and deploys the stack files you name | Install Docker, create resource classes or tokens, edit or copy the stack file, label or join nodes, build images, or run `--install` on the other nodes |
| Windows | Stages the runner and Git with the access rights and the `current` junction, creates the Swarm, labels the node with the image tags it can run, creates secrets, and deploys | Install Docker or Windows features, create classes or tokens, edit or copy the stack file, add the labels of the optional classes, join other nodes, or build images |

The steps run in a fixed order, and a rerun is safe. The helpers pin a runner version and its checksum, and do not look up the latest. Refer to [Optional: use the setup helper](install-linux.md#optional-use-the-setup-helper) and [the Windows helper](install-windows.md#optional-use-the-setup-helper).

## Why Swarm and not container runner or another runner?

Choose by what you already run and by the isolation that you need.

| You have or need | Use | Why |
|---|---|---|
| Kubernetes, and jobs that fit a `docker:` executor | [Container runner](https://circleci.com/docs/guides/execution-runner/container-runner-installation/) | CircleCI documents it, it scales pods, and it uses convenience images. Choose it when you have Kubernetes |
| A boundary stronger than a container, privileged or KVM jobs, a full OS, or autoscaling | [Machine runner orchestrator](https://circleci.com/docs/guides/execution-runner/machine-runner-orchestrator/) | A virtual machine for each job on Kubernetes with KubeVirt, and the token stays out of the VM. Refer to [Compared with the official runner installs](security.md#compared-with-the-official-runner-installs) |
| One host or a few, jobs that need the whole machine, or no containers at all | [Machine runner 3 on a host](https://circleci.com/docs/guides/execution-runner/runner-overview/#choosing-a-runner-execution-environment) | The simplest setup. Jobs share the host, and nothing separates one job from the next |
| The same, but in a container | [Machine runner 3 on Docker](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-docker/) | It runs the runner with `docker run`. The container is reused for more jobs until you stop it, so the environment is not clean |
| Docker hosts or Windows containers, no Kubernetes, and a clean container for every job | This repository | Swarm creates a new container for every job, and adds replicas, placement, secrets, and rolling updates. It has no support from CircleCI and no autoscaling, and the containers share the host kernel |

Swarm mode is part of Docker Engine, and the stack files use only its core features: services, secrets, constraints, and rolling updates. To move to the orchestrator or to a plain machine runner later, keep the resource class names, and the jobs with `machine: true` stay as they are. Container runner needs the jobs to change to a `docker:` executor. CircleCI lists its own options in the [runner overview](https://circleci.com/docs/guides/execution-runner/runner-overview/).

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

## Does it support macOS?

No. Docker has no macOS containers, so Swarm cannot schedule macOS jobs. Apple's licence also limits macOS to Apple hardware, so running macOS in a container on other hardware is not an option. CircleCI documents how to run machine runner 3 directly on a Mac, and CircleCI offers hosted macOS executors.

## Which operating systems does it support?

| Platform | Status |
|---|---|
| Linux, Ubuntu LTS, amd64 | Tested in CI, including real jobs |
| Linux, Ubuntu LTS, arm64 | CI tests the install and the start of the stack. It runs real jobs on amd64 only |
| Linux, RHEL 8 and later | Steps documented, not tested in CI |
| Windows Server 2025 and 2022 | Tested in CI |
| Windows Server 2019 | Supported by machine runner 3. Untested here, and the stack files have no label for it |
| Windows Server 2016 and older | Not compatible with machine runner 3 |
| macOS | Out of scope |

## Which CircleCI plans and platforms work?

The stack is tested against CircleCI cloud. It does not set `CIRCLECI_RUNNER_API_URL`, which CircleCI server needs. CircleCI server is not tested. Config policies, which restrict classes to projects, need the Scale plan on cloud.

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

## Is there a delay between jobs?

A replica needs about 10 seconds for the restart delay, plus the start-up time of the container and the download of the task agent, before it claims the next job. Other replicas of the class keep working during that time. Refer to [Job lifecycle](concepts.md#job-lifecycle).

## Do I need to open inbound ports?

No. Runners connect outbound over HTTPS, and the stack publishes no ports. Multi-node clusters need the Swarm ports between the nodes. Refer to [Inter-node ports](multi-node.md#inter-node-ports).

## Can I run a long-lived runner with warm caches?

Yes, with a persistent class. It gives up the clean environment, so use it only for trusted projects. Refer to [Persistent mode](resource-classes.md#persistent-mode).

## Can a job read the runner token?

In the default Linux class, a job that uses sudo can. In the hardened class, it cannot. On Windows, a job can, and Swarm also stores the secret in clear text on the container disk, so use BitLocker and one token for each class and host. Refer to [Token model on each OS](security.md#token-model-on-each-os) and to the [comparison with the official installs](security.md#compared-with-the-official-runner-installs). A holder of a token can run a rogue runner on that class and claim its jobs, so rotate tokens ([how](operations.md#rotate-a-runner-token)).

## Why does a Windows job end when I update or stop a service?

Stopping a busy stock Server Core container from outside kills its job after about 5 seconds, whatever `stop_grace_period` says, and a finished job ends its container cleanly. Roll out changes while the class is idle, or rerun the interrupted jobs. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

## Does the setup helper install the latest runner?

No. `linux/setup.sh` and `windows\Setup.ps1` install a pinned version and verify its SHA-256 checksum. Pass the version you want with `--version` and `--sha256` on Linux, or with `-RunnerVersion` on Windows, where the checksum comes from the release manifest.

## How do I verify a release?

Each release has a `SHA256SUMS` file and a keyless cosign signature that was made with the CircleCI OIDC token. Refer to [Verify a release](install-linux.md#verify-a-release), or [Verify a release](install-windows.md#verify-a-release) on Windows.

## Can a fork pull request use these runners?

No. CircleCI does not make self-hosted runners available to a public project that has **Build forked pull requests** enabled, because untrusted code on your machines is a significant risk. Keep that setting off for any project that uses these classes. For a private project, a collaborator's branch runs your code on the node, so restrict each class to the projects that need it. Refer to [CircleCI-side controls](security.md#circleci-side-controls).

## Which jobs cannot run here?

The jobs run in unprivileged containers on a shared kernel, so some jobs belong on another runner.

| Job needs | Here | Use instead |
|---|---|---|
| A privileged container, `/dev/kvm`, or other host devices | No. Swarm ignores `privileged` and `devices` | The machine runner orchestrator, or a machine runner on a host |
| Docker-in-Docker | No, because it needs a privileged container | The opt-in [docker-build class](docker-builds.md), or a daemonless builder |
| `setup_remote_docker` | No. It belongs to the Docker executor | The docker-build class, or a daemonless builder |
| Docker commands in a job | Only in the docker-build class, which is root-equivalent on its node | [Docker Builds](docker-builds.md) |
| A GPU | Not supported or tested. The stack files declare no generic resources | A machine runner on a GPU host |
| Service containers (`docker:` secondary images) | No. Jobs use `machine: true` | Install the service in the image, or use container runner |
| Desktop or UI automation on Windows | No. Windows jobs are headless | A machine runner on a host |
| A `docker:` executor job | No. Jobs use `machine: true`, and the image of the service is the environment of the job | Container runner |

## Do proxies and custom certificate authorities work?

The stack sets nothing for them, and this repository does not test them.

- **Proxy.** Set `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` under `environment` of the service. The runner is a Go program that reads them, and jobs inherit them. Test a checkout through the proxy before you roll out a class. Refer to [Egress hosts](security.md#egress-hosts).
- **Certificate authority.** Add your CA to a custom image and run `update-ca-certificates`, or mount a CA bundle read-only and point `SSL_CERT_FILE` at it. Windows images need the CA in the image too. Refer to [Images](images.md).

## Does it work on hosts without internet access?

Not without a route to CircleCI. Every runner needs outbound HTTPS to `runner.circleci.com`, and every new container downloads the task agent from `circleci-binary-releases.s3.amazonaws.com`. A host that reaches those names through an allow list or a proxy works. The variable `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` points only the `setup.sh` download of the runner at an HTTPS mirror, so it does not replace the task agent download. Pull the images from a registry that the nodes can reach. Refer to [Registry needs](multi-node.md#registry-needs).

## Does it work with rootless Docker, user namespaces, or Podman?

- **Podman** cannot run Swarm, so it cannot run this stack.
- **Rootless Docker** and **`userns-remap`** are not tested. The stack assumes a root daemon: the entrypoint checks that the mounted runner directory belongs to root, and the secret belongs to uid 2000. With a remap, root-owned host files appear under another owner, and the entrypoint is likely to exit with code 80. Swarm also ignores `userns_mode` in stack files.

## Does it work with SELinux on RHEL?

The RHEL steps are documented and not tested in CI. Keep SELinux enforcing, and label `/opt/machine-runner-swarm` for containers if it denies access. Refer to [Permission denied on /opt/machine-runner-swarm with SELinux](troubleshooting.md#permission-denied-on-optmachine-runner-swarm-with-selinux).

## What happens to a job when a node dies?

The job is lost. CircleCI reports it as failed because of an infrastructure problem, and self-hosted runners do not retry a job automatically, so rerun it. Swarm detects the lost node, and starts replacement runners on other nodes that match the constraints, which restores the capacity. A single manager that dies stops all replacements, and the quorum rules of [Managers and quorum](multi-node.md#managers-and-quorum) apply. Refer to [Node death](operations.md#node-death).

## How do I report a bug or a vulnerability?

Open a [GitHub issue](https://github.com/CircleCI-Labs/scalable-machine-runner/issues) for a bug. For a vulnerability, email [security@circleci.com](mailto:security@circleci.com). Refer to [SECURITY.md](../SECURITY.md).
