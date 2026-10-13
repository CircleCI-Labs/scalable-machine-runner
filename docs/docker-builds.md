---
page-title: Docker builds
page-audience: admin
page-description: Build container images from jobs with an opt-in service that mounts the host Docker engine, and compare the rootless and daemonless alternatives.
---

# Docker builds

By default, jobs on these runners cannot reach a Docker engine. Access to a Docker daemon is equivalent to root access to the machine, so this repository makes Docker builds opt-in, one dedicated class at a time.

This page describes pattern A, which is built and tested, and patterns B and C, which are documented alternatives.

## Choose a pattern

| Pattern | Jobs get | Root-equivalent on the node | Status | Platform |
|---|---|---|---|---|
| A: host engine socket | The full Docker API of the node | Yes | Built, with a stack file and an example | Linux, and Windows images on Windows |
| B: rootless BuildKit on the host | Only a build API, through the socket of one BuildKit daemon | No, but the daemon runs on the host | Documented, not built | Linux |
| C: daemonless builder in the job | Nothing from the host | No | Documented, not built | Linux |

CircleCI lists Docker layer caching among the features that self-hosted runners do not support. Pattern A reuses the layer cache of the host engine, which every job on that node shares.

## Pattern A: the host Docker engine

A service of this class bind-mounts the engine endpoint of the node: `/var/run/docker.sock` on Linux, and the named pipe `\\.\pipe\docker_engine` on Windows.

> [!CAUTION]
> The engine endpoint is root-equivalent on its node, and administrator-equivalent on Windows. A job that can use it can start a privileged container, mount any host path, and read the data of other jobs and containers. Use pattern A only for trusted projects, on a dedicated node.

Four controls limit the damage:

- **Worker nodes only.** The service runs only where `node.role == worker`. On a Swarm manager the socket also controls the Swarm, so a job can create a service that mounts any secret and read the token of every class. A single-node Swarm has only a manager, so do not use pattern A there.
- **Labeled nodes only.** The service runs only on nodes that carry `machine-runner-swarm.docker-build=true`.
- **No neighbors.** The engine shows every container on the node. Keep other classes off the node. Refer to [Keep the docker-build node to itself](multi-node.md#keep-the-docker-build-node-to-itself).
- **Trusted projects only.** Restrict the class with a config policy, and keep production contexts away from it. Refer to [CircleCI-side controls](security.md#circleci-side-controls).

State also persists. The images, containers, volumes, and build cache of the host engine outlive the job, so the environment is not clean. Remove what a job creates in a final step.

### Deploy on Linux

1. Join a dedicated worker node and install `/opt/machine-runner-swarm/current` on it. Refer to [Multi-Node Clusters](multi-node.md).
2. Label the node:

   ```console
   $ docker node update --label-add machine-runner-swarm.docker-build=true <worker node>
   ```

3. Create the resource class `<namespace>/linux-docker-build` and the secret `linux-docker-build-token`. Refer to [Resource Classes](resource-classes.md#define-a-class).
4. Deploy the add-on stack file with the main file. Pass the same list of files on every later deploy ([why](concepts.md#add-on-stack-files-and-how-they-merge)).

   ```console
   $ docker stack deploy -c linux/stack/runners.yaml -c linux/stack/docker-build.yaml runners
   ```

The file `linux/stack/docker-build.yaml` defines `linux-docker-build`. It mounts the socket, and constrains the service to `node.platform.os == linux`, `node.role == worker`, and `node.labels.machine-runner-swarm.docker-build == true`. Every other service in the stack files carries `node.labels.machine-runner-swarm.docker-build != true`, so labeling a node moves the other classes off it. The entrypoint adds the job user to the group of the socket, so jobs need no sudo to run `docker`. The `cimg/base` image includes the Docker CLI.

Use the class in a job:

```yaml
jobs:
  image:
    machine: true
    resource_class: <namespace>/linux-docker-build
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

The add-on stack file `windows\stack\docker-build.yaml` defines `windows-docker-build`. It mounts the named pipe `\\.\pipe\docker_engine`, which `docker stack deploy` supports, and the host directory `C:\Program Files\Docker` at `C:\docker`, read-only. It appends `C:\docker` to the `PATH`. Adjust the bind source if `docker.exe` lives elsewhere on your nodes.

1. Label the node: `docker node update --label-add machine-runner-swarm.docker-build=true <node name>`.
2. Create the resource class `<namespace>/windows-docker-build` and the secret `windows-docker-build-token`.
3. Deploy the add-on stack file with the main file. Pass the same list of files on every later deploy ([why](concepts.md#add-on-stack-files-and-how-they-merge)).

   ```powershell
   docker stack deploy -c windows\stack\runners.yaml -c windows\stack\docker-build.yaml runners
   ```

Jobs can build Windows images only, because the engine runs in Windows-container mode. Linux images cannot be built there. The file [`examples/windows-docker-build.yml`](../examples/windows-docker-build.yml) has a job. Registry credentials for `docker login` and `docker push` belong in a restricted context.

## Pattern B: rootless BuildKit on the host

Run a rootless BuildKit daemon on the host under a dedicated unprivileged account, and mount only its socket into a runner service. Jobs send builds to that daemon with a BuildKit client. The daemon exposes only the BuildKit build API, not the Docker API, so a job cannot start arbitrary containers or mount host paths through it.

The risk shrinks, but it does not disappear. The daemon runs on the host and shares its kernel, and every job that uses it shares its build cache. This repository documents the pattern only. It has no stack file, helper, or test for it.

## Pattern C: a daemonless builder in the job

Run a daemonless builder inside the job container, such as a maintained fork of Kaniko or Buildah. The job needs no access to the host engine, and nothing of the host is exposed.

These builders have their own privilege needs. Rootless Buildah relies on user namespaces, and Kaniko expects to run as root inside its container. Swarm ignores `security_opt` and `privileged` in a stack file, so test your builder in a class that matches your policy before you rely on it. This repository documents the pattern only.

## What to avoid

- Mounting the Docker socket into any class that is not dedicated to builds.
- Starting a privileged Docker-in-Docker container from a job. Swarm ignores `privileged`, so it does not work in a stack, and it is root-equivalent where it does work.
- Running pattern A on a manager, or on a node that also runs production workloads.
