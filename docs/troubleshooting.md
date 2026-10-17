---
page-title: Troubleshooting
page-audience: admin
page-description: Symptoms, causes and fixes for the Docker Swarm runner stack on Linux and Windows, with the error text to search for.
---

# Troubleshooting

Each entry gives the symptom, the cause and the fix. After a quickstart, find your symptom here first:

| You see | Do this |
|---|---|
| `runners_linux-default` shows `1/2` | Run `docker service ps --no-trunc runners_linux-default`. If the error says `insufficient resources`, run one replica: `sudo docker service scale runners_linux-default=1` ([A task stays pending](#a-task-stays-pending)) |
| `runners_token-proxy` shows `0/1` | Run `docker service ps --no-trunc runners_token-proxy`. A `no suitable node` error means no node matches its placement: by default it needs a manager, and with `MACHINE_RUNNER_SWARM_PROXY_PLACEMENT` it needs an active node with that label. A node with the label `machine-runner-swarm.proxy` runs no runner services |
| The CLI lists no instance | Run `docker service logs --tail 50 runners_linux-default`, then see [The runner log shows 401](#the-runner-log-shows-401) and [x509 certificate errors](#the-runner-log-shows-x509-certificate-errors) |
| The job stays `Queued` | The class name must equal `<NAMESPACE>/linux-default`, and your plan needs free runner concurrency ([Jobs wait while the runners are idle](#jobs-wait-while-the-runners-are-idle)) |

For anything else, start with the task state and the runner output:

```bash
docker stack ps runners --no-trunc
docker service logs --tail 100 runners_<SERVICE>
```

For CircleCI guidance shared by all runners, refer to [Troubleshoot self-hosted runner](https://circleci.com/docs/guides/execution-runner/troubleshoot-self-hosted-runner/).

## General

### A task stays pending

Symptom: the `ERROR` column of `docker service ps --no-trunc runners_<SERVICE>` shows `no suitable node`.

**Cause.** No node satisfies the task.

- `scheduling constraints not satisfied on N nodes`: a label is missing, the OS or architecture differs, or the service needs a worker and the label sits on a manager.
- `insufficient resources on N nodes`: the reservations exceed what the matching nodes have free. Reservations equal the limits, so extra replicas wait on purpose.
- `max replicas per node`: the SSH add-on runs one replica on each node, because a node has one host-mode port 54782.

**Fix.** Compare the constraints of the service with the labels of the nodes. Then add the label (`docker node update --label-add`), add nodes, lower `replicas`, or lower the reservations ([Labels and constraints](multi-node.md#labels-and-constraints)).

```bash
docker service inspect --format '{{ json .Spec.TaskTemplate.Placement }}' runners_<SERVICE>
docker node inspect --format '{{ .Description.Hostname }} {{ .Spec.Labels }}' $(docker node ls -q)
```

### The container restarts every 10 seconds

Symptom: `docker service ps` lists many tasks of one slot, each with `task: non-zero exit (80)` or `(1)`, started 10 to 12 seconds apart.

**Cause.** The runner or the entrypoint exits at start-up on a configuration error. Swarm restarts the container after 10 seconds and never gives up, so the loop runs until you fix the cause. The stack sets no `max_attempts`, because the runner would then never recover by itself: alert on exit code 80 instead. The log line names the problem:

| Log text | Cause |
|---|---|
| `api.auth_token must be set` | The secret has an empty token, or the wrong structure |
| `runner.name must be set` | `CIRCLECI_RUNNER_NAME` is missing |
| `runner.name must contain only letters, numbers, .()_-, and spaces` | Other characters, or more than 64 (long hostname or class name) |
| `--runner.mode must be one of "continuous","single-task"` | `CIRCLECI_RUNNER_MODE` has another value |
| `error parsing config file`, or a missing file (exit code 1) | The secret is not valid YAML, or not attached with the target `circleci_runner_config.yaml` |
| `circleci-runner-entrypoint: error: ...` | A missing prerequisite or runner: see the Linux entries |

**Fix.** Correct the stack file or the secret and deploy again. To stop the loop meanwhile:

```bash
docker service scale runners_<SERVICE>=0
```

### The runner log shows 401

Symptom: the log contains `401 (Unauthorized)` and the runner never claims a job.

**Cause.** CircleCI rejected the token: it was deleted, mistyped, or belongs to another class. A drifted clock is not a 401: it fails the TLS handshake first (see the x509 entry).

**Fix.** Check that the secret `<SERVICE>-token` holds the token of the class with the same name as the service. A swapped token does not fail loudly: the runner serves the class of its token, so jobs of the intended class stay queued. The token of a single-task class is in the proxy: look in `runners_token-proxy` (Windows: `runners_token-proxy-windows`) for `upstream status 401`. Then [rotate the token](operations.md#rotate-a-runner-token).

### The runner log shows 403 and the proxy log says refused

Symptom: the runner log has `403 (Forbidden)` for the claim, and `runners_token-proxy` says `claim from <IP_ADDRESS> refused`.

**Cause.** The proxy answers a claim only from an address that Swarm DNS lists now for `tasks.<SERVICE>` of a class it serves, once for each container. The log line gives the reason.

**Fix.**

- `not a runner of any class`: the class is not in the proxy (a new class needs its secret and, on Linux, its network under `token-proxy`: [Define a class](resource-classes.md#define-a-class)), the proxy is not on the class network, or the caller is not a runner.
- `this runner has already claimed a task`: the proxy restarted while the runner was idle, moved to another node and lost its state, or latched the runner after a claim of unknown outcome (fail closed). The runner retries every 5 seconds until its idle timeout replaces it. On Linux, replace the idle runners now:

  ```bash
  docker service update --force --update-parallelism 0 runners_<SERVICE>
  ```

  **On Windows, do not**: it kills busy jobs. Remove only the refused containers ([Replace refused runners on Windows](operations.md#replace-refused-runners-on-windows)). See also [A claim whose outcome is unknown](operations.md#a-claim-whose-outcome-is-unknown) and [Restart the proxy](operations.md#restart-the-proxy).
- `too many claims` (429), or 503 with `Retry-After`: the proxy limits each client IP and serves at most 512 requests at once. A runner stays far below that, so look for a client that polls in a loop ([Monitor the token proxy](operations.md#monitor-the-token-proxy)).

### The runner log shows x509 certificate errors

Symptom: `x509: certificate has expired or is not yet valid`, or `x509: certificate signed by unknown authority`, and the runner never connects.

**Cause.** The node clock drifted, or an inspecting proxy re-signs the traffic with a CA that the container does not trust.

**Fix.** This must print `yes`. If not, fix NTP on the node.

```bash
timedatectl show -p NTPSynchronized --value
```

For an inspecting proxy or your own CircleCI server CA, add the CA to your image for the runner and the jobs. The token proxy and the distributors read other stores: see [Proxies and certificate authorities, component by component](operations.md#proxies-and-certificate-authorities-component-by-component) and [Private certificate authorities](images.md#private-certificate-authorities).

### Jobs wait while the runners are idle

Symptom: the runner inventory shows idle runners, and jobs stay queued.

**Cause.** The inventory shows running tasks only, and queued tasks count against concurrency. A class can sit at the `maxConcurrentTasks` limit of the resource class (20 by default) or at the runner concurrency of your plan. Jobs for a class with no runner queue forever and hold concurrency.

**Fix.** Ask the runner API how many tasks wait, and compare it with the replicas. Set `RUNNER_API` to the runner API of your installation (for CircleCI server).

```bash
RUNNER_API=https://runner.circleci.com
curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" "$RUNNER_API/api/v3/runner/tasks?resource-class=<NAMESPACE>/<CLASS>"
```

A count above 0 with idle replicas points at a limit, or at a class name that no service serves. Cancel the tasks of a class with no runners, and ask CircleCI support to raise `maxConcurrentTasks` ([Capacity and concurrency](operations.md#capacity-and-concurrency)).

### Many jobs fail within seconds on one node

Symptom: jobs of a class fail within seconds or end with no work done, and `docker stack ps runners` lists many tasks of one node that ended seconds after they started. The node is `Ready` and the others are fine.

**Cause.** A `Ready` node can still fail every job it claims: a full disk, a wrong `current` link in the runner volume, a bad Docker engine, a clock far off, or a broken route to the registry or CircleCI. A failed task is replaced at once and claims again, so the broken node takes a large share of the jobs. Swarm does not see it, because the node answers its heartbeats.

**Fix.**

1. Count the tasks that ended in the last minute for each node. A node far above the others is the one.

   ```bash
   docker stack ps runners --format '{{.Node}} {{.CurrentState}}' | grep -E ' (Complete|Failed) [0-9]+ seconds? ago' | cut -d' ' -f1 | sort | uniq -c | sort -rn
   docker stack ps runners --no-trunc --format '{{.Node}} {{.Name}} {{.CurrentState}} {{.Error}}' | grep '<NODE_NAME>' | head -20
   ```

2. Stop it from taking jobs. On Linux, drain it. On Windows, pause it instead: failing jobs free the node quickly ([A Windows node](operations.md#a-windows-node)).

   ```bash
   docker node update --availability drain <NODE_NAME>
   ```

3. Find the cause on the node (Linux):

   ```bash
   df -h /var/lib/docker
   docker run --rm alpine true
   docker run --rm -v runners_runner-bin:/v:ro alpine ls -l /v/current
   docker ps -a --filter 'name=runners_' --format '{{.Names}} {{.Status}}' | head
   timedatectl show -p NTPSynchronized --value
   ```

   Read the newest failed container (`docker logs <CONTAINER>`) and `journalctl -u docker -n 100`. For a full disk, see [Free disk space](operations.md#free-disk-space). A missing `current` means the distributor has not installed a runner here: [The runner waits for the distributor, and then exits with code 80](#the-runner-waits-for-the-distributor-and-then-exits-with-code-80).
4. Fix the cause and set the node `active`. If the cause is unclear, run `docker swarm leave` on it, then `docker node rm <NODE_NAME>` on a manager, and rebuild it. Rerun the failed jobs.

To see it early, alert on the count in step 1 and keep a [canary job](operations.md#monitor-the-cluster) for each class.

### A service update is paused or rolled back

Symptom: `docker service update` or `docker stack deploy` stops partway, and this prints `paused`, `rollback_started` or `rollback_completed` (the `Message` field names the failed task):

```bash
docker service inspect --format '{{.UpdateStatus.State}}' runners_<SERVICE>
```

**Cause.** A new task failed to start, for example exit code 80 after a wrong setting or a missing secret. The stack files set no `failure_action`, so Swarm pauses at the first failure, and the replicas it did not reach keep the old version.

**Fix.** Read why the task failed (`docker service ps --no-trunc runners_<SERVICE>`), correct your stack file, and deploy again with the same files. To go back at once:

```bash
docker service update --rollback runners_<SERVICE>
```

Refer to [Update the images](operations.md#update-the-images).

### Error: The swarm does not have a leader

Symptom: a Swarm command fails with `The swarm does not have a leader. It's possible that too few managers are online.`

**Cause.** The managers lost quorum (two of three, or three of five must be online). Running jobs finish, but no replacement task starts, so capacity drops to zero.

**Fix.** Bring the managers back, starting with the ones stopped last, and check `docker node ls` on a reachable manager. If the managers are lost for good, recover from one surviving manager:

```bash
docker swarm init --force-new-cluster --advertise-addr <MANAGER_IP>
```

Refer to [Back up the managers, and recover](operations.md#back-up-the-managers-and-recover) and [Managers and quorum](multi-node.md#managers-and-quorum).

### More Swarm symptoms

| Symptom | Cause and fix |
|---|---|
| `docker stack deploy` fails with `secret not found: linux-default-token` | An external secret does not exist. Every service needs `<SERVICE>-token`, and every single-task runner service (Linux and Windows) also needs `runner-placeholder-token`. Create it, or delete the service from your copy with its entries under `secrets:` and `networks:`. On Windows, `runners.yaml` needs `windows-default-token` and `runner-placeholder-token`, and each add-on file its own `<SERVICE>-token` |
| `Swarm is encrypted and needs to be unlocked before it can be used` | Autolock, and this manager restarted. Run `docker swarm unlock` and enter the key from `docker swarm unlock-key` on an unlocked manager ([Unlock a locked swarm](operations.md#unlock-a-locked-swarm)) |
| `This node is not a swarm manager` | You ran a Swarm command on a worker. Run it on a manager (`docker node ls` lists them) |
| `docker swarm join` times out or fails with a connection error | The manager is not reachable on its advertised address and port 2377, or listens on loopback only. Open the [Inter-node ports](multi-node.md#inter-node-ports), and initialize the swarm with a routable `--advertise-addr` |
| Jobs queue but no runner claims them | The `resource_class` does not equal `<NAMESPACE>/<SERVICE>`, the class has `replicas: 0`, or replicas cannot reach CircleCI. Check **Runners** in the web app, that the tasks run, and [Egress hosts](security.md#egress-hosts) |
| A task is `rejected` with `No such image` or an authentication error | The node cannot pull the image: registry unreachable, image private, or rate limit. Check egress, deploy with `--with-registry-auth` for a private registry, or use a mirror ([Registry needs](multi-node.md#registry-needs), [What needs the internet](security.md#what-needs-internet)) |
| `docker service logs` prints nothing, or less than you expect | Swarm prunes old tasks of a slot with their logs (history limit 5 by default, 2 with the setup helper), and the command reads only the `local`, `json-file` and `journald` drivers. Use `docker service ps --no-trunc`, `docker logs <CONTAINER>` on the node, and [Ship the logs](operations.md#ship-the-logs) |
| A job exits with code 137, or a build fails with `fork: Resource temporarily unavailable` or `Cannot allocate memory` | 137 is SIGKILL: the kernel kills a job over the memory limit (`docker inspect <CONTAINER>` shows `OOMKilled: true`), or a stop outlasted `stop_grace_period`. More processes than `limits.pids` (4096) fails to fork. Raise `limits.memory` or `limits.pids` and keep the reservation equal ([Size the limits](resource-classes.md#size-the-limits)) |
| A job fails with a message that points at an issue with your infrastructure, and its log just stops | The runner stopped during the job: a node died or rebooted, a stop from outside (update, scale-down, drain) outlasted the grace period (on Windows, change a class only while it is idle), or an out-of-memory kill. Find the task with `docker service ps --no-trunc runners_<SERVICE>`, then rerun the job: runners do not retry ([Node death](operations.md#node-death), [Stop a busy Windows container](operations.md#stop-a-busy-windows-container)) |

## Linux

### The runner waits for the distributor, and then exits with code 80

Symptom: the runner log shows `circleci-runner-entrypoint: waiting for the runner-distributor of this node to install the runner`. After the wait (120 seconds by default) the container exits with code 80 and `/opt/machine-runner-swarm/current is 'missing': the runner-distributor of this node has not installed the runner`, and the loop repeats every 10 seconds.

**Cause.** The `runner-bin` volume of the node has no runner yet: the `runner-distributor` task of the node is not running, cannot download the runner, or refuses it. A first deploy or a node that just joined is normal: the next container starts as soon as `current` exists.

**Fix.** Check that the distributor runs on that node, and read its log:

```bash
docker service ps --no-trunc runners_runner-distributor
docker service logs --tail 50 runners_runner-distributor
```

A node with no task is `Down`, drained, or not a Linux node. Otherwise see [The distributor log shows cannot download](#the-distributor-log-shows-cannot-download) and [The distributor log shows SHA-256 mismatch](#the-distributor-log-shows-sha-256-mismatch). To wait longer, set `MACHINE_RUNNER_SWARM_RUNNER_WAIT` in the environment of the runner services.

### Error: does not match its SHA-256 record

Symptom: the container exits with code 80 and `.../versions/3.1.13/bin/circleci-runner does not match its SHA-256 record ...: refusing to start`.

**Cause.** The binary in the volume is not the one the distributor recorded: an incomplete install, a changed volume, or a damaged disk. The entrypoint checks at every start and never runs a different binary ([Runner binary integrity on Linux](security.md#runner-binary-integrity-on-linux)).

**Fix.** The distributor reinstalls a differing version at its next check. To do it now, force an update, which downloads the version again on every node:

```bash
docker service update --force runners_runner-distributor
```

If the binary changes again, find what writes to the volume: a privileged container on the node, or a person with access.

### The distributor log shows cannot download

Symptom: `runners_runner-distributor` logs `runner-distributor: cannot download <ADDRESS>`, for `manifest.json` or a tarball such as `<VERSION>/circleci-runner_linux_amd64.tar.gz`. The distributor keeps its runner and retries in 5 minutes. Without a runner, the runner containers of the node end as in the entry above.

**Cause.** The node cannot reach `circleci-binary-releases.s3.amazonaws.com` or your mirror (egress rule, proxy, DNS, clock), or the file is not on the mirror (for example the pinned version). An `https` mirror needs a certificate from a public CA, because the distributor uses the CA bundle of the stock Alpine image. A proxy rarely helps: the distributor `wget` reads only lowercase `http_proxy`, sends `https://` URLs as a plain `GET` and not `CONNECT`, and ignores `no_proxy`.

**Fix.** Download the same file from the node with the same tool:

```bash
docker run --rm alpine wget -q -O /dev/null https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/manifest.json && echo reachable
```

Open the host in [Egress hosts](security.md#egress-hosts), or fix the mirror. A mirror that the node reaches without a proxy is the dependable setup ([Run the downloads from a mirror](operations.md#run-the-downloads-from-a-mirror), [Proxies and certificate authorities, component by component](operations.md#proxies-and-certificate-authorities-component-by-component)).

### The distributor log shows SHA-256 mismatch

Symptom: `runner-distributor: SHA-256 mismatch for circleci-runner_linux_amd64.tar.gz <VERSION>: got <HASH>, wanted <HASH>: refusing to install`. The distributor installs nothing and retries later.

**Cause.** The tarball does not have the SHA-256 that the manifest, or your `MACHINE_RUNNER_SWARM_RUNNER_SHA256` list, names. Usual causes: a list that lacks one architecture (a fleet with amd64 and arm64 nodes needs both), a mirror whose tarball and manifest do not match, or a proxy that changes the download.

**Fix.** Compare `wanted` with the SHA-256 of the file you expect, from the `checksums.txt` of the release or the manifest, and correct the list, mirror or proxy. Never copy the `got` value into the list without checking where the file came from.

### The token-proxy service does not start: the image cannot be pulled

Symptom: `docker service ps runners_token-proxy --no-trunc` (Windows: `runners_token-proxy-windows`) shows `No such image`, `manifest unknown`, `pull access denied` or `no matching manifest for <PLATFORM>`, and runners get connection errors for `token-proxy`. The distributor and runner are unaffected.

**Cause.** The image is `ccilabs/machine-runner-swarm-proxy`, or what `MACHINE_RUNNER_SWARM_PROXY_IMAGE` names. Usual causes: the node cannot reach Docker Hub, the tag does not exist (a typo, or `edge` before the first publication of the main branch), a local image such as `machine-runner-swarm-proxy:dev` that exists on another node, or a platform the tag lacks (Windows on Arm).

**Fix.** Check the name and pull it on the node:

```bash
docker service inspect runners_token-proxy --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'
docker pull <IMAGE>
```

Behind an allow list, add Docker Hub ([Egress hosts](security.md#egress-hosts)), or mirror the image and set `MACHINE_RUNNER_SWARM_PROXY_IMAGE` ([Upgrade the token proxy](operations.md#upgrade-the-token-proxy)). A local build must be on the node that runs the proxy: build it there, or `docker save <IMAGE> | ssh <NODE> docker load`. Swarm retries by itself.

### Error: must be owned by root and not group/world writable

Symptom: the container exits with code 80 and `.../versions/3.1.13/bin/circleci-runner must be owned by root and not group/world writable`.

**Cause.** The entrypoint refuses a runner that the job user or runner user can replace. The distributor makes the volume files root-owned with mode `0755`, so something changed them.

**Fix.** Set the owner and mode again on the node:

```bash
docker run --rm -v runners_runner-bin:/v alpine sh -c 'chown -R 0:0 /v && chmod -R go-w /v'
```

### Error: failed to remove working directory, permission denied

Symptom: every task fails, with `failed to remove working directory before starting task` or `... while cleaning up task` (or `could not clean up task`), each with `permission denied`.

**Cause.** Someone set `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` to `true` on a Linux service. The runner (uid 2000) removes its working directory itself, but the job user owns that directory and its files, so even the first task fails. The stack files and the entrypoint default it to `false` for this reason.

**Fix.** Set `CIRCLECI_RUNNER_CLEANUP_WORK_DIR: "false"`, or remove the variable so the default applies, and deploy again. A single-task container is discarded after the job, so nothing is lost. In a persistent class, start every job with a step that removes what an earlier job left ([Working directory cleanup](security.md#working-directory-cleanup)).

### Permission denied on /opt/machine-runner-swarm with SELinux

Symptom: on RHEL, a replica reports `Permission denied` for files under `/opt/machine-runner-swarm` while SELinux is enforcing.

**Cause.** Untested here: CI does not run on RHEL. Docker normally labels volume files for containers. When it does not, the files keep a type that containers may not read, and a Swarm service mount has no `:z` option to relabel them.

**Fix.** Confirm the denial, then label the volume on the node. Files the distributor writes later inherit the label.

```bash
sudo ausearch -m avc -ts recent
sudo chcon -R -t container_file_t /var/lib/docker/volumes/runners_runner-bin/_data
```

Keep SELinux enforcing. If you needed this, open an [issue](https://github.com/CircleCI-Labs/machine-runner-swarm/issues) with the `avc` line.

### More Linux symptoms

| Symptom | Cause and fix |
|---|---|
| Exit code 80 with `jobs cannot be stepped down in this image: it needs sudo or util-linux setpriv` | The image has neither `sudo` nor util-linux `setpriv`, or no `setpriv` and no `su` to start the runner. A hardened class (`MACHINE_RUNNER_SWARM_JOB_SUDO=false`) needs util-linux `setpriv` even if the image has sudo. Add the packages in a derived image ([What an image needs](images.md#what-an-image-needs)) |
| The distributor logs `current is <VERSION> (major <N>), not 3: not adopting it`, or `current has SHA-256 <HASH>, which no versioned release of the manifest has: not adopting it` | The first: `current` moved to another major version, and the distributor keeps its version. Read the runner changelog, try it, then set `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` or pin the version ([Pin a version](operations.md#pin-a-version)). The second: the mirror has an old or edited `manifest.json`. Copy it again, with the tarball of the version `current` names |
| Every `sudo` in a job prints `unable to send audit message` | The `AUDIT_WRITE` capability is dropped. Keep it out of `cap_drop` (a hardened class keeps it in `cap_add`) |
| In the hardened class, `apt-get install` fails with `Permission denied`, or `sudo` says the user may not run sudo | By design: the class steps jobs down with `setpriv --no-new-privs`. Build the tools into the image ([Bring your own image](images.md#linux-bring-your-own-image)) |
| `docker build` fails with `Cannot connect to the Docker daemon` | By design: the class mounts no Docker engine. Use the opt-in class or a daemonless builder ([Docker builds](docker-builds.md)) |
| A docker-build job fails with `permission denied while trying to connect to the Docker daemon socket` | The entrypoint adds the job user to the socket's group but skips group id 0, so a `root:root` socket gives no access. Give the host socket a group that is not root, normally `docker` (`SocketGroup=docker` in the systemd socket unit), check that `stat -c '%U:%G %g' /var/run/docker.sock` shows a group id above 0, and deploy again |
| `no space left on device`, Docker commands fail, or the node stops taking jobs | Each finished job leaves a stopped container (Swarm keeps five tasks per slot by default), plus images, build cache and logs. Stop the node from taking jobs, free the space and set the history limit ([Free disk space](operations.md#free-disk-space)). It can look like [Many jobs fail within seconds on one node](#many-jobs-fail-within-seconds-on-one-node) |

## Windows

| Symptom | Cause and fix |
|---|---|
| Task rejected with `0xc0370101`: `The container operating system does not match the host operating system` | The image build is newer than the host. A Server 2022 host runs only `ltsc2022` images, a Server 2025 host `ltsc2025` and `ltsc2022`. Labels normally prevent this, so look for a node with a label it should not have. Use a tag the host can run, and set the `machine-runner-swarm.windows-ltsc2022` and `windows-ltsc2025` labels to match ([Image tags and host builds](install-windows.md#image-tags-and-host-builds)) |
| The container runs but the runner never claims a job and logs no clear error | Without `SeCreateSymbolicLinkPrivilege` the runner retries the task agent download forever. This happens when the container runs as a user other than `ContainerAdministrator`. Never set `user:` in a Windows service or change `USER` in a derived image |
| Log says `circleci-runner <VERSION> is in use: removing it at a later check` | Windows cannot remove files that a running container uses. Nothing to do: the distributor removes the version at a later check |
| `docker swarm init` fails with `could not find the system's IP address - specify one with --advertise-addr` | Pass the host IPv4 address: `docker swarm init --advertise-addr <HOST_IPV4>` (also on a host with several adapters, and `Setup.ps1 -InitSwarm` requires `-AdvertiseAddr`) |
| Downloads fail with `Unable to connect to the remote server` or `no such host` for a few seconds after `docker swarm init` | Pull the images first and run `docker swarm init` last. The distributor retries its downloads |
| Overlay network creation fails on a host with one adapter | An existing `transparent` network can block overlay networks. Move it to a second adapter or remove it (Microsoft documentation on Windows container networking) |
| The first task on a host takes a long time | The node pulls the Server Core image (about 2.2 GB compressed) when the first task lands. Run `docker pull` for the image on each node before you deploy |
| `Setup.ps1` reports `CHECK windows-server FAIL` | The helper supports Windows Server 2022 (build 20348) and 2025 (build 26100). Server 2019 is untested and has no label in the stack files, so it needs your own image tag, label and constraint |
| `persist_to_workspace` or `attach_workspace` reports a missing `tar` or `gzip` | The Git mount is missing, or the service `PATH` lacks `C:\Program Files\Git\usr\bin` (a service `PATH` replaces the image one). Keep both mounts and the full `PATH` from the shipped file |
| `C:\Program Files\Git\usr\bin\tar.exe` fails with `Cannot stat` when you run it by hand with a backslash path | The task agent runs this `tar.exe` from the drive root with `--force-local` and forward-slash operands relative to the root (for `C:\cci\w\ws` it passes `cci/w/ws`). Use the same form in your test |
| `hcs::System::Start: context deadline exceeded` | An image build used `New-Item -Force` on an existing registry key, which deletes its values and subkeys. On `HKLM:\SYSTEM\CurrentControlSet\Services\cexecsvc` that removes the container exec service. Rebuild the image and set values with `reg add` or `Set-ItemProperty` |

### The runner never starts: cannot access path current

Symptom: `docker service ps --no-trunc runners_windows-default` shows tasks failing with `cannot access path ...\runner-bin\_data\current` (or `...\git\current`) or `invalid mount config`, and Swarm starts the next task after 10 seconds.

**Cause.** `runner-distributor-windows` has not flipped the links `current` and `git\current` of the volume on this node yet. This is normal on a new node (the first download of the runner and portable Git takes a few minutes). It lasts when the distributor cannot install.

**Fix.** Read its log:

```powershell
docker service logs runners_runner-distributor-windows
```

A `SHA-256 mismatch`, `cannot download` or `not adopting it` line names the cause. The service must have a task on the node (`docker service ps runners_runner-distributor-windows`), so the node needs the label `machine-runner-swarm.windows-ltsc2022=true` and the base image pulled. Behind a proxy, set `HTTPS_PROXY` on the distributor service (it reads only `HTTPS_PROXY`, no `NO_PROXY`). Without internet access, refer to [Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows).

### Container exits with code 3221225786 after a stop

Symptom: a job ends about 5 seconds after a rolling update, scale-down, node drain or `docker stop`, and `docker service ps --no-trunc` shows `task: non-zero exit (3221225786)` (`0xC000013A`).

**Cause.** The container was stopped from outside while it ran a job. A job that finishes by itself does not end this way.

**Fix.** Rerun the interrupted jobs, and change a class only while it is idle ([why](operations.md#stop-a-busy-windows-container)).

## Collect information for a bug report

Gather the output of these commands, remove tokens, and open an [issue](https://github.com/CircleCI-Labs/machine-runner-swarm/issues).

```bash
docker version
docker node ls
docker stack ps runners --no-trunc
docker service logs --tail 200 runners_<SERVICE>
docker service logs --tail 200 runners_token-proxy
```

On Linux, add the runner version (run on the node) and the distributor log:

```bash
docker run --rm -v runners_runner-bin:/v:ro alpine cat /v/current/VERSION
docker service logs --tail 100 runners_runner-distributor
```

On Windows, add the distributor log:

```powershell
docker service logs --tail 100 runners_runner-distributor-windows
```
