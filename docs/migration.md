---
page-title: Migrate from Docker Compose
page-audience: admin
page-description: Move from the old docker-compose.yml setup to the Docker Swarm stack, and map each Compose setting to its Swarm equivalent.
---

# Migrate from Docker Compose

> [!WARNING]
> This repository no longer ships the Docker Compose setup. The files `docker-compose.yml`, `base-image/`, `convenience-image/`, and `machine-image/` were removed in the Swarm rewrite, and the change is marked `[BREAKING]` in the [changelog](../CHANGELOG.md). Find the old files in the Git history with `git log -- docker-compose.yml`.

The old setup ran the runner in single-task mode with `restart: unless-stopped` and replicas. A restart reuses the same container, so the old setup did not give a clean environment for every job. The Swarm stack creates a new container for every job. Refer to [Why not plain Docker Compose?](faq.md#why-not-plain-docker-compose)

This page describes how to move an existing setup. It covers Linux hosts, which the old setup supported.

## What changed

| Old setup | Swarm stack |
|---|---|
| Services `base`, `convenience`, and `machine` in `docker-compose.yml` | One service for each resource class in `linux/stack/runners.yaml`. The continuous runner is `linux/stack/persistent.yaml` |
| `restart: unless-stopped`, which restarts the same container | `restart_policy: condition: any`, which creates a new container |
| `deploy.replicas` | `deploy.replicas`, with placement, reservations, and limits |
| Token in a `.env` file as `CIRCLECI_RUNNER_API_AUTH_TOKEN`, visible in `docker inspect` | Swarm secret `<service>-token`, which holds a runner config file |
| The same `CIRCLECI_RUNNER_NAME` for every replica | `{{.Node.Hostname}}-<service>-{{.Task.Slot}}`, unique for each replica |
| Dockerfiles that build the runner into an Ubuntu, `cimg`, or `runner-agent` image | A stock image with the runner mounted from `/opt/smr`. Refer to [Images](images.md) |
| Runner logs written to a mounted file in the `machine` service | Logs on stdout, read with `docker service logs` |
| `CIRCLECI_RUNNER_MODE` and `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` in the service environment | The same variables, in the stack file. Cleanup is `"false"` on Linux |
| Jobs with `resource_class: <namespace>/<class>` | No change |

Your job configs do not change. Your resource classes and tokens can stay.

## Migrate

1. **Decide how to name the classes.** A Swarm service must have the name of its resource class. To keep your resource classes and tokens, name each service after the class that it replaces, for example `base`. To start with new classes, create them as described in [Create the resource classes](install-linux.md#1-create-the-resource-classes).
2. **Prepare the host.** Docker Engine is already there. Install the runner and the entrypoint into `/opt/smr`, and start Swarm. Refer to [Install the runner and the entrypoint](install-linux.md#3-install-the-runner-and-the-entrypoint) and [Start Swarm](install-linux.md#4-start-swarm).
3. **Create the secrets.** Use the token of each class. It is the value of `CIRCLECI_RUNNER_API_AUTH_TOKEN` in your old `.env` file. Create one secret for each service, as in [Create the secrets](install-linux.md#5-create-the-secrets).
4. **Choose the images.** The old `convenience` service maps to `cimg/base`, or to another `cimg` image. The old `base` service maps to a stock image that has the tools you need. If your Dockerfiles installed extra tools, move them into an image that you derive. Refer to [Linux: bring your own image](images.md#linux-bring-your-own-image).
5. **Edit the stack file.** Rename or copy the services, set the replica counts you used before, and keep only the services you need. The old `machine` service becomes `linux/stack/persistent.yaml`. Refer to [Resource Classes](resource-classes.md).
6. **Deploy next to the old setup.** Both can run at the same time, because the new runner names are different. Check that the new runners show up in the inventory.
7. **Stop the old setup.** When the old runners are idle, run `docker compose down` in the old directory. A running job is stopped after the Compose grace period, so wait for a quiet period first.
8. **Clean up.** Delete the old `.env` files, which hold tokens in clear text. If you created new classes, delete the old tokens and classes in CircleCI.

## Behavior to expect

- **Sudo.** The default classes keep passwordless sudo, as the old images did. The hardened class removes it. Refer to [Concepts](concepts.md#users-and-the-runner-token-on-linux).
- **Startup time.** A new container starts for every job, so a job waits about 10 seconds longer than before for the next claim, plus the task agent download. Add replicas for busy classes.
- **Swarm on one host.** Swarm mode is required even on a single host. The shipped helper and the install page start it on the loopback address, so nothing is exposed.
- **Working directory.** The runner no longer removes the working directory on Linux, because it runs as another user than the jobs and cannot delete their files. The container is new for every job, so nothing stays. The old `machine` service becomes a persistent class, which keeps files between jobs, so start its jobs with a cleanup step. Refer to [Working directory cleanup](security.md#working-directory-cleanup).
