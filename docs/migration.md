---
page-title: Migrate from Docker Compose
page-audience: admin
page-description: Move from the old docker-compose.yml setup to the Docker Swarm stack, and map each Compose setting to its Swarm equivalent.
---

# Migrate from Docker Compose

> [!WARNING]
> This repository no longer ships the Docker Compose setup. The files `docker-compose.yml`, `base-image/`, `convenience-image/`, and `machine-image/` were removed in the Swarm rewrite, and the change is marked `[BREAKING]` in the [changelog](../CHANGELOG.md). Find the old files with `git log -- docker-compose.yml`.

The old setup restarted the same container after each job, so jobs did not get a clean environment. The Swarm stack creates a new container for every job ([Why not plain Docker Compose?](faq.md#why-not-plain-docker-compose)). This page covers Linux hosts, which the old setup supported. Your job configs, resource classes and tokens can stay.

## What changed

| Old setup | Swarm stack |
|---|---|
| Services `base`, `convenience`, and `machine` in `docker-compose.yml` | One service for each resource class in `linux/stack/runners.yaml`. The continuous runner is `linux/stack/persistent.yaml` |
| `restart: unless-stopped`, which restarts the same container | `restart_policy: condition: any`, which creates a new container |
| Token in a `.env` file as `CIRCLECI_RUNNER_API_AUTH_TOKEN`, visible in `docker inspect` | Swarm secret `<SERVICE>-token`, which holds a runner config file |
| The same `CIRCLECI_RUNNER_NAME` for every replica | `{{.Node.Hostname}}-<SERVICE>-{{.Task.Slot}}`, unique for each replica |
| Dockerfiles that build the runner into an image | A stock image, with the runner mounted from the volume `runner-bin` ([Images](images.md)) |
| `CIRCLECI_RUNNER_MODE` and `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` in the service environment | The same variables, in the stack file. Cleanup is `"false"` on Linux |

## Migrate

1. **Name the classes.** A Swarm service must have the name of its resource class. To keep your classes and tokens, name each service after the class it replaces, for example `base`. For new classes, [create them](install-linux.md#1-create-the-resource-classes).
2. **Prepare the host.** Docker Engine is already there. Start Swarm and install nothing else: the `runner-distributor` service installs the runner on every node ([Start Swarm](install-linux.md#3-start-swarm)).
3. **Create the secrets.** Use the token of each class, the value of `CIRCLECI_RUNNER_API_AUTH_TOKEN` in your old `.env` file ([Create the secrets](install-linux.md#4-create-the-secrets)).
4. **Choose the images.** The old `convenience` service maps to `cimg/base` or another `cimg` image, and `base` to a stock image with your tools. Move extra tools from your Dockerfiles into a derived image ([Linux: bring your own image](images.md#linux-bring-your-own-image)).
5. **Edit the stack file.** Rename or copy the services, set your old replica counts, and keep only what you need. The old `machine` service becomes `linux/stack/persistent.yaml` ([Resource classes](resource-classes.md)).
6. **Deploy next to the old setup.** Both can run at once, because the runner names differ. Check that the new runners show up in the inventory. If a new service keeps a class whose old runners are busy, the token proxy sees running tasks at its first start, cannot tell whose they are, and refuses the present runners until their idle timeout, or until you run the command below once the old runners are idle. New classes avoid this ([Restart the proxy](operations.md#restart-the-proxy)).

   ```bash
   docker service update --force --update-parallelism 0 runners_<SERVICE>
   ```

7. **Stop the old setup.** When the old runners are idle, run `docker compose down` in the old directory. A running job is stopped after the Compose grace period, so wait for a quiet period.
8. **Clean up.** Delete the old `.env` files, which hold tokens in clear text. If you created new classes, delete the old tokens and classes in CircleCI.

## Behavior to expect

- **Runner updates.** The runner is an exact pin by default: the newest version this repository's CI tests, bumped by each release of this repository. Set `3.1`, `3` or `current` to follow CircleCI's manifest ([Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux)).
- **Sudo.** The default classes keep passwordless sudo, as the old images did. The hardened class removes it ([Concepts](concepts.md#users-and-the-runner-token-on-linux)).
- **Fixed replicas.** The stack does not scale by itself, and a node that dies is not replaced ([Capacity and concurrency](operations.md#capacity-and-concurrency)).
- **Startup time.** A new container starts for every job, so a job waits about 10 seconds longer for the next claim, plus the task agent download. Add replicas for busy classes.
- **Swarm on one host.** Swarm mode is required even on a single host. The helper and the install page start it on the loopback address, so nothing is exposed.
- **Working directory.** The runner no longer removes the working directory on Linux, because it runs as another user than the jobs. A new container for every job leaves nothing behind, but a persistent class (the old `machine` service) keeps files between jobs, so start its jobs with a cleanup step ([Working directory cleanup](security.md#working-directory-cleanup)).
