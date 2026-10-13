---
page-title: Runner distributor (draft)
page-audience: admin
page-description: Draft of the new default for Linux nodes. A global Swarm service keeps the pinned runner on every node, so no host install step is left.
---

# Runner distributor (draft)

> [!NOTE]
> This page is a draft of the new default. `linux/setup.sh --install` and the global job of [Install on every node with one command](operations.md#install-on-every-node-with-one-command) still work and are not removed yet.

Today every node needs `setup.sh --install` before it can run a replica. With the distributor, the nodes need Docker and a Swarm join and nothing else.

```console
$ docker stack deploy -c linux/stack/runners.yaml -c linux/stack/distributor.yaml runners
```

## How it works

- **`runner-distributor`** is a `global` service from a stock `alpine:3` image, pinned by digest. It runs on every Linux node, also on a node that joins later. Its script, `linux/runner-distributor.sh`, is a Swarm config.
- It downloads the pinned version, compares the SHA-256 of the `circleci-runner` binary with the pin, writes it to `versions/<version>/bin/circleci-runner` in the per-node volume `runner-bin`, moves the link `current` to it with one atomic rename, and idles. Old versions stay in the volume.
- The runner services mount `runner-bin` read-only at `/opt/machine-runner-swarm`. Their entrypoint is a second Swarm config, so a job that rewrites the volume cannot replace the checks.
- The entrypoint waits up to `MACHINE_RUNNER_SWARM_RUNNER_WAIT` seconds (default 120) until `current` points to `versions/<pinned version>`, resolves the link once, and exits 80 unless the binary has the pinned SHA-256. Swarm retries after the restart delay. The wait covers a first deploy, when the volume is empty, and an upgrade, when a new container starts before the flip.

## Pins

Three values in `linux/stack/distributor.yaml`, or the same names in the environment of `docker stack deploy`:

| Variable | Value |
|---|---|
| `MACHINE_RUNNER_SWARM_RUNNER_VERSION` | the runner version, for example `3.1.12` |
| `MACHINE_RUNNER_SWARM_RUNNER_SHA256_AMD64`, `..._ARM64` | the SHA-256 of the `circleci-runner` **binary**, not of the tarball in `checksums.txt` |

```console
$ curl -fsSL https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/<version>/circleci-runner_linux_<arch>.tar.gz | tar -xzO circleci-runner | sha256sum
```

## Upgrade and roll back

Change the three pins and run `docker stack deploy` again. The distributors on all nodes download, verify and flip at the same time. The runner services update one replica at a time, as before: an idle replica stops at once, and a busy one finishes its job first.

- **A running job** keeps the binary it started with. The container's runner process was started from `versions/<old>/...`, which is never deleted, so the flip of `current` does not touch it, even though the container sees the new link at once.
- **The next container**, which is the next job, runs the new version.
- **A rollback** is the same command with the old pins. The version is in the volume, so the distributor only checks its SHA-256 and flips.

Old versions use about 75 MB each. Remove one when no container uses it: `docker run --rm -v runners_runner-bin:/v alpine rm -rf /v/versions/<old>`.

## Integrity

The entrypoint hashes the binary at every container start (about 0.05 s for 75 MB). A binary that differs, for example after a privileged job such as a microVM class with `SYS_ADMIN` remounted the volume read-write and replaced it, stops the next container with exit 80 and `does not match the pinned SHA-256`. A force update of the distributor (`docker service update --force runners_runner-distributor`) downloads and verifies the version again. The check narrows the window but does not close it: a sibling container that rewrites the file between the hash and the `exec` of one start is not detected.

## What changes compared with the host install

- An upgrade is a service update. The pins are part of the runner services, so every class rolls one replica at a time: an idle replica restarts at once, and a busy one drains first (the real runner finishes its job after SIGTERM and exits 0). With the host install nothing restarted, and idle replicas kept the old version for up to an hour.
- The pins and the images are in one place, the stack. A node cannot run another version than the stack names, and a manual `ln -sfn` on a node does nothing.
- Every class needs the four keys of `distributor.yaml` (`entrypoint`, `configs`, `environment`, `volumes`). The add-on files `docker-build.yaml` and `persistent.yaml` are not changed yet.

## Windows

The same design maps to Windows nodes, with one difference that matters: a Windows stop kills a busy container after about 5 seconds, so a service update that carries the pins would kill running jobs. Not tested.

- A `global` service on `node.platform.os == windows` from a stock Windows Server Core image (pulled once per node, about 5 GB). The PowerShell script is a Swarm config, and it uses `Invoke-WebRequest` and `Get-FileHash`.
- A named volume (local driver) that the distributor mounts read-write and the runner services read-only at `C:\machine-runner-swarm`, with `versions\<version>` and a junction `current` (`cmd /c rmdir`, then `mklink /J`: two steps, so the entrypoint must retry).
- The pins must stay out of the runner service spec, for example in the distributor only, or the class is rolled while it is idle (see [Roll out a change when the class is idle](operations.md#roll-out-a-change-when-the-class-is-idle)). That drops the per-start check on Windows, which has no step-down anyway.
