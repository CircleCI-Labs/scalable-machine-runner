---
name: Bug report
about: Report something that does not work as documented
labels: bug
---

> Do not report a security vulnerability here. Read SECURITY.md in the root of the repository.
> Remove tokens, runner config files, and internal host names from every log and file you paste.

## What happened

Describe the problem and what you expected instead.

## Steps to reproduce

1.
2.
3.

## Environment

- Release or commit of this repository:
- Runner version (the log of `runner-distributor`: `docker service logs runners_runner-distributor`):
- Node operating system and architecture:
- Docker Engine version (`docker version`):
- Swarm layout (single node, or number of managers and workers):
- Service and resource class involved:
- Image:

## Logs

Paste the output of `docker service ps --no-trunc runners_<service>` and `docker service logs --tail 100 runners_<service>`.
