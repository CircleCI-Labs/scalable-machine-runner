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
- An error that mentions `max replicas per node`: the SSH add-on runs one replica on each node, because a node has one host-mode port 54782. Add nodes, or lower `replicas`.

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
| `circleci-runner-entrypoint: error: ...` | The entrypoint found a missing prerequisite, or no runner. Refer to the Linux entries below |

**Fix.** Correct the stack file or the secret, and deploy again. To stop the loop meanwhile, run `docker service scale runners_<service>=0`.

The restart delay is a pause between starts, not a back-off. Swarm creates the replacement task at once and starts its container after the delay, so the containers start 10 to 12 seconds apart. A `max_attempts` value in `restart_policy` would end the loop, but then the runner never recovers by itself after you fix the cause, so the stack does not set it. Alert on exit code 80 instead.

### Error: secret not found

`docker stack deploy` fails with `secret not found: linux-java-token`.

**Cause.** A service references an external secret that does not exist. Every service in the file needs its `<service>-token` secret.

**Fix.** Create the secret, or delete the service from your copy of the stack file together with its entries under `secrets:` and `networks:`. On Windows, `runners.yaml` needs only `windows-default-token`, and each add-on stack file (`custom-image.yaml`, `persistent.yaml`, `docker-build.yaml`, `ssh-rerun.yaml`) needs its own `<service>-token` secret when you deploy it.

### The runner log shows 401

The log contains `401 (Unauthorized)`, and the runner never claims a job.

**Cause.** CircleCI rejected the token. The token was deleted, or the secret holds a token of another class or a mistyped one. A 401 is not a clock problem: a clock that drifted fails the TLS handshake before any request, which gives the error in the next entry.

**Fix.**

- Check that the secret `<service>-token` holds the token of the resource class with the same name as the service. A swapped token does not fail loudly. The runner serves the class of its token, so jobs of the intended class stay queued.
- Create a new token and rotate it. Refer to [Rotate a runner token](operations.md#rotate-a-runner-token).

### The runner log shows x509 certificate errors

The log contains `x509: certificate has expired or is not yet valid`, or `x509: certificate signed by unknown authority`, and the runner never connects.

**Cause.** The clock of the node drifted, so TLS to CircleCI fails silently as far as the job is concerned. Or an inspecting proxy re-signs the traffic with a CA that the container does not trust.

**Fix.** Check the clock with `timedatectl show -p NTPSynchronized --value`, which must print `yes`, and fix NTP on the node. For a proxy CA, add the CA to your image. Refer to [Do proxies and custom certificate authorities work?](faq.md#do-proxies-and-custom-certificate-authorities-work).

### Jobs queue but no runner claims them

**Cause.** The `resource_class` in the config does not match a class that has running replicas, or the replicas cannot reach CircleCI.

**Fix.**

1. Check that `<namespace>/<class>` in the job config equals the namespace and the service name.
2. Check the inventory under **Runners** in the web app. If the replicas are missing, check that the tasks run and that the egress rules allow the hosts in [Egress hosts](security.md#egress-hosts).
3. Check that jobs are not in a class that has `replicas: 0`.

### Jobs wait while the runners are idle

The runner inventory shows idle runners, and jobs stay queued.

**Cause.** The inventory shows running tasks only. Queued tasks are invisible there, and they count against concurrency. A class can sit at the `maxConcurrentTasks` limit of the resource class (20 by default) or at the runner concurrency of your plan, and jobs for a class that has no runner queue forever and hold concurrency.

**Fix.** Ask the runner API how many tasks wait, and compare it with the replicas:

```console
$ curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" \
    "https://runner.circleci.com/api/v3/runner/tasks?resource-class=<namespace>/<class>"
```

A count above 0 with idle replicas points at a limit or at a class name that no service serves. Cancel the tasks of a class that no longer has runners, and ask CircleCI support to raise `maxConcurrentTasks`. Refer to [Capacity and concurrency](operations.md#capacity-and-concurrency).

### A service shows no logs

`docker service logs runners_<service>` prints nothing, or prints less than you expect.

**Cause.** Swarm prunes the old tasks of a slot, and their logs go with them, because every finished job ends a task and the history limit is 2. The command also works only for the `local`, `json-file`, and `journald` drivers, so a service that you moved to a shipping driver has no logs to read back.

**Fix.** Read `docker service ps --no-trunc runners_<service>` for the reason a task ended, and `docker logs <container>` on the node for a task that still has its container. To keep logs, ship them. Refer to [Ship the logs](operations.md#ship-the-logs).

### Error: The swarm does not have a leader

A Swarm command fails with `The swarm does not have a leader. It's possible that too few managers are online.`

**Cause.** The managers lost their quorum. A majority of them must be online: two of three, or three of five. Without it, running jobs finish, but no replacement task starts, so the capacity of the cluster drops to zero.

**Fix.** Bring the managers back, starting with the ones that were stopped last, and check `docker node ls` on a reachable manager. A manager that is locked needs `docker swarm unlock`. If the managers are lost for good, recover the cluster from one surviving manager with `docker swarm init --force-new-cluster`. Refer to [Back up the managers, and recover](operations.md#back-up-the-managers-and-recover) and [Managers and quorum](multi-node.md#managers-and-quorum).

### Error: Swarm is encrypted and needs to be unlocked

A Swarm command fails with `Swarm is encrypted and needs to be unlocked before it can be used`.

**Cause.** The managers use autolock, and this manager restarted. It stays out of the cluster until someone unlocks it.

**Fix.** Run `docker swarm unlock` on the manager and enter the unlock key. Get the key from a manager that is unlocked with `docker swarm unlock-key`. Refer to [Unlock a locked swarm](operations.md#unlock-a-locked-swarm).

### A service update is paused or rolled back

`docker service update` or `docker stack deploy` stops partway, and `docker service inspect --format '{{.UpdateStatus.State}}' runners_<service>` prints `paused`, `rollback_started`, or `rollback_completed`. The `Message` field says which task failed.

**Cause.** A new task failed to start, for example with exit code 80 after a wrong setting or a missing secret. The stack files set no `failure_action`, so Swarm pauses the update at the first failure, and the replicas that it did not reach keep the old version.

**Fix.** Read why the task failed with `docker service ps --no-trunc runners_<service>`, correct the cause in your stack file, and deploy again with the same list of files. To go back at once, run `docker service update --rollback runners_<service>`. Refer to [Update the images](operations.md#update-the-images).

### A job exits with code 137, or fails to start processes

A task or a step ends with exit code 137, or a build fails with `fork: Resource temporarily unavailable` or `Cannot allocate memory`.

**Cause.** Code 137 is SIGKILL. On Linux the kernel kills a job that exceeds the memory limit of the service, and `docker inspect <container>` shows `OOMKilled: true`. The same code appears when a stop outlasts `stop_grace_period`. A build that starts more processes than `limits.pids` (4096) fails to fork.

**Fix.** Raise `limits.memory` or `limits.pids` of that class in your stack file, and deploy again. Size the class for its largest job, and keep the reservation equal to the limit. Refer to [Size the limits](resource-classes.md#size-the-limits). A job that runs near its limit also needs room on the node.

### A job fails with an issue with your infrastructure

The job ends with a message that points at an issue with your infrastructure, and its log stops without an error of its own.

**Cause.** The runner stopped while it ran the job, or its connection to CircleCI broke. Typical causes are a node that died or rebooted, a stop from outside (an update, a scale-down, or a node drain) that outlasted the grace period or, on Windows, killed the job after about 5 seconds, or an out-of-memory kill.

**Fix.** Find the container that ran the job with `docker service ps --no-trunc runners_<service>`: a task that ended with `non-zero exit` or on a node that is `Down` names the cause. Self-hosted runners do not retry a job, so rerun it. Refer to [Node death](operations.md#node-death) and [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

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

### The runner waits for the distributor, and then exits with code 80

The log of a runner container shows `circleci-runner-entrypoint: waiting for the runner-distributor of this node to install the runner`. After the wait, which is 120 seconds by default, the container exits with code 80 and the message `/opt/machine-runner-swarm/current is 'missing': the runner-distributor of this node has not installed the runner`. Swarm starts a new container after 10 seconds, and the loop repeats.

**Cause.** The volume `runner-bin` of the node has no runner yet. The `runner-distributor` task of the node is not running, or it cannot download the runner, or it refuses the download. A first deploy and a node that just joined are normal: the wait covers a download of a few seconds, and the next container starts as soon as `current` exists.

**Fix.** Check that the distributor runs on that node, and read its log. Each line starts with the task and the node.

```console
$ docker service ps --no-trunc runners_runner-distributor
$ docker service logs --tail 50 runners_runner-distributor
```

A node that has no task is `Down`, drained, or not a Linux node. Otherwise the log names the problem: refer to [The distributor log shows cannot download](#the-distributor-log-shows-cannot-download) and [The distributor log shows SHA-256 mismatch](#the-distributor-log-shows-sha-256-mismatch). To wait longer, set `MACHINE_RUNNER_SWARM_RUNNER_WAIT` in the environment of the runner services.

### Error: does not match its SHA-256 record

The container exits with code 80 and a message such as `/opt/machine-runner-swarm/versions/3.1.13/bin/circleci-runner does not match its SHA-256 record ...: refusing to start`.

**Cause.** The binary in the volume is not the one that the distributor recorded. The install is incomplete, the volume was changed, or the disk is damaged. The entrypoint checks the binary at every start and never runs one that differs. Refer to [Runner binary integrity on Linux](security.md#runner-binary-integrity-on-linux).

**Fix.** The distributor compares the active binary with its record at every check, and installs the version again when it differs. To do it now, force an update of the distributor. It downloads the version again on every node, and the next containers start:

```console
$ docker service update --force runners_runner-distributor
```

If the binary changes again, find out what writes to the volume: a privileged container on the node, or a person with access to it.

### The distributor log shows cannot download

A line of `docker service logs runners_runner-distributor` reads `runner-distributor: cannot download <address>`, for the file `manifest.json` or for a tarball such as `<version>/circleci-runner_linux_amd64.tar.gz`. The distributor keeps the runner that it has and tries again in 5 minutes. Without a runner, the runner containers of the node end in the entry above.

**Cause.** The node cannot reach `circleci-binary-releases.s3.amazonaws.com` or your mirror: an egress rule, a proxy, DNS, or the clock. Or the file is not on the mirror, for example the version that you pinned. An `https` mirror needs a certificate from a public certificate authority, because the distributor uses the CA bundle of the stock Alpine image.

**Fix.** Download the same file from the node with the same tool:

```console
$ docker run --rm alpine wget -q -O /dev/null https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/manifest.json && echo reachable
```

Open the host in [Egress hosts](security.md#egress-hosts), or fix the mirror. Refer to [Run the downloads from a mirror](operations.md#run-the-downloads-from-a-mirror).

### The distributor log shows SHA-256 mismatch

A line reads `runner-distributor: SHA-256 mismatch for circleci-runner_linux_amd64.tar.gz <version>: got <hash>, wanted <hash>: refusing to install`. The distributor installs nothing and tries again later.

**Cause.** The tarball does not have the SHA-256 that the manifest, or your list in `MACHINE_RUNNER_SWARM_RUNNER_SHA256`, names. The usual causes are a list that lacks the value of one architecture (a fleet with amd64 and arm64 nodes needs both), a mirror whose tarball and manifest do not belong together, and a proxy that changes the download.

**Fix.** Compare `wanted` with the SHA-256 of the file that you expect, from the `checksums.txt` of the release or from the manifest. Correct the list, the mirror, or the proxy. Never copy the `got` value into the list without checking where the file came from.

### The distributor log shows not adopting it

The log has `runner-distributor: current is <version> (major <n>), not 3: not adopting it (MACHINE_RUNNER_SWARM_RUNNER_MAJOR)`, or `current has SHA-256 <hash>, which no versioned release of the manifest has: not adopting it`.

**Cause.** The first line says that `current` of CircleCI moved to another major version. The distributor keeps the version that it has, so nothing breaks, and the nodes stay where they are. The second line says that the manifest names no version for `current`, which happens with a mirror that has an old or edited `manifest.json`.

**Fix.** For a new major version, read the changelog of the runner, try it, and then set `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` or pin the version. Refer to [Pin a version](operations.md#pin-a-version). For the second line, copy `manifest.json` to the mirror again, with the tarball of the version that `current` names.

### Error: must be owned by root and not group/world writable

The container exits with code 80 and a message such as `/opt/machine-runner-swarm/versions/3.1.13/bin/circleci-runner must be owned by root and not group/world writable`.

**Cause.** The entrypoint refuses to run a runner that the job user or the runner user can replace. The distributor makes the files of the volume owned by root with the mode `0755`, so something changed them.

**Fix.** On the node, set the owner and the mode again:

```console
$ docker run --rm -v runners_runner-bin:/v alpine sh -c 'chown -R 0:0 /v && chmod -R go-w /v'
```

### Error: jobs cannot be stepped down in this image

The container exits with code 80 and the message `jobs cannot be stepped down in this image: it needs sudo or util-linux setpriv`.

**Cause.** The image has neither `sudo` nor util-linux `setpriv`, or it has no `setpriv` and no `su` to start the runner.

A hardened class (`MACHINE_RUNNER_SWARM_JOB_SUDO=false`) exits with code 80 and the message `needs util-linux setpriv with --no-new-privs` when the image has no util-linux `setpriv`, even if it has sudo. The hardened class never steps jobs down with sudo, because a setuid binary could then lift a job to root.

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

On RHEL, a replica reports `Permission denied` for files under `/opt/machine-runner-swarm` while SELinux is enforcing.

**Cause.** Untested: this repository's CI does not run on RHEL. The runner is in a named volume, and Docker labels the files of a volume for containers in the usual case. A setup where it does not leaves the files with a type that containers may not read. A Swarm service mount has no `:z` option to relabel them.

**Fix.** Confirm the denial with `sudo ausearch -m avc -ts recent`, then label the volume on the node. The files that the distributor writes later inherit the label.

```console
$ sudo chcon -R -t container_file_t /var/lib/docker/volumes/runners_runner-bin/_data
```

Keep SELinux enforcing. Do not disable it to work around the error, and open an [issue](https://github.com/CircleCI-Labs/scalable-machine-runner/issues) with the `avc` line if you needed this.

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

### Permission denied on the Docker socket in a docker-build job

A job on a docker-build class fails with `permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock`.

**Cause.** The entrypoint adds the job user to the group of the mounted socket so that the job can use it, but it skips a socket whose group id is 0, because group 0 is root's group and giving the job user that group would be wrong. A host whose socket is owned by `root:root` therefore leaves the job user without access.

**Fix.** Give the socket on the host a group that is not root, normally `docker`. With systemd, the socket unit of Docker sets it with `SocketGroup=docker`. Check with `stat -c '%U:%G %g' /var/run/docker.sock`, which must show a group id above 0, and deploy again so that the new containers pick it up. Refer to [Docker Builds](docker-builds.md).

### The disk fills up

**Cause.** Each finished job leaves a stopped container, and Swarm keeps the last five tasks of every slot by default.

**Fix.** Lower the history and prune. Refer to [Free disk space](operations.md#free-disk-space).

## Windows

### Error: 0xc0370101

A task is rejected with `The container operating system does not match the host operating system`.

**Cause.** The image build is newer than the host build. A Server 2022 host runs only `ltsc2022` images, and a Server 2025 host runs `ltsc2025` and `ltsc2022` images. The placement labels normally keep a service off a node that cannot run its image, so look for a node that carries a label it should not.

**Fix.** Use an image tag that the host can run, and label the node with the matching `machine-runner-swarm.windows-ltsc2022` and `windows-ltsc2025` capabilities. Refer to [Image tags and host builds](install-windows.md#image-tags-and-host-builds).

### The runner never claims a job

The container runs and logs the start-up lines, but the runner never claims a job and logs no clear error.

**Cause.** The runner creates a symbolic link when it installs the task agent. Without the `SeCreateSymbolicLinkPrivilege`, it retries the download forever. This happens when the container runs as a user other than `ContainerAdministrator`.

**Fix.** Never set `user:` in a Windows service, and never change `USER` in a derived image.

### The Windows runner fails to start: cannot access path current

`docker service ps --no-trunc runners_windows-default` shows tasks that fail with `cannot access path ...\runner-bin\_data\current` (or `...\git\current`) or with `invalid mount config`, and Swarm starts the next task after 10 seconds.

**Cause.** The service `runner-distributor-windows` has not flipped the links `current` and `git\current` of the volume on this node yet. This is normal on a new node, because the first download of the runner and of portable Git takes a few minutes. It lasts when the distributor cannot install.

**Fix.** Read the log of the distributor: `docker service logs runners_runner-distributor-windows`. A `SHA-256 mismatch`, a `cannot download` line, or `not adopting it` names the cause. The service must run on the node: `docker service ps runners_runner-distributor-windows` needs a task there, so the node must carry the label `machine-runner-swarm.windows-ltsc2022=true`, and the base image must be pulled. On a host behind a proxy, set `HTTPS_PROXY` on the distributor service. For a site without internet access, refer to [Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows).

### The distributor of Windows keeps a version that should be gone

The log says `circleci-runner <version> is in use: removing it at a later check`.

**Cause.** Windows cannot remove files that a running container uses. A job on that version is still running.

**Fix.** None needed: the distributor removes the version at a later check, when the job has ended.

### Error: could not find the system's IP address

`docker swarm init` fails with `could not find the system's IP address - specify one with --advertise-addr`.

**Fix.** Always pass the IPv4 address of the host: `docker swarm init --advertise-addr <host IPv4 address>`. A host with several network adapters needs it too, and `Setup.ps1 -InitSwarm` requires `-AdvertiseAddr`.

### Downloads fail right after docker swarm init

Outbound connections fail with `Unable to connect to the remote server` or `no such host` for a few seconds after you create the swarm.

**Fix.** Pull the images first, and run `docker swarm init` last. The distributor retries its downloads.

### Windows container exits with code 3221225786 after a stop

A job ends about 5 seconds after a rolling update, a scale down, a node drain, or `docker stop`. `docker service ps --no-trunc` shows `task: non-zero exit (3221225786)`, which is `0xC000013A`.

**Cause.** The container was stopped from outside while it ran a job, and Windows gives a stock Server Core container about 5 seconds, whatever `stop_grace_period` says. A job that finishes by itself does not end this way.

**Fix.** Rerun the interrupted jobs, and change a service only while its class runs no job. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

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

**Fix.** Use a Server 2022 or 2025 host. Server 2019 is untested: the stack files have no label or placement for it, so a 2019 node needs your own image tag, label, and constraint.

## Collect information for a bug report

Gather the output of these commands. Remove tokens before you share it.

```console
$ docker version
$ docker node ls
$ docker stack ps runners --no-trunc
$ docker service logs --tail 200 runners_<service>
```

On Linux, include the runner version and the log of the distributor: `docker run --rm -v runners_runner-bin:/v:ro alpine cat /v/current/VERSION` on the node, and `docker service logs --tail 100 runners_runner-distributor`. On Windows, include the log of `runner-distributor-windows`: `docker service logs --tail 100 runners_runner-distributor-windows`. Then open an [issue](https://github.com/CircleCI-Labs/scalable-machine-runner/issues).
