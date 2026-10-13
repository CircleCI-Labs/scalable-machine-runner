---
page-title: Troubleshooting
page-audience: admin
page-description: Symptoms, causes, and fixes for the Docker Swarm runner stack on Linux and Windows, with the error text to search for.
---

# Troubleshooting

This page lists symptoms with their cause and fix. Start with the state of the tasks and the runner output:

```console
$ docker stack ps runners --no-trunc
$ docker service logs --tail 100 runners_<service>
```

For the shared CircleCI guidance, refer to [Troubleshoot self-hosted runner](https://circleci.com/docs/guides/execution-runner/troubleshoot-self-hosted-runner/).

## General

### A task stays pending

The `ERROR` column of `docker service ps --no-trunc runners_<service>` shows `no suitable node`, and the task stays in the `Pending` state.

**Cause.** No node satisfies the task.

- `scheduling constraints not satisfied on N nodes`: no node matches the constraints. A label is missing, the OS or architecture differs, or the service needs a worker and the label sits on a manager.
- `insufficient resources on N nodes`: the reservations of the replicas exceed what the matching nodes have free. Reservations equal the limits, so extra replicas wait on purpose.

**Fix.** Compare the constraints of the service with the labels of the nodes.

```console
$ docker service inspect --format '{{ json .Spec.TaskTemplate.Placement }}' runners_<service>
$ docker node inspect --format '{{ .Description.Hostname }} {{ .Spec.Labels }}' $(docker node ls -q)
```

Add the missing label with `docker node update --label-add`, lower `replicas`, or lower the reservations. Refer to [Labels and constraints](multi-node.md#labels-and-constraints).

### The container restarts every 10 seconds

`docker service ps` lists many tasks of one slot, each with `task: non-zero exit (80)` or `(1)`, started about 10 seconds apart.

**Cause.** The runner or the entrypoint exits at start-up because of a configuration error. Swarm restarts the container after the restart delay. It never gives up and never backs off, so the loop runs until you fix the cause. The log line names the problem:

| Log text | Cause |
|---|---|
| `api.auth_token must be set` | The secret has an empty token, or the wrong structure |
| `runner.name must be set` | `CIRCLECI_RUNNER_NAME` is missing |
| `runner.name must contain only letters, numbers, .()_-, and spaces` | The name has other characters, or exceeds 64 characters because of a long hostname or class name |
| `--runner.mode must be one of "continuous","single-task"` | `CIRCLECI_RUNNER_MODE` has another value |
| `error parsing config file`, or a missing file (exit code 1) | The secret is not valid YAML, or it is not attached with the target `circleci_runner_config.yaml` |
| `circleci-runner-entrypoint: error: ...` | The entrypoint found a missing prerequisite. Refer to the Linux entries below |

**Fix.** Correct the stack file or the secret, and deploy again. To stop the loop meanwhile, run `docker service scale runners_<service>=0`.

The restart delay is a pause between starts, not a back-off. Swarm creates the replacement task at once and starts its container after the delay, so the containers start 10 to 12 seconds apart. A `max_attempts` value in `restart_policy` would end the loop, but then the runner never recovers by itself after you fix the cause, so the stack does not set it. Alert on exit code 80 instead.

### Error: secret not found

`docker stack deploy` fails with `secret not found: linux-java-token`.

**Cause.** A service references an external secret that does not exist. Every service in the file needs its `<service>-token` secret.

**Fix.** Create the secret, or delete the service from your copy of the stack file together with its entries under `secrets:` and `networks:`. On Windows, `runners.yaml` needs only `windows-default-token`, and each overlay file (`custom-image.yaml`, `persistent.yaml`, `docker-build.yaml`) needs its own `<service>-token` secret when you deploy it.

### The runner log shows 401

The log contains `401 (Unauthorized)`, and the runner never claims a job.

**Cause.** CircleCI rejects the token. The token was deleted, the secret holds a token of another class, or the clock drifted.

**Fix.**

- Check that the secret `<service>-token` holds the token of the resource class with the same name as the service. A swapped token does not fail loudly. The runner serves the class of its token, so jobs of the intended class stay queued.
- Check the clock with `timedatectl show -p NTPSynchronized --value`. TLS to CircleCI fails silently when the clock drifts.
- Create a new token and rotate it. Refer to [Rotate a runner token](operations.md#rotate-a-runner-token).

### Jobs queue but no runner claims them

**Cause.** The `resource_class` in the config does not match a class that has running replicas, or the replicas cannot reach CircleCI.

**Fix.**

1. Check that `<namespace>/<class>` in the job config equals the namespace and the service name.
2. Check the inventory under **Runners** in the web app. If the replicas are missing, check that the tasks run and that the egress rules allow the hosts in [Egress hosts](security.md#egress-hosts).
3. Check that jobs are not in a class that has `replicas: 0`.

### A task is rejected because the image cannot be pulled

`docker service ps` shows `rejected` with `No such image` or an authentication error.

**Cause.** The node cannot pull the image: the registry is not reachable, the image is private, or the registry rate limit applies.

**Fix.** Check egress to the registry, deploy with `docker stack deploy --with-registry-auth` for a private registry, and use a mirror or authenticated pulls. Refer to [Registry needs](multi-node.md#registry-needs).

### Error: This node is not a swarm manager

Swarm commands such as `docker stack deploy` fail on a worker.

**Fix.** Run them on a manager. Use `docker node ls` on a manager to list the managers.

### A node cannot join the swarm

`docker swarm join` times out or fails with a connection error.

**Cause.** The manager is not reachable on the advertised address and port 2377, or the manager listens on the loopback address only.

**Fix.** Open the ports in [Inter-node ports](multi-node.md#inter-node-ports), and check that the swarm was initialized with a routable `--advertise-addr`.

## Linux

### Error: bind source path does not exist

A task is rejected with `invalid mount config for type "bind": bind source path does not exist: /opt/machine-runner-swarm/current`.

**Cause.** The node has no `/opt/machine-runner-swarm/current` link, because the runner is not installed there, or the link points to a version that was deleted.

**Fix.** Install the runner and the entrypoint on that node. Refer to [Install the runner and the entrypoint](install-linux.md#3-install-the-runner-and-the-entrypoint).

### Error: must be owned by root and not group/world writable

The container exits with code 80 and a message such as `/opt/machine-runner-swarm/bin/circleci-runner must be owned by root and not group/world writable`.

**Cause.** The entrypoint refuses to run a runner that the job user or the runner user can replace.

**Fix.** On the node, run `sudo chown -R root:root /opt/machine-runner-swarm` and `sudo chmod -R go-w /opt/machine-runner-swarm`.

### Error: jobs cannot be stepped down in this image

The container exits with code 80 and the message `jobs cannot be stepped down in this image: it needs sudo or util-linux setpriv`.

**Cause.** The image has neither `sudo` nor util-linux `setpriv`, or it has no `setpriv` and no `su` to start the runner.

**Fix.** Add the packages in a derived image. Refer to [What an image needs](images.md#what-an-image-needs).

### Error: could not remove every sudo right

A hardened class exits with code 80 and `could not remove every sudo right of <user>; check /etc/sudoers and /etc/sudoers.d`.

**Cause.** The image grants sudo to the job user in a way that the entrypoint cannot remove. The entrypoint deletes only the rules whose first entry is the user, one of its groups, its numeric ID, or `ALL`. A rule that comes through a user alias, or from a list where the user is not first, such as `other,circleci ALL=...`, stays. The container refuses to start rather than run with sudo.

**Fix.** Remove the rule in a derived image, or use an image that does not grant sudo.

### Error: failed to remove working directory, permission denied

Every task fails. The runner log shows `failed to remove working directory before starting task` or `failed to remove working directory while cleaning up task`, each with `permission denied`. A `could not clean up task` line with the same error has the same cause.

**Cause.** This happens only if someone sets `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` to `true` on a Linux service: the entrypoint and the stack files default it to `false`. The runner removes its working directory itself, as the runner user (uid 2000), but the job user owns that directory and its files. The removal fails even for the first task, because the parent directory belongs to the job user too. The stack files and the entrypoint set the variable to `false` for this reason.

**Fix.** Set `CIRCLECI_RUNNER_CLEANUP_WORK_DIR: "false"`, or remove the variable so that the entrypoint default applies, and deploy again. A single-task container is discarded after the job, so nothing is lost. In a persistent class, start every job with a step that removes what an earlier job left. Refer to [Working directory cleanup](security.md#working-directory-cleanup).

### Permission denied on /opt/machine-runner-swarm with SELinux

On RHEL, a task fails or the runner reports `Permission denied` for files under `/opt/machine-runner-swarm` while SELinux is enforcing.

**Cause.** The Docker daemon has SELinux support enabled, and the files in `/opt/machine-runner-swarm` have a type that containers may not read. This repository's CI does not run on RHEL, so verify the fix on your host.

**Fix.** Label the directory for containers.

```console
$ sudo semanage fcontext -a -t container_file_t '/opt/machine-runner-swarm(/.*)?'
$ sudo restorecon -Rv /opt/machine-runner-swarm
```

Keep SELinux enforcing. Do not disable it to work around the error.

### Warning: sudo unable to send audit message

Every `sudo` call in a job prints `unable to send audit message`.

**Cause.** The `AUDIT_WRITE` capability is dropped.

**Fix.** Keep `AUDIT_WRITE` out of `cap_drop`. A hardened class keeps it in `cap_add`.

### Jobs in the hardened class cannot install packages

`apt-get install` fails with `Permission denied`, or `sudo` reports that the user may not run sudo.

**Cause.** The hardened class has no sudo, by design.

**Fix.** Build the tools into the image. Refer to [Bring your own image](images.md#linux-bring-your-own-image).

### Cannot connect to the Docker daemon in a job

`docker build` fails with `Cannot connect to the Docker daemon`.

**Cause.** The class does not mount a Docker engine, by design.

**Fix.** Use the opt-in class, or a daemonless builder. Refer to [Docker Builds](docker-builds.md).

### The disk fills up

**Cause.** Each finished job leaves a stopped container, and Swarm keeps the last five tasks of every slot by default.

**Fix.** Lower the history and prune. Refer to [Free disk space](operations.md#free-disk-space).

## Windows

### Error: 0xc0370101

A task is rejected with `The container operating system does not match the host operating system`.

**Cause.** The image build does not match the host build. A Server 2022 host runs only `ltsc2022` images.

**Fix.** Use an image tag that the host can run, and label the node with the matching `machine-runner-swarm.windows-build` value. Refer to [Image tags and host builds](install-windows.md#image-tags-and-host-builds).

### The runner never claims a job

The container runs and logs the start-up lines, but the runner never claims a job and logs no clear error.

**Cause.** The runner creates a symbolic link when it installs the task agent. Without the `SeCreateSymbolicLinkPrivilege`, it retries the download forever. This happens when the container runs as a user other than `ContainerAdministrator`.

**Fix.** Never set `user:` in a Windows service, and never change `USER` in a derived image.

### Access is denied on C:\machine-runner-swarm

Starting `C:\machine-runner-swarm\bin\circleci-runner.exe` in a container fails with `Access is denied`, or reading `C:\machine-runner-swarm\VERSION` fails on the host.

**Cause.** Files under `C:\machine-runner-swarm` have no usable access control list. The recursive `icacls` call can leave files with an empty list.

**Fix.** Let every file inherit the access of the directory.

```powershell
icacls 'C:\machine-runner-swarm\*' /reset /T /C /Q
```

### Error: could not find the system's IP address

`docker swarm init` fails with `could not find the system's IP address - specify one with --advertise-addr`.

**Fix.** Always pass the IPv4 address of the host: `docker swarm init --advertise-addr <host IPv4 address>`. A host with several network adapters needs it too, and `Setup.ps1 -InitSwarm` requires `-AdvertiseAddr`.

### Downloads fail right after docker swarm init

Outbound connections fail with `Unable to connect to the remote server` or `no such host` for a few seconds after you create the swarm.

**Fix.** Stage `C:\machine-runner-swarm` and pull the images first, and run `docker swarm init` last. `Setup.ps1` stages before it starts Swarm.

### Windows container exits with code 3221225786 after a stop

A job ends about 5 seconds after a rolling update, a scale down, a node drain, or `docker stop`. `docker service ps --no-trunc` shows `task: non-zero exit (3221225786)`, which is `0xC000013A`.

**Cause.** The container was stopped from outside while it ran a job. After the shutdown event, Windows waits only the time in the registry value `WaitToKillServiceTimeout` before it ends the processes of the container. The default is 5 seconds, whatever `stop_grace_period` says, so the runner and its job die before the drain ends. A job that finishes by itself does not end this way.

**Fix.** Rerun the interrupted jobs, and change a service only while its class runs no job. Refer to [Windows drain](operations.md#windows-drain), which also shows an optional image of your own that lifts the limit.

### Error: hcs::System::Start: context deadline exceeded

A Windows container does not start, and `docker service ps --no-trunc` shows `hcs::System::Start: context deadline exceeded`.

**Cause.** One cause is an image build that replaced a registry key. `New-Item -Force` on an existing key deletes its values and subkeys. On `HKLM:\SYSTEM\CurrentControlSet\Services\cexecsvc`, it removes the definition of the container exec service, and the container cannot start.

**Fix.** Rebuild the image, and set registry values with `reg add` or `Set-ItemProperty`, which only set a value. Never use `New-Item -Force` on an existing registry key.

### Workspaces fail because tar or gzip is missing

`persist_to_workspace` or `attach_workspace` reports a missing `tar` or `gzip`.

**Cause.** The Git mount is missing, or the `PATH` of the service does not include `C:\Program Files\Git\usr\bin`. The `PATH` of a service replaces the one of the image.

**Fix.** Keep both mounts and the full `PATH` from the shipped file.

### tar fails with Cannot stat when you test it by hand

You run `C:\Program Files\Git\usr\bin\tar.exe` in a container with a backslash path, and it fails with `Cannot stat`.

**Cause.** The task agent starts this `tar.exe` from the root of the drive, with `--force-local`, and with forward-slash operands that are relative to the root. For `C:\cci\w\ws`, it passes `cci/w/ws`. It never passes a backslash operand, which this tar does not accept.

**Fix.** Use the same form in your test. A workspace step that fails in a job is more likely a missing `tar` or `gzip` on the `PATH`, as in the previous entry.

### Overlay network creation fails

**Cause.** On a host with one network adapter, an existing `transparent` network can block the creation of overlay networks.

**Fix.** Refer to the Microsoft documentation on Windows container networking, and move the transparent network to a second adapter or remove it.

### The first task on a host takes a long time

**Cause.** The node pulls the Server Core image, which is about 2.2 GB compressed, when the first task lands there.

**Fix.** Run `docker pull` for the image on each node before you deploy.

### Setup.ps1 reports CHECK windows-server FAIL

**Cause.** The helper supports Windows Server 2022 (build 20348) and 2025 (build 26100), and the host is another version or a client edition.

**Fix.** On Server 2019, use the manual steps and the `ltsc2019` image tag. This repository does not test Server 2019.

## Collect information for a bug report

Gather the output of these commands. Remove tokens before you share it.

```console
$ docker version
$ docker node ls
$ docker stack ps runners --no-trunc
$ docker service logs --tail 200 runners_<service>
```

Include the contents of `/opt/machine-runner-swarm/current/VERSION` or `C:\machine-runner-swarm\current\VERSION`, and open an [issue](https://github.com/CircleCI-Labs/scalable-machine-runner/issues).
