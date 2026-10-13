# Security policy

## Reporting a vulnerability

**Do not open a public issue or pull request for a security vulnerability.**

To report a vulnerability in this repository, in the CircleCI platform, or in the CircleCI runner agent itself, email [security@circleci.com](mailto:security@circleci.com). You can also follow the process at <https://circleci.com/security/>. CircleCI does not have a bounty program.

For a sensitive report, encrypt the message with the key at <https://circleci.com/.well-known/pgp-key.txt>.

Include the steps to reproduce, the version of this repository, the runner version, and the operating system of the node.

## Supported versions

This repository is at version `0.x`. Fixes land on `main` and ship in the next release. Only the latest `0.x` release receives fixes.

## Support status of this repository

This repository is part of CircleCI Labs. CircleCI support does not cover it. Field engineering handles bugs and feature requests on a best-effort basis, without an SLA. Use [GitHub issues](https://github.com/CircleCI-Labs/scalable-machine-runner/issues) for problems that are not security vulnerabilities.

## What this stack does with your credentials

- The resource class token is stored as a Swarm secret and mounted into the container as a file, which is a minimal runner config file. The stack never puts the token in an environment variable or in a stack file.
- On Linux, a job in the default class has passwordless sudo, so a job that uses sudo can read the token. The hardened class removes sudo, and the token is then unreadable from jobs.
- On Windows, jobs run as the same account as the runner, so a job can read the token file. Swarm also stores the secret in clear text on the disk of the container until the container stops, unlike Linux, which keeps it in memory. Enable BitLocker, and treat every Windows resource class as a trust boundary.
- A job that can reach the Docker engine has root on that node. Docker builds are opt-in and limited to worker nodes labeled `machine-runner-swarm.docker-build=true`.

[Security](docs/security.md) describes the threat model and the controls in detail.

## Fork pull requests and CI

Do not use self-hosted runners for public projects that build forked pull requests. A malicious pull request can run code on your runner. The settings of this repository keep fork builds away from secrets and from self-hosted runners.
