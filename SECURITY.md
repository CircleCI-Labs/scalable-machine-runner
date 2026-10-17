# Security policy

## Reporting a vulnerability

**Do not open a public issue or pull request for a security vulnerability.**

To report a vulnerability in this repository, in the CircleCI platform, or in the CircleCI runner agent itself, email [security@circleci.com](mailto:security@circleci.com). You can also follow the process at <https://circleci.com/security/>, which also says that CircleCI has no bounty program. CircleCI's security team receives the report, and this repository sets no response target.

For a sensitive report, encrypt the message with the key at <https://circleci.com/.well-known/pgp-key.txt>.

Include the steps to reproduce, the version of this repository, the runner version, and the operating system of the node.

## Supported versions

This repository is at version `0.x`. Fixes land on `main` and ship in the next release. Only the latest `0.x` release receives fixes. The code and the design have not been independently reviewed or penetration-tested.

## Support status of this repository

This repository is part of CircleCI Labs. CircleCI support does not cover it. Field engineering handles bugs and feature requests on a best-effort basis, without an SLA. Use [GitHub issues](https://github.com/CircleCI-Labs/scalable-machine-runner/issues) for problems that are not security vulnerabilities.

## What this stack does with your credentials

- The resource class token is stored as a Swarm secret, a minimal runner config file. The stack never puts the token in an environment variable or in a stack file.
- On Linux, the single-task classes do not hold their token: the `token-proxy` service holds it and adds it to the task claims of the runners of that class, once for each container. The runner containers hold a made-up placeholder, so a job cannot read the class token, with or without sudo. A job that escapes its container onto the node of the proxy could read the tokens. In a cluster, label the node of the proxy `machine-runner-swarm.proxy=true`: runner services never run on a node with that label.
- On Linux, the persistent class keeps its token as a file in its container, because a continuous runner claims many times. A job in it that uses sudo can read the token. Keep that class for trusted projects.
- On Windows, the single-task classes work as on Linux in this respect: the class token is in the `token-proxy-windows` service, and the runner container holds only a placeholder. A job runs as an administrator, so it can read the placeholder. It can also send packets with a forged source address, because Windows cannot drop `NET_RAW` as Linux does, and the proxy uses the source address to tell the runners of a class apart. What that gains a job is limited, and it is not tested on Windows. The persistent class holds the real token in its container, and every job in it can read the token. Swarm also stores a Windows secret in clear text on the disk of the container until the container stops, unlike Linux, which keeps it in memory. Enable BitLocker, and treat every Windows resource class as a trust boundary.
- A job that can reach the Docker engine has root on that node. Docker builds are opt-in and limited to worker nodes labeled `machine-runner-swarm.docker-build=true`, and every other service of the stack files stays off those nodes (`node.labels.machine-runner-swarm.docker-build != true`).

[Security](docs/security.md) describes the threat model and the controls in detail.

## Fork pull requests and CI

Do not use self-hosted runners for public projects that build forked pull requests. A malicious pull request can run code on your runner. The settings of this repository keep fork builds away from secrets and from self-hosted runners: the project uses the GitHub OAuth integration, and its settings **Build forked pull requests** and **Pass secrets to builds from forked pull requests** are off.
