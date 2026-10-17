---
page-title: Resource classes
page-audience: admin
page-description: Resource classes as Swarm services: default sizes and limits, how to add a class, replica counts, persistent classes, Rerun job with SSH, and the stack variable reference.
---

# Resource classes

Each Swarm service in a stack file is one CircleCI resource class, named `<namespace>/<service>`, and `deploy.replicas` is how many jobs it runs at once. This page lists the shipped sizes, then how to add a class, choose replicas, run a persistent class, enable Rerun job with SSH, and read the stack variables.

## Size the limits

Limits cap what a runner can use. Reservations tell the scheduler how much room a replica needs, and the stack sets them equal. A reservation is held whether or not the replica runs a job, so you pay for the peak. A service with no reservation still has the limit shown.

| Service | File | Replicas | Reserved for each replica | Limit, when it differs |
|---|---|---|---|---|
| `linux-default` | `runners.yaml` | 2 | 2 CPUs, 4 GB | |
| `token-proxy` | `runners.yaml` | 1 | 0.1 CPU, 32 MB | 0.5 CPU, 128 MB |
| `runner-distributor` | `runners.yaml` | One for each Linux node | Nothing | 0.5 CPU, 256 MB |
| `linux-java` | `classes-extra.yaml` | 1 | 4 CPUs, 8 GB | |
| `linux-hardened` | `classes-extra.yaml` | 1 | 2 CPUs, 4 GB | |
| `linux-docker-build` | `docker-build.yaml` | 1 | 4 CPUs, 8 GB | |
| `linux-microvm` | `microvm.yaml` | 2 | 2 CPUs, 4 GB | The VM adds overhead of its own, not measured here |
| `linux-microvm-docker` | `microvm.yaml` | 1 | 4 CPUs, 8 GB | The same |
| `microvm-dns` | `microvm.yaml` | 2 | Nothing | 0.5 CPU, 128 MB |
| `microvm-netkeep` | `microvm.yaml` | One for each microVM node | Nothing | 0.2 CPU, 256 MB |
| `linux-persistent` | `persistent.yaml` | 1 | 4 CPUs, 8 GB | |
| `linux-default-ssh` | `ssh-rerun.yaml` | 1 | 2 CPUs, 4 GB | |
| `windows-default` | `runners.yaml` (Windows) | 2 | 2 CPUs, 4 GB | |
| `token-proxy-windows` | `runners.yaml` (Windows) | 1 | Nothing | 1 CPU, 512 MB |
| `runner-distributor-windows` | `runners.yaml` (Windows) | One for each Windows node | Nothing | 1 CPU, 1 GB |
| `windows-custom`, `windows-docker-build`, `windows-default-ssh` | Add-on files (Windows) | 1 each | 2 CPUs, 4 GB | |
| `windows-persistent` | `persistent.yaml` (Windows) | 1 | 4 CPUs, 8 GB | |

The shipped `runners.yaml` reserves 4.1 CPUs and a little over 8 GB on Linux, and 4 CPUs and 8 GB on Windows, before the operating system, Docker and the distributor. `classes-extra.yaml` adds 6 CPUs and 12 GB.

| Setting | Linux | Windows |
|---|---|---|
| `limits.cpus` | Caps CPU | Caps CPU. A value above the CPU count of the host is rejected |
| `limits.memory` | Caps memory. The kernel kills a job that exceeds it | Caps memory |
| `limits.pids` | Caps processes. The files set `4096` | Rejected by the Windows engine, so absent |
| `reservations` | Scheduler only. Extra replicas stay pending instead of overcommitting | Scheduler only. The engine never receives it |
| `ulimits` | `nofile` 65536, `core` 0 | Rejected by the Windows engine, so absent |

Size one runner for the largest job of the class. A job cannot pick a size, so create a second class (for example `linux-large`) for bigger jobs. The reservations of all replicas on a node must fit in it, with room for the operating system and Docker (for example one CPU and 2 GB). Replicas that do not fit stay `Pending`.

Swarm cannot limit disk. Jobs share the Docker data disk of the node, so size it for the replicas plus the stopped containers that Swarm keeps ([Start Swarm](install-linux.md#3-start-swarm)). A Windows node also holds the `servercore` base image (about 2.2 GB compressed).

**Cost.** This project has no price of its own. You pay for the nodes at the peak, your CircleCI plan, and the network and storage that jobs use. Runner compute does not use credits, but at least one credit is needed, and self-hosted runner concurrency is a separate limit of your plan ([Run jobs on self-hosted runners](https://circleci.com/docs/guides/execute/run-jobs-on-self-hosted-runners/)).

## Define a class

The shipped `linux/stack/runners.yaml` has one class, `linux-default`. Add other classes to your copy of the stack files (`deploy/runners.yaml`, as [Install on Linux](install-linux.md) describes) and deploy your copy. `linux/stack/classes-extra.yaml` is a worked example: it adds `linux-java` and `linux-hardened`.

1. Create the resource class and a token in CircleCI. The class name must equal the service name.

   ```bash
   circleci runner resource-class create <NAMESPACE>/linux-python --org <ORG> --generate-token
   ```

2. Copy the service `linux-default` in your stack file under another name, and change the name, `hostname`, `CIRCLECI_RUNNER_NAME` and `networks` as in the example below.
3. Create the secret `<service>-token` with the token. Refer to [Create the secrets](install-linux.md#4-create-the-secrets) or [Create the secrets on Windows](install-windows.md#4-create-the-secrets).
4. On Linux, add the class network and secret to the existing `token-proxy` service. The proxy serves a class for every secret `<service>-token` that it holds, and finds its runners as `tasks.<service>`.
5. Deploy again with the same `-c` files as before. Swarm creates the new service and leaves the others alone.

   ```bash
   docker stack deploy -c deploy/runners.yaml runners
   ```

The runner name must be unique across the runners of your organization. It has at most 64 characters and contains only letters, numbers, `.`, `(`, `)`, `_`, `-`, and spaces. A long hostname plus class name can exceed that, and the runner then exits with code 80.

A Linux example, in your copy of `runners.yaml`, where the anchors `*runner`, `*env`, `*restart`, `*update` and `*placement` resolve. First, the service next to `linux-default`:

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
    networks: [linux-python]
    cap_drop: [NET_RAW, MKNOD]   # keep NET_RAW dropped: the proxy tells runners apart by source address
    deploy:
      replicas: 2
      restart_policy: *restart
      update_config: *update
      resources:
        limits: {cpus: "2", memory: 4G, pids: 4096}
        reservations: {cpus: "2", memory: 4G}
      placement: *placement
```

Second, add these lines to the `token-proxy:` key, which appears once in the file. Do not repeat the key:

```yaml
  token-proxy:
    secrets:
      # ... the secrets of the classes that are there
      - {source: linux-python-token, target: linux-python-token, uid: "65534", gid: "65534", mode: 0400}
    networks: [linux-default, linux-python]   # every class network, the new one included
```

Third, declare the network (`linux-python: {driver: overlay, driver_opts: {encrypted: "true"}}`) under the top-level `networks:` and the secret (`linux-python-token: {external: true}`) under `secrets:`.

A deploy that adds a class secret replaces the proxy task. What the runners see meanwhile is in [Restart the proxy](operations.md#restart-the-proxy). A class that the proxy does not serve gets 403 on every claim, and the proxy log says `not a runner of any class`. For a hardened class, set `MACHINE_RUNNER_SWARM_JOB_SUDO: "false"` with the capability settings of `linux-hardened` ([Concepts](concepts.md#users-and-the-runner-token-on-linux)).

**A class in its own stack file.** Write `token-proxy` there with only the secret and network: Swarm merges files by name. Anchors do not reach into another file, so repeat what `*runner` sets (`user: "0"`, the `entrypoint` and its config, the placeholder secret `runner-placeholder-token`, `CIRCLECI_RUNNER_API_URL: http://token-proxy:8080`, and the read-only volume `runner-bin`), or copy `classes-extra.yaml`. The config name carries the first 12 hex digits of the SHA-256 of the file, because a Swarm config cannot change ([Upgrade to a new release of this repository](operations.md#upgrade-to-a-new-release-of-this-repository)).

**A class on Windows.** Copy a service such as `windows-default` in your copy of `windows\stack\runners.yaml`, with its two mounts of the volume `runner-bin` (`subpath: current` and `subpath: 'git\current'`). Its `CIRCLECI_RUNNER_NAME` is `"{{.Node.Hostname}}-windows-<class>-{{.Task.Slot}}"`, and the file sets no `hostname`. The secret has no `uid`, `gid`, or `mode`, and the file defines no networks. A single-task class also adds its secret (target `<service>-token`) to `token-proxy-windows`, and reads `runner-placeholder-token`.

## Choose replica counts

`deploy.replicas` is the number of jobs the class runs at the same time.

1. Estimate the peak number of parallel jobs for the class.
2. Check that nodes with enough room exist. A replica needs its full reservation on one node.
3. Add one replica for many very short jobs. A replica needs about 10 seconds between jobs.
4. Set `deploy.replicas` in the stack file and deploy again. The file stays the source of truth.

For a quick change, scale the service. The next `docker stack deploy` resets the count to the file.

```bash
docker service scale runners_linux-default=4
```

Swarm has no autoscaling and this stack adds none. Set `replicas: 0` to switch a class off without deleting it, and know that jobs for a class with no runner wait without limit and hold concurrency ([Capacity and concurrency](operations.md#capacity-and-concurrency)). For elastic capacity, use the machine runner orchestrator or CircleCI cloud executors ([FAQ](faq.md#does-it-scale-to-zero-and-what-does-idle-capacity-cost)).

## Persistent mode

**Status: experimental.** CI runs the persistent class with a fake or idle runner only, and no real job runs on it in CI.

A persistent class runs the runner in `continuous` mode. One long-lived container claims job after job, and a named volume keeps data between jobs. Use it only for trusted projects that gain a lot from warm caches.

> [!WARNING]
> Continuous mode removes the guarantee of a clean environment. A job can leave files, processes, or settings that later jobs see, and can change what later jobs run. CircleCI rates untrusted jobs on a runner that keeps its environment as the highest risk.

To limit the risk:

- Use a separate class restricted to named projects with a config policy ([CircleCI-side controls](security.md#circleci-side-controls)), and keep production contexts away from it.
- Put cleanup steps at the start of its jobs. The runner does not clean the working directory on Linux.
- Recycle the runner on a schedule.
- On Linux this class is weaker than the single-task classes: it does not use the token proxy, so the runner holds the real token ([The persistent class](security.md#the-persistent-class)).

### Linux

`linux/stack/persistent.yaml` defines `linux-persistent`. It sets `CIRCLECI_RUNNER_MODE: continuous` with no idle timeout, mounts the named volume `persistent-home` at `/home/circleci` (Swarm copies the image content of that directory into the new volume on first use), and sets `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` to `"false"`, so each job must clean up what an earlier job left ([Working directory cleanup](security.md#working-directory-cleanup)).

A volume lives on one node, so the service has the constraint `node.hostname == CHANGE-ME`. Edit it in your copy (`deploy/persistent.yaml`) before you deploy.

The runner keeps its class token in its own container, because a continuous runner claims after every job and the proxy allows one claim for each container. The shipped file sets `MACHINE_RUNNER_SWARM_JOB_SUDO: "false"`, so jobs have no sudo and cannot read the token file, and the tools that a job needs must be in the image ([Images](images.md)). Set it to `"true"` in your copy if jobs need sudo, and accept that a job that uses it reads the token and can run a runner of its own on the class.

```bash
printf 'api:\n  auth_token: %s\n' "$TOKEN" | docker secret create linux-persistent-token -
docker stack deploy -c deploy/runners.yaml -c deploy/persistent.yaml runners
```

Recycle the runner with a forced update. It drains first (it finishes the running job and takes no new one), and the volume survives. A forced update is also how the class moves to a new runner version.

```bash
docker service update --force runners_linux-persistent
```

### Windows

`windows\stack\persistent.yaml` defines `windows-persistent`. It sets `CIRCLECI_RUNNER_MODE: continuous` with no idle timeout, and mounts the named volume `windows-persistent-cache` at `C:\cache`. Point NuGet, npm, and similar caches there with an environment variable in the job. The runner and the jobs use the same account, so the runner cleans the working directory and `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` stays `"true"`.

The service is pinned to nodes with the label `machine-runner-swarm.class.windows-persistent=true`. Create the secret `windows-persistent-token`, label the node, and deploy your copy with your copy of the main file:

```powershell
docker node update --label-add machine-runner-swarm.class.windows-persistent=true <NODE_NAME>
docker stack deploy -c deploy\runners.yaml -c deploy\persistent.yaml runners
```

## Rerun job with SSH

**Status: experimental.** CI checks that the files parse, merge and keep their contract (the host-mode port 54782, `max_replicas_per_node: 1`, the advertise address). The Swarm side was proven by hand on Linux with a real runner. No CI test logs in over SSH, and the Windows file is untested.

The add-on files `linux/stack/ssh-rerun.yaml` and `windows\stack\ssh-rerun.yaml` define `linux-default-ssh` and `windows-default-ssh`. Their runners support **Rerun job with SSH**, which opens a shell in a running job. The default classes publish no port and cannot serve it.

- **Advertised address.** Setting `CIRCLECI_RUNNER_SSH_ADVERTISE_ADDR` turns the feature on. The task agent then starts an SSH server on the fixed port 54782, and the **Enable SSH** and **Wait for SSH** steps show the address. CircleCI only displays it, so it can be any name or IP address your users reach. The add-on files set `{{.Node.Hostname}}:54782`. If DNS does not resolve node hostnames, use one that does, for example `{{.Node.Hostname}}.example.com:54782`.
- **Host-mode port.** The file publishes 54782 in host mode, so it opens on the node that runs the task (ingress mode would send a connection to any replica, which can be another user's job). A node has one port 54782, so the service sets `max_replicas_per_node: 1`, and replicas beyond the number of eligible nodes stay pending.
- **Which class.** A rerun uses the class of the original job, so set the `resource_class` of the job to debug to `<namespace>/linux-default-ssh`. To give an existing class SSH, copy three settings from the add-on file into that service: the environment variable, the host-mode port, and `max_replicas_per_node: 1`. Every replica of that class then needs its own node.

```bash
printf 'api:\n  auth_token: %s\n' "$TOKEN" | docker secret create linux-default-ssh-token -
docker stack deploy -c deploy/runners.yaml -c deploy/ssh-rerun.yaml runners
```

Before you use it:

- **Firewall.** Open inbound TCP 54782 on the nodes that run the class, only from the networks where your users connect, such as a VPN. Docker publishes the port with NAT rules that run before `ufw` and `firewalld` rules, so those rules do not restrict it. Filter in the `DOCKER-USER` chain or with a cloud security group, for example `sudo iptables -I DOCKER-USER ! -s <VPN_RANGE> -p tcp --dport 54782 -j DROP` (not tested here). Refer to [Listening ports on a node](security.md#listening-ports-on-a-node).
- **SSH key.** A user adds a public key in their [CircleCI user settings](https://app.circleci.com/settings/user/job-ssh-keys), or, with a GitHub or Bitbucket organization, to their VCS account. Without a key, the **Enable SSH** step does not appear. Refer to [Debug jobs with SSH rerun](https://circleci.com/docs/guides/execute/ssh-access-jobs/).
- **Concurrency.** A rerun holds the runner for up to 2 hours after a user connects (1 hour on the Free plan), or 10 minutes if nobody does. It counts against the concurrency limit of your organization, and the replica takes no other job. A forgotten session blocks the node. Cancel the rerun in the web app or with the CLI when you finish: the container exits and Swarm starts a new one.
- **Security.** The SSH user gets the privileges of the job user and can reach what the job reached. Anyone who can start a job on the class can rerun it with SSH, and only the user who reruns gets their keys added. In `linux-default-ssh` the job user keeps sudo, so the SSH user is root in the container, but it holds only the placeholder, because the class claims through the token proxy. Set `MACHINE_RUNNER_SWARM_JOB_SUDO` to `"false"` to take root away. Keep the class for named projects and deploy contexts away from it ([CircleCI-side controls](security.md#circleci-side-controls)).

On Windows, the SSH user must name the shell: `ssh -p 54782 <HOST> -- powershell.exe`. Open the port in Windows Defender Firewall as well.

## Configuration reference

### Variables in the stack files

| Variable | Value in the files | Applies to | Notes |
|---|---|---|---|
| `CIRCLECI_RUNNER_NAME` | `"{{.Node.Hostname}}-<service>-{{.Task.Slot}}"` | Every service | Required. Unique per replica |
| `CIRCLECI_RUNNER_MODE` | `single-task`, or `continuous` for persistent classes | Every service | `single-task` gives a new container for every job |
| `CIRCLECI_RUNNER_IDLE_TIMEOUT` | `1h` | Single-task services | An idle replica exits and Swarm replaces it. Do not set it in continuous mode |
| `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` | `"false"` on Linux, `"true"` on Windows | Every service | On Linux the runner user cannot remove files that the job user owns, so never set `true` there ([Working directory cleanup](security.md#working-directory-cleanup)) |
| `CIRCLECI_RUNNER_LOGGING_FORMAT` | `text` | Every service | No color codes in logs |
| `CIRCLECI_RUNNER_MAX_RUN_TIME` | Commented out, default `5h` | Every service | If you lower it, set `stop_grace_period` to the same value plus 5 minutes |
| `HTTPS_PROXY`, `NO_PROXY` | Commented out | Every service | Jobs inherit them |
| `MACHINE_RUNNER_SWARM_JOB_SUDO` | `"true"` or `"false"` | Linux | `"false"` makes the class hardened |
| `CIRCLECI_RUNNER_WORK_DIR`, `CIRCLECI_RUNNER_TASK_AGENT_DIRECTORY` | `C:\cci\w`, `C:\cci\agent` | Windows | Job working directory and task agent directory |
| `MACHINE_RUNNER_SWARM_INSTANCE_ID` | `{{.Task.ID}}` | Windows | Lets a job tell which container it ran in |
| `GIT_TERMINAL_PROMPT`, `GCM_INTERACTIVE`, `GIT_CONFIG_*` | `0`, `never`, and `core.longpaths=true` | Windows | Stop Git prompts, and allow long paths |
| `PATH` | The full Server Core path, then Git | Windows stock services | Replaces the image `PATH`, so the file spells it out |

Refer to the [machine runner 3 configuration reference](https://circleci.com/docs/guides/execution-runner/machine-runner-3-configuration-reference/) for every other `CIRCLECI_RUNNER_*` variable. Environment variables override the config file.

### Variables read by the Linux entrypoint

| Variable | Default | Notes |
|---|---|---|
| `MACHINE_RUNNER_SWARM_RUNNER_WAIT` | `120` | Seconds that the entrypoint waits for the link `current` of the distributor. Without it, the container exits with code 80 |
| `MACHINE_RUNNER_SWARM_JOB_USER` | `circleci` | The account that runs jobs. The entrypoint creates it with uid 2001 when the image has none |
| `MACHINE_RUNNER_SWARM_JOB_SUDO` | `true` | `false` removes every sudo right of the job user and steps jobs down with `setpriv --no-new-privs`, which needs util-linux `setpriv` in the image. Any other value, or a missing `setpriv`, exits with code 80 |

The runner user is `circleci-runner` with uid 2000. It owns the secret file and has no sudo rights.

The entrypoint always sets `CIRCLECI_RUNNER_COMMAND_PREFIX`: `["sudo","-niHu","<job user>","--"]`, or a `setpriv` command when the image has no sudo, and always a `setpriv --no-new-privs` command in a hardened class. It keeps a value that you set for three more: `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` (default `false`), `CIRCLECI_RUNNER_TASK_AGENT_DIRECTORY` (default `/var/lib/circleci-runner/agent`, owned by the runner user) and `CIRCLECI_RUNNER_WORK_DIR` (default `/var/opt/circleci/workdir`, owned by the job user; keep a custom directory under `/var/opt/circleci`).

Arguments that you pass to the entrypoint replace the default command, `machine --config /run/secrets/circleci_runner_config.yaml`.

### Variables read by the runner distributor

These are `docker stack deploy` variables. `x-distributor-env` in `linux/stack/runners.yaml` passes them to the `runner-distributor` service only. Refer to [Upgrade the runner on Linux](operations.md#upgrade-the-runner-on-linux).

| Variable | Default | Effect |
|---|---|---|
| `MACHINE_RUNNER_SWARM_RUNNER_VERSION` | An exact version, the newest that CI tests | An exact version pins it. `3.1`, `3` and `current` follow the manifest of CircleCI ([the version policy](operations.md#the-version-policy)) |
| `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` | `3` | The major version that `current` may adopt |
| `MACHINE_RUNNER_SWARM_CHECK_INTERVAL` | `24h` | How often a floating version looks at the manifest again: seconds, or a number with `s`, `m`, `h`, or `d` |
| `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` | `https://circleci-binary-releases.s3.amazonaws.com/circleci-runner` | Where `manifest.json` and the tarballs are, for example a mirror. It must be `https://`, unless a SHA-256 list is set |
| `MACHINE_RUNNER_SWARM_RUNNER_SHA256` | The tarball SHA-256 values of the pinned version | A comma-separated list for an exact pin. `manifest` means no list: the hash of the manifest is trusted, which is weaker. A floating value ignores any list |
| `MACHINE_RUNNER_SWARM_ALLOW_HTTP` | Not set | `true` accepts an `http://` download base without a SHA-256 list, for a lab |

### Stack keys on Windows

Not every key of a stack file reaches a Windows container.

| Effect | Keys |
|---|---|
| Used | `isolation`, bind mounts of directories, `npipe` mounts, named volumes (a `volume.subpath` may be a relative directory symbolic link, but not a junction or an absolute link), Swarm configs with an absolute target, secrets without `uid`, `gid`, and `mode`, `stop_grace_period`, `logging`, `entrypoint`, `environment` with Swarm placeholders, `labels`, `deploy.mode: global`, `deploy.placement`, `deploy.restart_policy`, `deploy.update_config`, `deploy.endpoint_mode`, and `deploy.resources.limits` for `cpus` and `memory` |
| Scheduler only | `deploy.resources.reservations`. The engine rejects a memory reservation, so Swarm never sends it |
| Rejected by the Windows engine | `deploy.resources.limits.pids` and `ulimits`, so the files do not set them. A `limits.cpus` above the CPU count of the host is rejected too |
| No effect | `init`, `cap_drop`, `cap_add`, `read_only`, `tmpfs`, and `sysctls` |
| Ignored by `docker stack deploy` on every platform | `security_opt`, `privileged`, `userns_mode`, `restart`, and `build` |

Three choices in the Windows files follow:

- **No `hostname`.** A Windows computer name has at most 15 characters, and a templated hostname would give every container of a slot the same `COMPUTERNAME`. Without it, `COMPUTERNAME` is the container ID.
- **`endpoint_mode: dnsrr`.** Nothing connects to a runner, so no virtual IP is needed.
- **Settings repeated per service.** YAML merge keys do not merge deeply. The idle timeout is set for each service, because the persistent class must not have one, and `windows-docker-build` repeats the `PATH` with `C:\docker` appended.

The log driver is `json-file` with rotation. The `local` driver also works on Windows.

### The secret

- **Linux, token proxy:** secret `<service>-token`, target `<service>-token`, at `/run/secrets/<service>-token` in the proxy, uid 65534, gid 65534, mode `0400`.
- **Linux, persistent runner and placeholder:** secret `<service>-token` (a proxied class uses `runner-placeholder-token`), target `circleci_runner_config.yaml`, at `/run/secrets/circleci_runner_config.yaml`, uid 2000, gid 2000, mode `0400`.
- **Windows:** secret `<service>-token`, target `circleci_runner_config.yaml`, at `C:\ProgramData\Docker\secrets\circleci_runner_config.yaml`. Windows supports no owner or mode: administrators and `SYSTEM` only.

The content is `api:` and `auth_token: <token>` (the placeholder holds a made-up token). The proxy also accepts a bare token. The entrypoint passes `--config <path>` to the runner, and environment variables override the file.

### Exit codes

| Code | Source | Meaning |
|---|---|---|
| 0 | Runner | A normal exit after a job or a runner drain. Swarm starts a new container |
| 80 | Entrypoint | A prerequisite is missing: the link `current` does not exist after the wait, the runner does not match its SHA-256 record, the runner or a directory above it is not root-owned or is writable, the image has neither sudo nor `setpriv` (or, for a hardened class, no util-linux `setpriv` with `--no-new-privs`), `MACHINE_RUNNER_SWARM_JOB_SUDO` is invalid, or the entrypoint cannot remove every sudo right of the job user |
| 80 | Runner | A configuration error: a missing or invalid name, an empty token, an unknown log level, or an invalid mode |
| 1 | Runner | The config file is missing because the secret is not attached, the YAML does not parse, or a duration is malformed |

Swarm restarts a container that exits with any code after 10 seconds. It never gives up and never backs off, so a configuration error repeats until you fix it ([Troubleshooting](troubleshooting.md#the-container-restarts-every-10-seconds)).
