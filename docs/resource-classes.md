---
page-title: Resource classes
page-audience: admin
page-description: Define resource classes as Swarm services, size their limits, choose replica counts, run persistent classes, enable Rerun job with SSH, and look up every setting the stack files use.
---

# Resource classes

Each Swarm service in a stack file is one CircleCI resource class. This page describes how to define a class, size it, choose its replica count, run a persistent class, and enable Rerun job with SSH. It ends with a reference of every environment variable that the stack files and the entrypoint use.

## Define a class

To add a class:

1. Create the resource class and a token in CircleCI. The class name must equal the service name.

   ```console
   $ circleci runner resource-class create <namespace>/linux-python --org <org> --generate-token
   ```

2. Copy an existing service in your stack file and change the values in the table below.
3. Create the secret `<service>-token` with the token. Refer to [Create the secrets](install-linux.md#4-create-the-secrets) or [Create the secrets on Windows](install-windows.md#5-create-the-secrets).
4. Deploy the stack again, with the same set of `-c` files as before. Swarm creates the new service and leaves unchanged services alone.

   ```console
   $ docker stack deploy -c linux/stack/runners.yaml runners
   ```

Each service needs its own values for these keys:

| Key | Value for a class named `linux-python` |
|---|---|
| Service name | `linux-python` |
| `hostname` and `CIRCLECI_RUNNER_NAME` (Linux) | `"{{.Node.Hostname}}-linux-python-{{.Task.Slot}}"` |
| `CIRCLECI_RUNNER_NAME` (Windows) | `"{{.Node.Hostname}}-windows-<class>-{{.Task.Slot}}"`. The Windows files set no `hostname` |
| `secrets.source` | `linux-python-token`, declared under the top-level `secrets:` with `external: true` |
| `networks` (Linux) | `[linux-python]`, declared under the top-level `networks:` with `driver: overlay` |

The runner name must be unique across all runners of your organization. It has at most 64 characters and contains only letters, numbers, `.`, `(`, `)`, `_`, `-`, and spaces. A long hostname plus a long class name can exceed the limit, and the runner then exits with code 80.

A complete Linux example, which reuses the anchors of `linux/stack/runners.yaml`:

```yaml
services:
  linux-python:
    <<: *runner
    image: cimg/python:3.14
    hostname: "{{.Node.Hostname}}-linux-python-{{.Task.Slot}}"
    environment:
      <<: *env
      CIRCLECI_RUNNER_NAME: "{{.Node.Hostname}}-linux-python-{{.Task.Slot}}"
      MACHINE_RUNNER_SWARM_JOB_SUDO: "true"
    secrets:
      - source: linux-python-token
        target: circleci_runner_config.yaml
        uid: "2000"
        gid: "2000"
        mode: 0400
    networks: [linux-python]
    cap_drop: [NET_RAW, MKNOD]
    deploy:
      replicas: 2
      restart_policy: *restart
      update_config: *update
      resources:
        limits: {cpus: "2", memory: 4G, pids: 4096}
        reservations: {cpus: "2", memory: 4G}
      placement: *placement

networks:
  linux-python: {driver: overlay}

secrets:
  linux-python-token: {external: true}
```

Use `MACHINE_RUNNER_SWARM_JOB_SUDO: "false"` with the capability settings of `linux-hardened` for a hardened class. Refer to [Concepts](concepts.md#users-and-the-runner-token-on-linux).

The anchor `*runner` brings the four keys that a Linux class needs for the runner: `user: "0"`, `entrypoint: ["/circleci-runner-entrypoint"]`, the config `entrypoint`, and the volume `runner-bin` mounted read-only. A service in another stack file, or one written without the anchor, repeats them:

```yaml
services:
  linux-python:
    user: "0"
    entrypoint: ["/circleci-runner-entrypoint"]
    configs:
      - {source: entrypoint, target: /circleci-runner-entrypoint, mode: 0555}
    volumes:
      - {type: volume, source: runner-bin, target: /opt/machine-runner-swarm, read_only: true}

configs:
  entrypoint: {name: machine-runner-swarm-entrypoint-<12 hex digits>, file: <path to circleci-runner-entrypoint>}

volumes:
  runner-bin: {}
```

The name of the config carries the first 12 hex digits of the SHA-256 of the file, because a Swarm config cannot change. Refer to [Upgrade to a new release of this repository](operations.md#upgrade-to-a-new-release-of-this-repository). The shipped add-on files repeat the top-level `configs:` and `volumes:`, so each of them also loads alone.

On Windows, copy a service such as `windows-default`. The secret has no `uid`, `gid`, or `mode`, and the file defines no networks.

## Size the limits

The stack sets the same values for limits and reservations. The limit caps what a runner can use. The reservation tells the scheduler how much room a replica needs.

| Setting | Linux | Windows |
|---|---|---|
| `limits.cpus` | Caps CPU for the container | Caps CPU. A value above the CPU count of the host is rejected |
| `limits.memory` | Caps memory. The kernel kills a job that exceeds it | Caps memory |
| `limits.pids` | Caps processes. The files set `4096` | Rejected by the Windows engine, so absent |
| `reservations` | Scheduler only. Equal to the limits, so extra replicas stay pending instead of overcommitting | Scheduler only. The engine never receives it |
| `ulimits` | `nofile` 65536, `core` 0 | Rejected by the Windows engine, so absent |

Size one runner for the largest job of the class, not for the average job. A job cannot choose a different size, because the resource class defines it. Create a second class for jobs that need more, for example `linux-large`.

Plan the node capacity from the reservations:

- The sum of the reservations of all replicas on a node must fit in the node. Leave room for the operating system and Docker, for example one CPU and 2 GB of memory.
- The shipped Linux file reserves 10 CPUs and 20 GB of memory in total. A node with fewer resources runs fewer replicas, and the others stay `Pending`. The `runner-distributor` service reserves nothing, and its limit is 0.5 CPU and 256 MB.
- Swarm cannot limit disk for a container. Jobs share the Docker data disk of the node, so size it for the replicas plus the stopped containers that Swarm keeps. Refer to [Start Swarm](install-linux.md#3-start-swarm).

## Choose replica counts

`deploy.replicas` is the number of jobs that the class runs at the same time. Choose it as follows:

1. Estimate the peak number of parallel jobs for the class from your workflows.
2. Check that nodes with enough room exist. A replica needs its full reservation on one node.
3. Add headroom for short jobs. A replica needs about 10 seconds between jobs, so a class that receives many very short jobs benefits from one extra replica.
4. Set the value in the stack file and deploy again. The file stays the source of truth.

For a quick change, scale the service directly. The next `docker stack deploy` resets the count to the value in the file.

```console
$ docker service scale runners_linux-default=4
```

Swarm has no autoscaling. An idle replica holds its reservation, so a class with more replicas than demand wastes node capacity. Set `replicas: 0` to switch a class off without deleting it.

## Persistent mode

A persistent class runs the runner in `continuous` mode. One long-lived container claims job after job, and a named volume keeps data between jobs. Use it only for trusted projects that gain a lot from warm caches.

> [!WARNING]
> Continuous mode removes the guarantee of a clean environment. A job can leave files, processes, or settings that later jobs see, and a job can change what later jobs run. CircleCI describes untrusted jobs on a runner that keeps its environment as the highest risk.

To limit the risk:

- Create a separate resource class for it, and restrict the class to named projects with a config policy. Refer to [CircleCI-side controls](security.md#circleci-side-controls).
- Keep production contexts away from the class.
- Put cleanup steps at the start of its jobs. The runner does not clean the working directory on Linux.
- Recycle the runner on a schedule.

### Linux

The file `linux/stack/persistent.yaml` defines `linux-persistent`. It sets `CIRCLECI_RUNNER_MODE: continuous` and sets no idle timeout. It mounts the named volume `persistent-home` at `/home/circleci`. Swarm copies the image content of that directory into the new volume on first use.

A volume lives on one node, so the service pins itself with the constraint `node.hostname == CHANGE-ME`. Edit that value before you deploy.

The service sets `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` to `"false"`. The runner user cannot remove files that the job user created, so the runner does not clean the working directory, and each job must clean up what an earlier job left. Refer to [Working directory cleanup](security.md#working-directory-cleanup).

```console
$ printf 'api:\n  auth_token: %s\n' "$TOKEN" | docker secret create linux-persistent-token -
$ docker stack deploy -c linux/stack/runners.yaml -c linux/stack/persistent.yaml runners
```

Recycle the runner with a forced update. The runner drains first (a runner drain: it takes no new job and finishes the running one), so a running job finishes. The volume survives. The container keeps the runner version that it started with, so a forced update is also how the class moves to a new runner version.

```console
$ docker service update --force runners_linux-persistent
```

### Windows

The add-on stack file `windows\stack\persistent.yaml` defines `windows-persistent`. It sets `CIRCLECI_RUNNER_MODE: continuous` and sets no idle timeout. It declares and mounts the named volume `windows-persistent-cache` at `C:\cache`. Point NuGet, npm, and similar caches there with an environment variable in the job.

The service is pinned to the nodes that carry the label `machine-runner-swarm.class.windows-persistent=true`. Create the secret `windows-persistent-token` first, then label the node and deploy the file with the main file:

```powershell
docker node update --label-add machine-runner-swarm.class.windows-persistent=true <node name>
docker stack deploy -c windows\stack\runners.yaml -c windows\stack\persistent.yaml runners
```

Swarm still replaces the container when the runner exits. Only the volume survives the replacement. On Windows, the runner and the jobs use the same account, so the runner cleans the working directory, and `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` stays `"true"`.

## Rerun job with SSH

The add-on stack files `linux/stack/ssh-rerun.yaml` and `windows\stack\ssh-rerun.yaml` define the classes `linux-default-ssh` and `windows-default-ssh`. Their runners support **Rerun job with SSH**, which opens a shell in a running job so that a user can debug it. Deploy them only if you need this. The default classes publish no port and cannot serve SSH.

A runner turns the feature on when `CIRCLECI_RUNNER_SSH_ADVERTISE_ADDR` is set. The task agent then starts an SSH server on port 54782, which is fixed, and the **Enable SSH** and **Wait for SSH** steps show the advertised address. CircleCI only displays that address, so it can be any name or IP address that your users can reach. The add-on files set it to `{{.Node.Hostname}}:54782`, and Swarm fills in the node name for each task. If your DNS does not resolve the node hostnames, write a name or an address that it does, for example `{{.Node.Hostname}}.example.com:54782`.

The file publishes port 54782 in host mode, so it opens on the node that runs the task. The default ingress mode would send a connection to any replica of the class, which can be another user's job. A node has one port 54782, so the service sets `max_replicas_per_node: 1`, and replicas beyond the number of eligible nodes stay pending.

A rerun uses the resource class of the original job. To debug a job, run it on the SSH class by setting its `resource_class` to `<namespace>/linux-default-ssh`. To give an existing class SSH instead, copy three settings from the add-on file into that service in your copy of the stack file: the environment variable, the host-mode port, and `max_replicas_per_node: 1`. Every replica of that class then needs its own node.

```console
$ printf 'api:\n  auth_token: %s\n' "$TOKEN" | docker secret create linux-default-ssh-token -
$ docker stack deploy -c linux/stack/runners.yaml -c linux/stack/ssh-rerun.yaml runners
```

Before you use it:

- **Firewall.** Open inbound TCP 54782 on the nodes that run the class, only from the networks where your users connect, such as a VPN. Runners need no other inbound port.
- **SSH key.** A user adds a public key in their CircleCI user settings. Without a key, the **Enable SSH** step does not appear.
- **Concurrency.** A rerun with SSH holds the runner for up to 2 hours after a user connects, or 10 minutes if nobody does. The job counts against the concurrency limit of your organization, and the replica takes no other job. With one replica for each node, a forgotten session blocks the node, so size the class for it.
- **Cancel.** Cancel the rerun in the web app or with the CLI when you finish. The container then exits, and Swarm starts a new one.
- **Security.** The SSH user gets the privileges of the job user, and can reach what the job reached. Anyone who can start a job on the class can rerun it with SSH, and only the user who reruns gets their keys added. In `linux-default-ssh` the job user keeps sudo, as in `linux-default`, so the SSH user can read the runner token. Set `MACHINE_RUNNER_SWARM_JOB_SUDO` to `"false"` to prevent this. Keep the class for named projects, and keep deploy contexts away from SSH reruns. Refer to [CircleCI-side controls](security.md#circleci-side-controls).

On Windows, the SSH user must name the shell: `ssh -p 54782 <host> -- powershell.exe`. Open the port in Windows Defender Firewall as well. The Windows file is not tested.

## Configuration reference

### Variables in the stack files

| Variable | Value in the files | Applies to | Notes |
|---|---|---|---|
| `CIRCLECI_RUNNER_NAME` | `"{{.Node.Hostname}}-<service>-{{.Task.Slot}}"` | Every service | Required. Unique per replica |
| `CIRCLECI_RUNNER_MODE` | `single-task`, or `continuous` for persistent classes | Every service | `single-task` gives a new container for every job |
| `CIRCLECI_RUNNER_IDLE_TIMEOUT` | `1h` | Single-task services | An idle replica exits and Swarm replaces it. Do not set it in continuous mode |
| `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` | `"false"` on Linux, `"true"` on Windows | Every service | On Windows, the runner removes the working directory before and after each task. On Linux it stays off, because the runner user cannot remove files that the job user owns. Refer to [Working directory cleanup](security.md#working-directory-cleanup) |
| `CIRCLECI_RUNNER_LOGGING_FORMAT` | `text` | Every service | No color codes in logs |
| `CIRCLECI_RUNNER_MAX_RUN_TIME` | Commented out, default `5h` | Every service | If you lower it, lower `stop_grace_period` to the same value plus 5 minutes |
| `HTTPS_PROXY`, `NO_PROXY` | Commented out | Every service | Jobs inherit variables that you set here |
| `MACHINE_RUNNER_SWARM_JOB_SUDO` | `"true"` or `"false"` | Linux | `"false"` makes the class hardened |
| `CIRCLECI_RUNNER_WORK_DIR` | `C:\cci\w` | Windows | The working directory of jobs. The task agent creates it |
| `CIRCLECI_RUNNER_TASK_AGENT_DIRECTORY` | `C:\cci\agent` | Windows | The task agent directory. The runner creates it |
| `MACHINE_RUNNER_SWARM_INSTANCE_ID` | `{{.Task.ID}}` | Windows | Lets a job tell which container it ran in |
| `GIT_TERMINAL_PROMPT`, `GCM_INTERACTIVE`, `GIT_CONFIG_*` | `0`, `never`, and `core.longpaths=true` | Windows | Stop Git prompts, and allow long paths. The system Git config is read-only |
| `PATH` | The full Server Core path, then Git | Windows stock services | Replaces the image `PATH`, so the file spells it out |

Refer to the [machine runner 3 configuration reference](https://circleci.com/docs/guides/execution-runner/machine-runner-3-configuration-reference/) for every other `CIRCLECI_RUNNER_*` variable. Environment variables override the config file.

### Variables read by the Linux entrypoint

| Variable | Default | Notes |
|---|---|---|
| `MACHINE_RUNNER_SWARM_RUNNER_WAIT` | `120` | The seconds that the entrypoint waits for the link `current` of the runner distributor. Without it, the container exits with code 80 |
| `MACHINE_RUNNER_SWARM_JOB_USER` | `circleci` | The account that runs jobs. The entrypoint creates it with uid 2001 when the image has none |
| `MACHINE_RUNNER_SWARM_JOB_SUDO` | `true` | `false` removes every sudo right of the job user in that container and steps jobs down with `setpriv --no-new-privs`, which needs util-linux `setpriv` in the image (exit code 80 without it). Any other value exits with code 80 |

The runner user is `circleci-runner` with uid 2000. It owns the secret file and has no sudo rights.

The entrypoint sets these variables for the runner. It always sets the command prefix, and it keeps a value that you set for the other three:

| Variable | Value |
|---|---|
| `CIRCLECI_RUNNER_COMMAND_PREFIX` | `["sudo","-niHu","<job user>","--"]`, or a `setpriv` command when the image has no sudo, and always a `setpriv --no-new-privs` command in a hardened class |
| `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` | `false`. Do not set it to `true` on Linux |
| `CIRCLECI_RUNNER_TASK_AGENT_DIRECTORY` | `/var/lib/circleci-runner/agent`, owned by the runner user |
| `CIRCLECI_RUNNER_WORK_DIR` | `/var/opt/circleci/workdir`, owned by the job user. Keep a custom directory under `/var/opt/circleci` |

Arguments that you pass to the entrypoint replace the default command, which is `machine --config /run/secrets/circleci_runner_config.yaml`.

### Variables read by the runner distributor

These are variables of `docker stack deploy`, and `x-distributor-env` in `linux/stack/runners.yaml` passes them to the `runner-distributor` service. They apply to that service only. Refer to [Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux).

| Variable | Default | Effect |
|---|---|---|
| `MACHINE_RUNNER_SWARM_RUNNER_VERSION` | `current` | `current` follows the manifest of CircleCI. A version such as `3.1.12` pins that version |
| `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` | `3` | The major version that `current` may adopt |
| `MACHINE_RUNNER_SWARM_CHECK_INTERVAL` | `24h` | How often the distributor looks again: seconds, or a number with `s`, `m`, `h`, or `d` |
| `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` | `https://circleci-binary-releases.s3.amazonaws.com/circleci-runner` | Where `manifest.json` and the tarballs are, for example a mirror |
| `MACHINE_RUNNER_SWARM_RUNNER_SHA256` | Empty | A comma-separated list of the SHA-256 values of the tarballs that may be installed, instead of the value of the manifest |

### Stack keys on Windows

Not every key of a stack file reaches a Windows container. `docker stack deploy` and the Windows engine treat the keys as follows.

| Effect | Keys |
|---|---|
| Used | `isolation`, bind mounts of directories, `npipe` mounts, named volumes, secrets without `uid`, `gid`, and `mode`, `stop_grace_period`, `logging`, `entrypoint`, `environment` with Swarm placeholders, `labels`, `deploy.placement`, `deploy.restart_policy`, `deploy.update_config`, `deploy.endpoint_mode`, and `deploy.resources.limits` for `cpus` and `memory` |
| Scheduler only | `deploy.resources.reservations`. The engine rejects a memory reservation, so Swarm never sends it |
| Rejected by the Windows engine | `deploy.resources.limits.pids` and `ulimits`, so the files do not set them. A `limits.cpus` above the CPU count of the host is rejected too |
| No effect | `init`, `cap_drop`, `cap_add`, `read_only`, `tmpfs`, and `sysctls` |
| Ignored by `docker stack deploy` on every platform | `security_opt`, `privileged`, `userns_mode`, `restart`, and `build` |

Three choices in the Windows files follow from this:

- **No `hostname`.** A Windows computer name has at most 15 characters, and a templated hostname would give every container of a slot the same `COMPUTERNAME`. Without it, `COMPUTERNAME` is the container ID, which tells the containers apart.
- **`endpoint_mode: dnsrr`.** Nothing connects to a runner, so no virtual IP is needed.
- **Settings repeated per service.** YAML merge keys do not merge deeply. The idle timeout is set for each service, because the persistent class must not have one, and `windows-docker-build` repeats the `PATH` with `C:\docker` appended.

The log driver is `json-file` with rotation. The `local` driver also works on Windows.

### The secret

| | Linux | Windows |
|---|---|---|
| Name | `<service>-token` | `<service>-token` |
| Target | `circleci_runner_config.yaml` | `circleci_runner_config.yaml` |
| Path in the container | `/run/secrets/circleci_runner_config.yaml` | `C:\ProgramData\Docker\secrets\circleci_runner_config.yaml` |
| Owner and mode | uid 2000, gid 2000, `0400` | Not supported. Administrators and `SYSTEM` only |
| Content | `api:` and `auth_token: <token>` | The same |

The runner does not look for a config file on its own. The entrypoint arguments pass `--config <path>`, and environment variables override the values in the file.

### Exit codes

| Code | Source | Meaning |
|---|---|---|
| 0 | Runner | A normal exit after a job or after a runner drain. Swarm starts a new container |
| 80 | Entrypoint | A prerequisite is missing: the link `current` does not exist after the wait, the runner does not match its SHA-256 record, the runner or a directory above it is not root-owned or is writable, the image has neither sudo nor `setpriv` (or, for a hardened class, no util-linux `setpriv` with `--no-new-privs`), `MACHINE_RUNNER_SWARM_JOB_SUDO` is invalid, or the entrypoint cannot remove every sudo right of the job user |
| 80 | Runner | A configuration error: a missing or invalid name, an empty token, an unknown log level, or an invalid mode |
| 1 | Runner | The config file is missing because the secret is not attached, the YAML does not parse, or a duration is malformed |

Swarm restarts a container that exits with any code after the restart delay of 10 seconds. It never gives up and never backs off, so a configuration error repeats until you fix it. Refer to [Troubleshooting](troubleshooting.md#the-container-restarts-every-10-seconds).
