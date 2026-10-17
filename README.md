# Machine runner swarm: CircleCI machine runner 3 on Docker Swarm

Self-hosted CircleCI runners that give every job a clean container, on the Docker hosts you already run. Linux and Windows Server, no Kubernetes.

[![CircleCI](https://dl.circleci.com/status-badge/img/gh/CircleCI-Labs/machine-runner-swarm/tree/main.svg?style=shield)](https://dl.circleci.com/status-badge/redirect/gh/CircleCI-Labs/machine-runner-swarm/tree/main)
[![Release](https://img.shields.io/github/v/release/CircleCI-Labs/machine-runner-swarm?include_prereleases&label=release)](https://github.com/CircleCI-Labs/machine-runner-swarm/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/)

## Why use it

- **A clean container for every job.** Each Swarm service is one resource class. A runner claims one job and exits, and Swarm starts a new container, so no job inherits files from the last one.
- **VM-grade isolation when you need it.** Kata Containers microVM classes run each job in its own microVM, on Swarm (experimental).
- **Linux and Windows in one cluster.** Linux amd64 and arm64, and Windows Server 2022 and 2025, with labels that decide where each class runs.
- **Jobs never see the class token.** A token proxy holds it, and the runners hold a placeholder (the persistent classes are the exception).
- **No runner install on your hosts.** A distributor service installs the runner on every node, pins a tested version and checks its SHA-256. An update changes one service and interrupts no job on Linux.
- **Scale by setting replicas.** `deploy.replicas` is the number of concurrent jobs of a class.
- **Signed releases.** Each release bundle carries a keyless cosign signature, and the token proxy image is pinned by digest.

## Who it is for

Teams that run Docker hosts or Windows Server and want something as simple as Docker Compose, without Kubernetes. `docker stack deploy` is the whole install. It sits between a single machine runner (jobs share a host) and a Kubernetes container runner.

Use something else when:

- You need no machines of your own: use CircleCI cloud executors.
- You run Kubernetes: use [container runner](https://circleci.com/docs/guides/execution-runner/container-runner-installation/).
- You need autoscaling, privileged or KVM jobs, or a full VM per job today: use the [machine runner orchestrator](https://circleci.com/docs/guides/execution-runner/machine-runner-orchestrator/).
- You need CircleCI server, macOS, or hosts with no internet access: this project does not cover them.

The [FAQ](docs/faq.md#why-swarm-and-not-container-runner-or-another-runner) has the full comparison.

## Quickstart

You need the [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, a node with Docker Engine (24 or later on Linux, 28.0 or later on Windows), and an organization admin who accepted the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/).

1. Create a resource class and a token with the CircleCI CLI.
2. Download the release, start Swarm, create the secrets, and deploy the stack.
3. Run a sample job twice, and see a new container each time.

Follow [Quickstart on Linux](docs/quickstart-linux.md) or [Quickstart on Windows Server](docs/quickstart-windows.md).

## Documentation

**Read the docs for everything else: [circleci-labs.github.io/machine-runner-swarm](https://circleci-labs.github.io/machine-runner-swarm/).**

The site follows `main`. The `docs/` folder of a release bundle is the documentation of that release. Start with [Concepts](docs/concepts.md), then [Install on Linux](docs/install-linux.md) or [on Windows Server](docs/install-windows.md), [Multi-Node Clusters](docs/multi-node.md), [Resource Classes](docs/resource-classes.md), [Security](docs/security.md), [Operations](docs/operations.md), and the [FAQ](docs/faq.md). [Examples](examples) has a job config for every class.

## What is tested

The project is pre-release `0.x`: a minor release can change stack files, so read the [release notes](https://github.com/CircleCI-Labs/machine-runner-swarm/releases) before you upgrade. [CI/CD](docs/ci.md#what-is-tested) lists every test and every gap. A statement in these pages that the table does not support is an overclaim, so please report it.

| What | Status | How it is checked |
|---|---|---|
| Linux amd64 (Ubuntu), one node: install, token proxy, clean container per job, default and hardened class | Tested | Real CircleCI jobs on a fresh VM |
| Windows Server 2022 and 2025, one host, amd64 | Tested | Real CircleCI jobs on real Windows hosts |
| Linux arm64 | Partly tested | The stack starts on every pipeline. Three probe jobs run on a real arm64 runner on `main` |
| Mixed cluster of a Linux manager and a Windows worker | Verified by hand | Real jobs ran once, on 2026-10-16. CI cannot run it |
| Multi-node clusters, day-two operations (drain, rolling update, token rotation, manager loss) | Documented, not tested | CI runs two Swarm nodes as containers on one VM |
| RHEL 8 or later | Documented, not tested | The steps follow Docker's documentation |
| ppc64le and s390x | Emulated start only | No job runs |
| CircleCI server, hosts without internet, proxies, private certificate authorities | Not tested | CircleCI cloud only |
| MicroVM classes (Kata Containers) | Experimental | A fake CircleCI API on nested KVM. One real job ran by hand |
| Container mode, docker-build, persistent, and Rerun job with SSH classes | Experimental | Config and contract checks. No real job in CI |
| Windows Server 2019, Hyper-V isolation, `add_ssh_keys` | Not tested | Not exercised |

Known limits: capacity is fixed (no autoscaling, no node creation), one token proxy runs on a manager (not high availability, use three managers in production), and containers share the host kernel. The [FAQ](docs/faq.md#what-is-not-in-this-release) lists what is not in this release.

## Support

This is a CircleCI Labs project: a solution that field engineers at CircleCI built with customers. It is **not** an official CircleCI product, and CircleCI support does not cover it. Field engineering handles issues on a best-effort basis, without an SLA.

- Open a [GitHub issue](https://github.com/CircleCI-Labs/machine-runner-swarm/issues) for a bug or a feature request. Search [Troubleshooting](docs/troubleshooting.md) first, and include the output of [Collect information for a bug report](docs/troubleshooting.md#collect-information-for-a-bug-report).
- Ask the community on [CircleCI Discuss](https://discuss.circleci.com/).
- Problems with the CircleCI platform or the runner agent go to [CircleCI support](https://support.circleci.com/hc/en-us).
- To report a security vulnerability, read [SECURITY.md](SECURITY.md).

## License

MIT. Refer to [LICENSE](./LICENSE).
