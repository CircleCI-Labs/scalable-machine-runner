# Security policy

## Reporting a vulnerability

**Do not open a public issue or pull request for a security vulnerability.**

Email [security@circleci.com](mailto:security@circleci.com), whether the problem is in machine runner swarm, the CircleCI platform or the CircleCI runner agent. CircleCI's security team receives the report. The project sets no response target, and CircleCI has no bounty program ([process](https://circleci.com/security/)).

For a sensitive report, encrypt the message with the key at <https://circleci.com/.well-known/pgp-key.txt>.

Include the steps to reproduce, the release or commit, the runner version, and the operating system of the node.

## Supported versions

Machine runner swarm is at version `0.x`. Only the latest `0.x` release receives fixes. Fixes land on `main` and ship in the next release. The code and the design have not been independently reviewed or penetration-tested.

## Support

Machine runner swarm is a CircleCI Labs project. CircleCI support does not cover it, and field engineers handle bugs and feature requests on a best-effort basis, with no SLA. Use [GitHub issues](https://github.com/CircleCI-Labs/machine-runner-swarm/issues) for problems that are not security vulnerabilities.

## What this stack does with your credentials

[Security](docs/security.md) describes the threat model and the controls in detail.

- The resource class token is a Swarm secret, a minimal runner config file. No environment variable or stack file holds a token.
- On Linux, the single-task classes do not hold their token. The `token-proxy` service holds it and adds it to the task claims of that class, once for each container. The runner containers hold a placeholder, so a job cannot read the class token, with or without sudo. In a cluster, label the node of the proxy `machine-runner-swarm.proxy=true`: runner services never run there, so a job that escapes its container cannot reach the tokens.
- On Linux, the persistent class keeps its token as a file in its container, because a continuous runner claims many times. A job in it that uses sudo can read the token. Keep that class for trusted projects.
- On Windows, the single-task classes work the same way: the class token is in the `token-proxy-windows` service, and the runner container holds only a placeholder. A job runs as an administrator and can read the placeholder. It can also forge a source address, because Windows cannot drop `NET_RAW` and the proxy tells the runners of a class apart by source address. That gains a job little, and no test covers it on Windows. The persistent class holds the real token, and every job in it can read it. Swarm keeps a Windows secret in clear text on disk until the container stops. Enable BitLocker, and treat every Windows resource class as a trust boundary.
- A job that can reach the Docker engine has root on that node. Docker builds are opt-in and limited to worker nodes labeled `machine-runner-swarm.docker-build=true`, and every other service stays off those nodes (`node.labels.machine-runner-swarm.docker-build != true`).

## Fork pull requests and CI

Do not use self-hosted runners for public projects that build forked pull requests. A malicious pull request can run code on your runner. The project keeps fork builds away from secrets and self-hosted runners: it uses the GitHub OAuth integration, and **Build forked pull requests** and **Pass secrets to builds from forked pull requests** are off.
