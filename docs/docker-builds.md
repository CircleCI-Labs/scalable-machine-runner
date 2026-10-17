---
page-title: Docker builds
page-audience: admin
page-description: Build container images from jobs with an opt-in service that mounts the host Docker engine, and compare the rootless and daemonless alternatives.
---

# Docker builds

By default, jobs on these runners cannot reach a Docker engine, because access to a Docker daemon is root access to the machine. Docker builds are opt-in, one dedicated class at a time.

## Choose a pattern

| Pattern | Jobs get | Root-equivalent on the node | Status | Platform |
|---|---|---|---|---|
| A: host engine socket | The full Docker API of the node | Yes | Built, with a stack file and an example | Linux, and Windows images on Windows |
| B: rootless BuildKit on the host | Only a build API, through the socket of one BuildKit daemon | No, but the daemon runs on the host | Documented, not built | Linux |
| C: daemonless builder in the job | Nothing from the host | No | Documented, not built | Linux |
| D: Docker daemon inside a microVM | Its own daemon, in the VM of the job | No, but the job has `SYS_ADMIN` inside a VM | Built and tested with a fake API, in the [microVM add-on](microvm.md#run-docker-inside-the-vm) | Linux with KVM |

CircleCI lists Docker layer caching among the features that self-hosted runners do not support. Pattern A reuses the layer cache of the host engine, which every job on that node shares.

## Pattern A: the host Docker engine

A service of this class bind-mounts the engine endpoint of the node: `/var/run/docker.sock` on Linux, and the named pipe `\\.\pipe\docker_engine` on Windows.

> [!CAUTION]
> The engine endpoint is root-equivalent on its node (administrator-equivalent on Windows). A job that can use it can start a privileged container, mount any host path, and read the data of other jobs and containers. Use pattern A only for trusted projects, on a dedicated node.

Four controls limit the damage:

- **Worker nodes only.** The service runs only where `node.role == worker`. On a manager the socket also controls the Swarm, so a job could read the token of every class. A single-node Swarm has only a manager, so do not use pattern A there.
- **Labeled nodes only.** The service runs only on nodes with `machine-runner-swarm.docker-build=true`. Every other service carries `!= true`, so labeling a node moves the other classes off it.
- **No neighbors.** The engine shows every container on the node. Refer to [Keep the docker-build node to itself](multi-node.md#keep-the-docker-build-node-to-itself).
- **Trusted projects only.** Restrict the class with a config policy, and keep production contexts away from it ([CircleCI-side controls](security.md#circleci-side-controls)).

State persists: the images, containers, volumes, and build cache of the host engine outlive the job, and nothing else prunes this engine. Remove what a job creates in a final step, and schedule `docker builder prune` and `docker image prune` on the node ([Free disk space](operations.md#free-disk-space)). Never run `docker volume prune` there: the node also holds the volume `runner-bin`.

### Deploy on Linux

1. Join a dedicated worker node ([Multi-node clusters](multi-node.md)). Nothing is installed on it: `runner-distributor` installs the runner there.
2. Label the node:

   ```bash
   docker node update --label-add machine-runner-swarm.docker-build=true <WORKER_NODE>
   ```

3. Create the resource class `<NAMESPACE>/linux-docker-build` and the secret `linux-docker-build-token` ([Resource classes](resource-classes.md#define-a-class)).
4. Deploy the add-on stack file with the main file. Pass the same list of files on every later deploy ([why](concepts.md#add-on-stack-files-and-how-they-merge)).

   ```bash
   docker stack deploy -c linux/stack/runners.yaml -c linux/stack/docker-build.yaml runners
   ```

`linux/stack/docker-build.yaml` defines `linux-docker-build`. It mounts the socket and adds the job user to the group of the socket, so jobs need no sudo to run `docker`. The runner volume stays read-only, but a job that controls the engine can change `runner-bin` of its node, which only this class uses there. The `cimg/base` image includes the Docker CLI.

```yaml
jobs:
  image:
    machine: true
    resource_class: <NAMESPACE>/linux-docker-build
    steps:
      - checkout
      - run: docker build -t "app:${CIRCLE_SHA1:0:12}" .
      - run:
          name: Clean up, the engine outlives the job
          when: always
          command: docker image rm -f "app:${CIRCLE_SHA1:0:12}" || true
```

The file [`examples/linux-docker-build.yml`](../examples/linux-docker-build.yml) has the full job.

### Deploy on Windows

`windows\stack\docker-build.yaml` defines `windows-docker-build`. It mounts the named pipe `\\.\pipe\docker_engine` and the host directory `C:\Program Files\Docker` read-only at `C:\docker`, which it appends to the `PATH`. Adjust the bind source if `docker.exe` lives elsewhere. It runs on a worker only, as on Linux, so it needs a Windows worker in the Swarm ([Multi-node clusters](multi-node.md)). The single-node Swarm of the Windows quickstart has only a manager, and the class stays `Pending` there.

1. Label the worker node:

   ```powershell
   docker node update --label-add machine-runner-swarm.docker-build=true <NODE_NAME>
   ```

2. Create the resource class `<NAMESPACE>/windows-docker-build` and the secret `windows-docker-build-token`.
3. Deploy the add-on stack file with the main file. Pass the same list of files on every later deploy ([why](concepts.md#add-on-stack-files-and-how-they-merge)).

   ```powershell
   docker stack deploy -c windows\stack\runners.yaml -c windows\stack\docker-build.yaml runners
   ```

Jobs can build Windows images only, because the engine runs in Windows-container mode. The file [`examples/windows-docker-build.yml`](../examples/windows-docker-build.yml) has a job. Keep registry credentials for `docker login` and `docker push` in a restricted context.

## Pattern B: rootless BuildKit on the host

Run a rootless BuildKit daemon on the host under a dedicated unprivileged account, and mount only its socket into a runner service. Jobs send builds to it with a BuildKit client. The daemon exposes the build API, not the Docker API, so a job cannot start arbitrary containers or mount host paths. The risk shrinks but stays: the daemon shares the host kernel, and every job shares its build cache. This repository has no stack file, helper, or test for it.

## Pattern C: a daemonless builder in the job

Run a daemonless builder inside the job container, such as a maintained fork of Kaniko or Buildah. Nothing of the host is exposed. These builders have their own privilege needs: rootless Buildah relies on user namespaces, and Kaniko expects to run as root inside its container. Swarm ignores `security_opt` and `privileged` in a stack file, so test your builder in a class that matches your policy first. This repository has no stack file or test for it.

## What to avoid

- Mounting the Docker socket into any class that is not dedicated to builds.
- Starting a privileged Docker-in-Docker container from a job. Swarm ignores `privileged`, and it is root-equivalent where it works.
- Running pattern A on a manager, or on a node that also runs production workloads.
