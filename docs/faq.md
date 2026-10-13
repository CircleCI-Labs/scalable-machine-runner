---
page-title: FAQ
page-audience: admin
page-description: Answers to common questions about the Docker Swarm runner stack, including Compose, container runner, macOS, Windows versions, and support.
---

# FAQ

## What is this repository?

It is a set of Docker Swarm stack files, a small Linux entrypoint, optional setup helpers, and documentation. Together they run CircleCI machine runner 3 in containers, with one resource class for each Swarm service and a new container for every job. Refer to [Concepts](concepts.md).

## Does CircleCI support it?

No. This repository is part of CircleCI Labs. CircleCI field engineers created it and real customers use it, but CircleCI support does not cover it. Field engineering handles issues on a best-effort basis. The runner itself, the CircleCI platform, and your resource classes are covered by your normal CircleCI support.

## Why not container runner?

Container runner is the recommended method for containerized jobs, and CircleCI supports it. It needs a Kubernetes cluster. This stack is for teams that do not run Kubernetes, that run Windows jobs, or that already operate Docker hosts. CircleCI lists its own options in the [runner overview](https://circleci.com/docs/guides/execution-runner/runner-overview/). Choose container runner when you have Kubernetes.

## How is this different from machine runner 3 on Docker?

The CircleCI page for [machine runner 3 on Docker](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-docker/) runs a container with `docker run`. That container is reused for more jobs until you stop it, so it does not give a clean environment. This stack runs the runner in single-task mode and lets Swarm create a new container for every job. It adds replicas, placement, secrets, and rolling updates.

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

## Can I use a Docker executor job on these runners?

No. Jobs use `machine: true` with `resource_class: <namespace>/<class>`. The runner runs inside the image of the service, so the image is the environment of the job. Machine runner does not run `docker:` executor jobs.

## Can jobs build Docker images?

Not by default. Docker builds are opt-in, through a dedicated class that mounts the host engine. That class is root-equivalent on its node. Refer to [Docker Builds](docker-builds.md).

## How do I add capacity?

Raise `deploy.replicas` of a service, or add nodes. Refer to [Choose replica counts](resource-classes.md#choose-replica-counts).

## Is there a delay between jobs?

A replica needs about 10 seconds for the restart delay, plus the start-up time of the container and the download of the task agent, before it claims the next job. Other replicas of the class keep working during that time. Refer to [Job lifecycle](concepts.md#job-lifecycle).

## Do I need to open inbound ports?

No. Runners connect outbound over HTTPS, and the stack publishes no ports. Multi-node clusters need the Swarm ports between the nodes. Refer to [Inter-node ports](multi-node.md#inter-node-ports).

## Can I run a long-lived runner with warm caches?

Yes, with a persistent class. It gives up the clean environment, so use it only for trusted projects. Refer to [Persistent mode](resource-classes.md#persistent-mode).

## Can a job read the runner token?

In the default Linux class, a job that uses sudo can. In the hardened class, it cannot. On Windows, a job can, and Swarm also stores the secret in clear text on the container disk. Refer to [Security](security.md#token-model-on-each-os).

## Why does a Windows job end when I update or stop a service?

Stopping a busy stock Server Core container from outside kills its job after about 5 seconds, whatever `stop_grace_period` says. The exit code is 3221225786. The normal flow is not affected: a job that finishes ends the runner and the container cleanly. Only a deploy or update, a scale-down, a drain, `docker stack rm`, and a restart of Docker stop a busy container. Roll out changes while the class is idle, or rerun the interrupted jobs. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

## Does the setup helper install the latest runner?

No. `linux/setup.sh` and `windows\Setup.ps1` install a pinned version and verify its SHA-256 checksum. Pass the version you want with `--version` and `--sha256` on Linux, or with `-RunnerVersion` on Windows, where the checksum comes from the release manifest.

## How do I verify a release?

Each release has a `SHA256SUMS` file and a keyless cosign signature that was made with the CircleCI OIDC token. Refer to [Verify a release](install-linux.md#verify-a-release), or [Verify a release](install-windows.md#verify-a-release) on Windows.

## How do I report a bug or a vulnerability?

Open a [GitHub issue](https://github.com/CircleCI-Labs/scalable-machine-runner/issues) for a bug. For a vulnerability, email [security@circleci.com](mailto:security@circleci.com). Refer to [SECURITY.md](../SECURITY.md).
