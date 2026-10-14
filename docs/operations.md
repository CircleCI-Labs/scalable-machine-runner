---
page-title: Operations
page-audience: admin
page-description: Check status and logs, run the cluster with monitoring, capacity, backups and recovery, upgrade the runner and images, rotate tokens, drain nodes for patching, and uninstall the stack.
---

# Operations

This page describes the day-to-day tasks for a running stack: checking status, running the cluster, upgrading, rotating tokens, patching nodes, and uninstalling. The commands use the stack name `runners` and the service names of the shipped files. Run them on a manager node.

## Check status and logs

List the services and the replicas that run:

```console
$ docker stack services runners
```

List the tasks, including the finished ones that Swarm keeps for a short time. The `ERROR` column shows why a task failed or stays pending.

```console
$ docker stack ps runners --no-trunc
$ docker service ps --no-trunc runners_linux-default
```

Read the runner output of a service. On Linux, the entrypoint prints one line that starts with `circleci-runner-entrypoint:`.

```console
$ docker service logs --tail 100 --follow runners_linux-default
```

On Linux, the lines of the `runner-distributor` service start with `runner-distributor:`. They say which version the node installs and when the link `current` moves.

```console
$ docker service logs --tail 50 runners_runner-distributor
```

Healthy single-task replicas show a steady stream of tasks that end in `Complete`, because every finished job ends a task. A task that ends in `Failed` with `task: non-zero exit` needs attention. Alert on these signals:

- Tasks that end with a non-zero exit code, including 80 and 1. Code 143 is the exception: a replica that gets SIGTERM while it still retries to reach CircleCI at start-up exits with 143, and needs no action.
- Log lines that start with `circleci-runner: error` or `circleci-runner-entrypoint: error`, and lines that contain `401`. In the log of the distributor, alert on `cannot download`, `SHA-256 mismatch`, and `error`.
- Tasks that stay `Pending`.

In the web app, select **Runners** to see the replicas of each class in the inventory. A name that you do not recognize means that someone else holds a token of that class.

## Run the cluster

The sections below cover what a team that runs the stack in production needs beyond the day-one commands: logs that survive, signals to watch, capacity, backups, certificates, and what a failure costs.

### Ship the logs

`docker service logs` reads the logs of the tasks that Swarm still holds. Every finished job ends a task, and the task history limit of 2 makes Swarm prune old tasks and their containers, so the log of a job is gone after a few more jobs. The stack files keep the logs on the node, with the `local` driver on Linux (3 files of 20 MB) and `json-file` on Windows, and rotate them.

To keep logs for incidents, move them off the node. Choose one:

- **A logging driver.** Change `logging:` in your copy of every stack file to a driver that ships logs, such as `syslog`, `fluentd`, or `gelf`. The stack files set the driver per service, so a default in `daemon.json` does not apply. `docker service logs` then works only for drivers that can be read back, which these are not.
- **A log agent on every node.** Run an agent that reads container logs through the Docker API and forwards them. The stack files stay as they are, and `docker service logs` keeps working.

Keep the lines that start with `circleci-runner-entrypoint:`, `circleci-runner:`, and `runner-distributor:`, and alert on the signals in [Check status and logs](#check-status-and-logs).

### Monitor the cluster

Watch the Swarm and CircleCI. The Swarm commands run on a manager.

```console
$ docker service ls
$ docker node ls
$ docker stack ps runners --filter desired-state=running --format '{{.Name}} {{.Node}} {{.CurrentState}}' | grep -v Running
```

The runner API shows what CircleCI sees. It needs a personal API token. Refer to the [runner API reference](https://circleci.com/docs/reference/runner-api/).

```console
$ curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" \
    "https://runner.circleci.com/api/v3/runner?resource-class=<namespace>/linux-default" \
    | jq -r '.items[] | "\(.name) \(.last_connected)"'
$ curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" \
    "https://runner.circleci.com/api/v3/runner/tasks?resource-class=<namespace>/linux-default"
$ curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" \
    "https://runner.circleci.com/api/v3/runner/tasks/running?resource-class=<namespace>/linux-default"
```

| Signal | Where | Alert when |
|---|---|---|
| Replicas running against desired | `docker service ls`, the `REPLICAS` column | Fewer than desired for more than 10 minutes. Refer to [A task stays pending](troubleshooting.md#a-task-stays-pending) |
| Node state | `docker node ls` | A node is not `Ready`, a manager is `Unreachable`, or no manager is `Leader` |
| Runners connected | `/api/v3/runner`, `items` and `last_connected` | Fewer items than replicas, or a `last_connected` older than 2 minutes, which is when the CLI stops calling an instance `online` |
| Jobs that wait | `/api/v3/runner/tasks`, `unclaimed_task_count` | Above 0 for several minutes. With every replica busy, add replicas. With idle replicas, check [concurrency](#capacity-and-concurrency) |
| Jobs that run | `/api/v3/runner/tasks/running`, `running_runner_tasks` | Equal to the replicas of the class for a long time: the class is full |
| Task exits | `docker service ps` | Exit code 80, or a restart loop. Refer to [The container restarts every 10 seconds](troubleshooting.md#the-container-restarts-every-10-seconds) |
| Runner distributor | `docker service ps runners_runner-distributor`, and its log | Fewer running tasks than Linux nodes, or log lines with `cannot download` or `SHA-256 mismatch`. A line with `not adopting it` says that `current` is not a version that the distributor follows |
| Disk | `docker system df` and the free space of the Docker data directory | Above 80 percent. Refer to [Free disk space](#free-disk-space) |

### Capacity and concurrency

The replicas of a class are the jobs it runs at the same time, and the sum over all classes is the capacity of the cluster. A job with `parallelism: n` is `n` tasks, so it needs `n` replicas at once.

Two limits sit above the replicas, and both are set on the CircleCI side:

- **The runner concurrency of your plan**, which all self-hosted runner jobs of the organization share.
- **`maxConcurrentTasks` of the resource class**, which is 20 by default and which CircleCI support raises. A class with more than 20 replicas leaves the extra replicas idle until it is raised.

Queued tasks count against concurrency, and the runner inventory shows running tasks only, so runners can look idle while jobs wait. A job for a class that has no runner queues indefinitely and holds concurrency. Check `unclaimed_task_count`, and cancel the tasks of a class that no longer has runners. Refer to [Jobs wait while the runners are idle](troubleshooting.md#jobs-wait-while-the-runners-are-idle).

On the Swarm side, the reservations of the replicas on a node must fit in the node. Refer to [Size the limits](resource-classes.md#size-the-limits).

### Back up the managers, and recover

The state of the cluster is the directory `/var/lib/docker/swarm` of each manager. It holds the Raft log with every Swarm secret, so **the backup holds every runner token**. Keep it as you keep a password vault, and delete old copies.

1. If the managers use autolock, save the unlock key first: `docker swarm unlock-key`.
2. Stop Docker on one manager that is not the leader, so that nothing changes during the copy. The other managers keep the quorum, so use three managers.
3. Copy the whole directory, and start Docker again:

   ```console
   $ sudo systemctl stop docker
   $ sudo tar -czf swarm-backup-$(date +%F).tar.gz -C /var/lib/docker swarm
   $ sudo systemctl start docker
   ```

For this stack, **disaster recovery means redeploying and issuing new tokens**, because the stack files hold the whole desired state and the tokens are the only secrets:

1. Create a new Swarm on a new manager, and join the nodes. Refer to [Create the swarm](multi-node.md#create-the-swarm).
2. Create a new token for each class, delete the old tokens, and create the secrets. Refer to [Rotate a runner token](#rotate-a-runner-token).
3. Deploy the same stack files, with the same list of `-c` files.

Restore the backup only to keep the node membership, or after a loss of quorum. Stop Docker on the target manager, replace the contents of `/var/lib/docker/swarm` with the backup, start Docker, and run `docker swarm init --force-new-cluster --advertise-addr <manager IP address>`. This makes the manager a single-manager cluster with the old state. Unlock it if the swarm uses autolock, check `docker node ls` and `docker service ls`, and then add managers and workers again. Back up again afterwards.

### Unlock a locked swarm

With autolock (`docker swarm update --autolock=true`), a manager that restarts cannot read the Raft log until you unlock it. A locked manager answers Swarm commands with `Swarm is encrypted and needs to be unlocked before it can be used`, and it takes no part in the quorum. Running containers on other nodes keep running, but nothing creates replacement tasks without a quorum, so a reboot of managers without unlocking them drains the capacity of the cluster.

```console
$ docker swarm unlock
$ docker swarm unlock-key
$ docker swarm unlock-key --rotate
```

The first command asks for the key on the locked manager. The second prints the key, on an unlocked manager. The third makes a new key, so run it after anyone who knew the old key leaves, and store the new key outside the cluster. Plan every patching reboot of a manager with its unlock.

### Rotate the cluster certificates

Every node has a certificate from the Swarm CA, and Swarm renews them before they expire (90 days by default). A node that is offline longer than that must leave and join again.

After a node was compromised, for example a build job that took over a docker-build node, remove the node and rotate the CA, so that its certificate stops working:

```console
$ docker node rm --force <node name>
$ docker swarm ca --rotate
$ docker node ls
```

Rotate the join tokens too (`docker swarm join-token --rotate worker` and `manager`). A compromised node could read the secrets of the tasks that ran on it, and a compromised manager could read every secret, so also rotate the tokens of those classes. Refer to [If a token leaked](#if-a-token-leaked).

### Upgrade Docker and the nodes in order

Upgrade one node at a time, managers first and then workers, and wait until the cluster is healthy before the next node:

1. Drain the node (a node drain), as in [Drain a node for patching](#drain-a-node-for-patching). On Windows, drain only a node whose classes are idle.
2. Upgrade Docker and reboot. Unlock a manager that uses autolock.
3. Return the node to service, and check that `docker node ls` shows it `Ready`, and a manager `Reachable` or `Leader`.

Managers go one at a time so the quorum holds: with three managers, one is down at most. Leave mixed Docker versions in place only for the length of the upgrade. The runner upgrades separately, with no stop. Refer to [Upgrade the runner on Linux](#upgrade-the-runner-on-linux).

### Node death

When a node dies, Swarm marks it `Down` after it misses its heartbeats, and starts replacement tasks on other nodes that match the constraints of the service.

- **The jobs that ran on the node are lost.** CircleCI reports them as failed because of a problem with your infrastructure. Self-hosted runners have no automatic retry, so rerun the workflow from the failed job.
- **Services that are pinned to the node stay `Pending`.** That includes the persistent class, which uses `node.hostname`, and the docker-build classes, which need a labeled node.
- **The capacity drops** by the replicas of the node, until the node returns or the other nodes have room. Queued jobs wait for the replicas to start.
- **A node that returns** rejoins by itself when its certificate is still valid, and Swarm does not move tasks back to it.
- **A node that is gone for good** is removed with `docker node rm --force <node name>`. Remove a lost manager with `docker node demote` (if it can still be reached) or `docker node rm --force`, and add a new manager so that the quorum holds.
- **The loss of a manager** keeps the cluster running while a majority remains. Without a majority, running jobs finish but no replica is replaced. Refer to [Managers and quorum](multi-node.md#managers-and-quorum).

## Upgrade the runner and images

Swarm replaces containers one at a time. The stack files set `update_config` to `order: stop-first` and `parallelism: 1`. Swarm sends SIGTERM to a busy replica, the runner drains (a runner drain: it takes no new job and finishes the running one), and only then does Swarm start the new container. An idle replica stops within about 5 seconds and exits with code 0. A busy replica exits with code 0 when its job ends, so an update can take as long as your longest job, up to the `stop_grace_period` of 5 hours and 5 minutes. The command waits until the update finishes, unless you add `--detach`. This holds on Linux. On Windows, a stop kills a busy container after about 5 seconds. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container). A new runner version needs no stop on Linux: refer to the next section.

### Upgrade the runner on Linux

The `runner-distributor` service is the only way a runner reaches a Linux node, and it is the only place that says which version the nodes run. A runner service carries no version and no hash. An upgrade, a pin, and a rollback therefore change the distributor service only: no runner service restarts, and no job is interrupted. Refer to [The runner distributor on Linux](concepts.md#the-runner-distributor-on-linux) for the model.

A container resolves the link `current` once, when it starts. A job that runs now, and its container, keep their version. The next container, which is the next job, gets the new one. Idle replicas keep the old binary until they claim a job or exit after `CIRCLECI_RUNNER_IDLE_TIMEOUT`, which is 1 hour in the stack files.

#### Settings of the distributor

The settings are variables of `docker stack deploy`. They apply to the distributor service only. The file `linux/stack/runners.yaml` reads them in `x-distributor-env` and sets the defaults.

| Variable | Default | Effect |
|---|---|---|
| `MACHINE_RUNNER_SWARM_RUNNER_VERSION` | `current` | `current` follows the manifest of CircleCI. A version such as `3.1.12` pins that version |
| `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` | `3` | The major version that `current` may adopt |
| `MACHINE_RUNNER_SWARM_CHECK_INTERVAL` | `24h` | How often the distributor looks again. A number of seconds, or a number with `s`, `m`, `h`, or `d` |
| `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` | `https://circleci-binary-releases.s3.amazonaws.com/circleci-runner` | Where `manifest.json` and the tarballs are. Set it for a [mirror](#run-the-downloads-from-a-mirror) |
| `MACHINE_RUNNER_SWARM_RUNNER_SHA256` | Empty | A comma-separated list of the SHA-256 values of the tarballs that may be installed, for every architecture of your nodes. It replaces the value of the manifest. Refer to [Runner binary integrity on Linux](security.md#runner-binary-integrity-on-linux) |

A command that sets a variable must reach `docker stack deploy`. A host with `sudo` drops the environment, so pass the variable with `env`, or run the command as a user in the `docker` group. Set the same variables on every later deploy, because a deploy without them sets the defaults again.

```console
$ sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 docker stack deploy -c deploy/runners.yaml runners
$ sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 linux/setup.sh --deploy --stack-file deploy/runners.yaml
```

#### What the default does

With `current`, the distributor reads `manifest.json` when it starts and at every check interval. It finds the version that `current` names by matching the SHA-256 of `current` to a versioned entry of the manifest. It adopts that version only when its major version equals `MACHINE_RUNNER_SWARM_RUNNER_MAJOR`. For another major version it logs `not adopting it` and keeps what it has.

For a new version, it downloads the tarball, checks the SHA-256 of the tarball, extracts the runner, records the SHA-256 of the binary, and moves the link `current` with one atomic rename. A new release reaches every node within one check interval, with no redeploy. At every check the distributor also compares the active binary with its record, and it installs the version again when the binary changed.

To move the replicas that already wait for a job, force an update. An idle replica stops within seconds, and a busy one finishes its job first:

```console
$ docker service update --force runners_linux-default
```

A persistent class runs one container for all jobs, so it keeps its version until its container restarts. Recycle it in a quiet moment, for example with `docker service update --force runners_linux-persistent`. Refer to [Recycle a class](#recycle-a-class).

#### Pin a version

A version such as `3.1.12` pins that version. The distributor takes its SHA-256 from the manifest, installs it, and never moves to another version by itself. Pin a version when a change of the runner must go through your own change process, and then upgrade by changing the pin.

```console
$ sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.13 docker stack deploy -c deploy/runners.yaml runners
```

A strict organization sets `MACHINE_RUNNER_SWARM_RUNNER_SHA256` too, with the SHA-256 values of the tarballs from the `checksums.txt` of that release. The distributor then installs only a tarball with one of these values, whatever the manifest says. With `current`, a new release is refused until you update the list, so set the list together with a pinned version.

The distributor switches to a version that is installed already without any network access. Use `3.1.12` or later: it fixes the enforcement of `max_run_time`.

#### Freeze the nodes now

To stop all change at once, pin the version that the nodes run now. That version is installed, so the pin needs no network. Read it first, as in [See what runs](#see-what-runs), and then update the distributor:

```console
$ docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 runners_runner-distributor
```

Set the same value in the environment of your next `docker stack deploy`. A deploy without it sets `current` again.

#### Roll back

A rollback is a pin of an older version. The distributor keeps the last 3 versions that were active, so a rollback to one of them only moves the link: no download, and no network. A version that was removed is downloaded again.

```console
$ docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.11 runners_runner-distributor
```

The next container of every runner service runs the old version. Running jobs are not affected. Set the same value in the environment of your next `docker stack deploy`, as for the pin above.

#### What the distributor keeps

Each version takes about 75 MB in the volume. After each flip the distributor removes the versions beyond the last 3 that were active, and it never removes the active one. The file `history` in the volume lists the versions with the time of each flip.

#### See what runs

The distributor logs each flip, and each version that it installs or finds installed:

```console
$ docker service logs --tail 20 runners_runner-distributor
```

The volume `runners_runner-bin` exists on every node, so run these commands on the node that you want to inspect:

```console
$ docker run --rm -v runners_runner-bin:/v:ro alpine readlink /v/current
$ docker run --rm -v runners_runner-bin:/v:ro alpine cat /v/history
```

The runner of a container names the version directory that the container resolved when it started:

```console
$ docker top <container ID> | grep circleci-runner
```

When a node gets no runner, or a download is refused, refer to [The runner waits for the distributor, and then exits with code 80](troubleshooting.md#the-runner-waits-for-the-distributor-and-then-exits-with-code-80) and the entries that follow it.

#### Run the downloads from a mirror

A site without a route to the release bucket of CircleCI serves two things from an internal HTTP server: `manifest.json`, and the tarball `<version>/circleci-runner_linux_<arch>.tar.gz` of every version that the nodes may run. The distributor builds the address of a tarball from the base URL and the version, and it does not follow the `url` fields of the manifest, so a mirror may hold a copy of `manifest.json` unchanged.

```console
$ base=https://circleci-binary-releases.s3.amazonaws.com/circleci-runner
$ mkdir -p mirror && curl -fsSL "$base/manifest.json" -o mirror/manifest.json
$ jq -r '.releases | keys[] | select(test("^[0-9]"))' mirror/manifest.json
$ for v in 3.1.12 3.1.13; do
    mkdir -p "mirror/$v"
    for arch in amd64 arm64; do
      curl -fsSL "$base/$v/circleci-runner_linux_$arch.tar.gz" -o "mirror/$v/circleci-runner_linux_$arch.tar.gz"
    done
  done
```

Serve the directory `mirror`, and point the distributor at it:

```console
$ sudo env MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=https://mirror.example.com/circleci-runner docker stack deploy -c deploy/runners.yaml runners
```

- Copy the tarballs of the architectures that your nodes have. With `current`, copy the version that `current` names, and copy `manifest.json` again when you want the nodes to adopt a new release. The command `jq -r '.releases as $r | $r.current.linux.amd64.sha256 as $s | $r | to_entries[] | select(.key | test("^[0-9]")) | select(.value.linux.amd64.sha256 == $s) | .key' mirror/manifest.json` prints that version.
- The distributor downloads with the `wget` of the stock Alpine image and its CA bundle, so an `https` mirror needs a certificate from a public certificate authority.
- For plain `http` inside a trusted network, set `MACHINE_RUNNER_SWARM_RUNNER_SHA256` together with a pinned version. The manifest then travels unprotected, and the list keeps it out of the chain.
- The mirror replaces the runner download only. Every runner container still downloads its task agent from `circleci-binary-releases.s3.amazonaws.com`, and every node still pulls the `alpine` image of the distributor from a registry. Refer to [Does it work on hosts without internet access?](faq.md#does-it-work-on-hosts-without-internet-access).

### Upgrade the runner on Windows

The service `runner-distributor-windows` is the only way a runner and Git reach a Windows node. It works as the [Linux distributor](#upgrade-the-runner-on-linux): the same variables, the same policy, and the same rule that a runner service carries no version and no hash. An upgrade, a pin, and a rollback therefore change the distributor only. **No runner service restarts, so no busy job is killed**, which a stop would do after about 5 seconds. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container).

The distributor installs into the volume `runner-bin`, next to the versions that exist: `versions\<version>` for the runner, `git\<git version>` for portable Git. The links `current` and `git\current` are relative directory symbolic links to them, and the runner services mount the volume read-only through them: `current` at `C:\machine-runner-swarm`, and `git\current` at `C:\Program Files\Git`. Docker resolves a link when it creates a container, so the next container, which is the next job, runs the new version, and a job that runs now keeps the directory that it started with. Windows cannot replace or delete files that a running container uses, so the distributor never overwrites a version and never removes one that is in use: it tries again at its next check. `windows\tests\Test-Distributor.ps1` checks all of this in CI.

The settings are the variables of [the Linux table](#settings-of-the-distributor), set in `x-distributor-env` of `windows\stack\runners.yaml` and read from the environment of `docker stack deploy`, plus one for the pinned downloads of Git and 7-Zip:

| Variable | Effect |
|---|---|
| `MACHINE_RUNNER_SWARM_RUNNER_VERSION` | `current` (default) follows the manifest of CircleCI within `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` (default `3`) and looks again every `MACHINE_RUNNER_SWARM_CHECK_INTERVAL` (default `24h`). A version such as `3.1.12` pins it |
| `MACHINE_RUNNER_SWARM_RUNNER_SHA256` | A comma-separated list of the SHA-256 values of the `circleci-runner_windows_amd64.tar.gz` tarballs that may be installed. It replaces the value of the manifest |
| `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` | A mirror: `manifest.json` and `<version>/circleci-runner_windows_amd64.tar.gz` below this URL |
| `MACHINE_RUNNER_SWARM_TOOLS_BASE_URL` | A directory URL that holds `PortableGit-<version>-64-bit.7z.exe` and `7zr.exe`, the two downloads that the script pins by SHA-256. Without it they come from GitHub |

In PowerShell, set the variables in the environment of the shell that runs the deploy:

```powershell
$env:MACHINE_RUNNER_SWARM_RUNNER_VERSION = '3.1.12'
docker stack deploy -c deploy\runners.yaml runners
```

- **Upgrade.** With the default, a new release reaches every node within one check interval, with no redeploy. To move to a version yourself, pin it as above. A deploy without the variable sets `current` again, so set the same values on every deploy.
- **Freeze the nodes now.** Pin the version that the nodes run now. It is installed, so the pin needs no network: `docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 runners_runner-distributor-windows`.
- **Roll back.** Pin an older version. The distributor keeps the last 3 versions that were active, so a rollback to one of them only moves the link, with no network. A version that was removed is downloaded again.
- **See what runs.** `docker service logs runners_runner-distributor-windows` shows each flip. On the node, `docker run --rm --mount type=volume,source=runners_runner-bin,target=C:\v,readonly mcr.microsoft.com/windows/servercore:ltsc2022 powershell -Command "Get-Content C:\v\history; (Get-Item C:\v\current).Target"` shows the history and the active version.
- **Replicas that wait for a job** keep the old version until they claim a job or exit after `CIRCLECI_RUNNER_IDLE_TIMEOUT`, which is 1 hour in the stack file. A forced update replaces them at once, but it also stops the containers of the service, which kills a running job after about 5 seconds. Force the update only while the class is idle: `docker service update --force runners_windows-default`.
- **A mirror.** Copy `manifest.json` and the tarballs as for [Linux](#run-the-downloads-from-a-mirror), with `windows` and `amd64` in the names, and copy the two pinned Git downloads into the tools directory. The distributor downloads with PowerShell, so an `https` mirror needs a certificate that the stock Server Core image trusts.

A link cannot be replaced in one step on Windows, so for a moment `current` does not exist. A container that Swarm creates in that moment does not start, and Swarm starts the next one after the restart delay of 10 seconds. The window is a few milliseconds long. On a new node, the runner tasks fail in the same way until the first download of the distributor is done. The runner has no start-time check of the binary on Windows, because no entrypoint script exists: the distributor compares the active binary with its record at every check and installs it again when it changed. Refer to [Runner binary integrity on Windows](security.md#runner-binary-integrity-on-windows).

### Update the images

- **Linux and Windows stock images.** Change the tag or digest of `image` in your stack file, and run `docker stack deploy`. Swarm resolves a tag to its digest when you deploy, so deploy again to pick up a tag that the publisher re-pushed.
- **The distributor image.** The service `runner-distributor` runs `alpine:3`, pinned by digest. Change the digest in your stack file to move to a newer Alpine, and deploy. The distributor restarts on every node at once, and no running job is affected.
- **Your own images.** Rebuild, push, change the tag, and deploy. Rebuild on a schedule, for example monthly, and when the base image or a tool changes.
- **Windows base images.** Microsoft republishes the Server Core tags each Patch Tuesday. Pin by digest, and rebuild your own images on top of them after each update. Change a Windows service only while its class is idle. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container).

For a single service, you can also run `docker service update --image <new image> runners_<service>`. Record the change in your stack file, so that the next deploy does not undo it.

### Upgrade to a new release of this repository

1. Read the [changelog](../CHANGELOG.md). Entries marked `[BREAKING]` say what to change.
2. Compare your stack file with the file of the new release, and merge the differences.
3. Run `docker stack deploy` with the same set of `-c` files as before, and with the same distributor variables as before.

The entrypoint and the script of the distributor are Swarm configs, so this command is the whole upgrade. A Swarm config cannot change, so the name of each config carries the first 12 hex digits of the SHA-256 of its file. A release that changes the entrypoint or the script has new names. `docker stack deploy` creates the new config and updates the services that use it: the runner services one replica at a time, as in [Upgrade the runner and images](#upgrade-the-runner-and-images), and the distributor on every node.

If you edit one of these files in your own copy, rename the config in your stack file after each edit, or Swarm keeps the old file. The new name is the old prefix and the first 12 digits of the new hash:

```console
$ sha256sum linux/stack/circleci-runner-entrypoint | cut -c1-12
$ sha256sum linux/stack/runner-distributor.sh | cut -c1-12
```

In a clone of this repository, `ci/config-names.sh --write` renames the configs of the shipped stack files.

## Rotate a runner token

Swarm secrets are immutable. To rotate a token, create a second secret and swap it into the service. The rolling update replaces one replica at a time, and busy runners finish their job first. The update is serial per replica: the shipped stack files set `update_config.parallelism: 1`, and a busy replica is replaced only after its job ends, which takes up to the grace period of 5 hours and 5 minutes. A service with N replicas can therefore take up to N times that long to finish the swap. To shorten it, raise `update_config.parallelism` in the stack file, or pass `--update-parallelism <number>` to `docker service update` for one update (`0` replaces every replica at once).

1. Create a new token in CircleCI. Keep the old token until the swap is complete.

   ```console
   $ circleci runner token create <namespace>/linux-default --nickname "linux-default-<date>"
   ```

2. Create a secret with the new token. Use a new name, such as `linux-default-token-v2`.

   ```sh
   printf 'New token (hidden): '; stty -echo; IFS= read -r TOKEN; stty echo; echo
   [ -n "$TOKEN" ] && printf 'api:\n  auth_token: %s\n' "$TOKEN" | docker secret create linux-default-token-v2 -
   unset TOKEN
   ```

3. Swap the secrets in the service. On Linux:

   ```console
   $ docker service update \
       --secret-rm linux-default-token \
       --secret-add source=linux-default-token-v2,target=circleci_runner_config.yaml,uid=2000,gid=2000,mode=0400 \
       runners_linux-default
   ```

   On Windows, secrets have no `uid`, `gid`, or `mode`:

   ```powershell
   docker service update `
     --secret-rm windows-default-token `
     --secret-add source=windows-default-token-v2,target=circleci_runner_config.yaml `
     runners_windows-default
   ```

4. Wait until the update completes. The state is `completed`:

   ```console
   $ docker service inspect --format '{{.UpdateStatus.State}}' runners_linux-default
   ```

5. Record the new name in your stack file: change `source:` and the entry under the top-level `secrets:`. A later `docker stack deploy` from the old file then does not revert the swap.
6. Revoke the old token in CircleCI, and remove the old secret.

   ```console
   $ circleci runner token list --resource-class <namespace>/linux-default
   $ circleci runner token delete <token ID>
   $ docker secret rm linux-default-token
   ```

### If a token leaked

Do not swap first. Until the old token is deleted in CircleCI, it stays valid for anyone who holds it, and the swap above can take up to N times 5 hours and 5 minutes for N replicas, because it replaces one replica at a time and each busy replica finishes its job first. Delete the token as soon as its replacement exists:

1. Create the new token, and the secret with the new token. Use the steps 1 and 2 above. Nothing uses the new secret yet.
2. Delete the old token at once.

   ```console
   $ circleci runner token list --resource-class <namespace>/linux-default
   $ circleci runner token delete <token ID>
   ```

   CircleCI stops accepting the old token for new claims, so nobody can start a runner on the class with it. Jobs that already run continue until they end. Idle runners that still hold the old secret fail with 401 and restart every 10 seconds until the swap replaces them, so the class claims no new jobs until step 3 completes.
3. Swap the secrets, and replace every replica at once so that the class recovers soon:

   ```console
   $ docker service update --update-parallelism 0 \
       --secret-rm linux-default-token \
       --secret-add source=linux-default-token-v2,target=circleci_runner_config.yaml,uid=2000,gid=2000,mode=0400 \
       runners_linux-default
   ```

   Each replica still finishes the job that it runs before Swarm replaces it. On Windows, drop `uid`, `gid`, and `mode`, and expect the update to end a running job after about 5 seconds: rerun those jobs. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container).
4. Do steps 4 and 5 above (wait for the update, record the new name in your stack file), and remove the old secret with `docker secret rm linux-default-token`. Then look for what the leaked token did: the runner inventory in CircleCI for names you do not know, and the jobs that ran on the class.

## Drain a node for patching

A node drain (`docker node update --availability drain`) stops the tasks of a node and keeps new tasks away. Swarm sends SIGTERM and waits for the grace period, so a running job finishes. On Windows, a drain kills a running job after about 5 seconds, so drain a Windows node only while its classes are idle. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container). Restarting the Docker daemon stops every running container, because live restore does not work in Swarm mode, so always drain before you patch Docker or reboot.

```console
$ docker node update --availability drain <node name>
$ docker node ps <node name>
```

Wait until `docker node ps` shows no running tasks. Swarm starts the replacement tasks on other nodes at once. If the other nodes lack capacity, the replacements stay `Pending` until the drained tasks exit. Patch and reboot the node, and then return it to service:

```console
$ docker node update --availability active <node name>
```

Tasks do not move back to the node by themselves. Single-task replicas restart after every job, so new tasks spread over the nodes again within a short time. Patch managers one at a time, so the cluster keeps its quorum. Refer to [Managers and quorum](multi-node.md#managers-and-quorum).

### Stop a busy Windows container

On Linux, a stop lets the running job finish. On Windows, stopping a busy container from outside kills its job after about 5 seconds.

**The normal flow is not affected.** A job finishes, the runner exits, and the container ends cleanly. Swarm then starts a new container for the next job. Nothing stops a container from outside, so no job is lost.

**Only a stop of a busy container from outside kills the job.** When Docker stops a container, Windows sends the shutdown event to it. The runner turns the event into SIGTERM and drains (a runner drain): it accepts no new job and lets the running job finish. On Server Core, Windows waits only the time in the registry value `WaitToKillServiceTimeout` before it ends the processes. The default is 5 seconds, whatever `docker stop -t` or `stop_grace_period` says. The container then exits with the code 3221225786 (`0xC000013A`), and the job dies with it. Every one of these actions stops containers in this way:

- A rolling update, with `docker stack deploy` or `docker service update`: a deploy or an update.
- `docker service scale` to a lower number: a scale-down.
- `docker node update --availability drain`: a node drain.
- `docker stack rm`, and a restart of the Docker service.

So roll out changes while the class is idle, or rerun the jobs that were interrupted.

Microsoft describes the same limit in [hcsshim pull request 1416](https://github.com/microsoft/hcsshim/pull/1416) and in [Windows-Containers issue 164](https://github.com/microsoft/Windows-Containers/issues/164). Microsoft fixed it only in the containerd shim, and Swarm uses the runtime of the Docker engine, which does not have that fix. The CI of this repository measures the rule in every run: [`Test-StopHandling.ps1`](../windows/tests/Test-StopHandling.ps1) stops a stock container that runs a fake job of 40 seconds and reports what happens to the job.

#### Roll out a change when the class is idle

The runner API shows what a class is doing. Use a personal API token, not a resource class token.

```powershell
$h = @{ 'Circle-Token' = $env:CIRCLECI_API_TOKEN }
Invoke-RestMethod -Headers $h -Uri 'https://runner.circleci.com/api/v3/runner/tasks/running?resource-class=<namespace>/windows-default'
Invoke-RestMethod -Headers $h -Uri 'https://runner.circleci.com/api/v3/runner/tasks?resource-class=<namespace>/windows-default'
```

The first call returns `running_runner_tasks`, and the second returns `unclaimed_task_count`. Wait for `running_runner_tasks` to be 0 in a quiet period, and then run `docker service update` or `docker stack deploy`. A rolling update replaces one replica at a time and interrupts only that replica. Single-task runners also recycle after every job and at the idle timeout, so an idle class is easy to find. A drain of a node and `docker service scale` to a lower number kill running jobs in the same way, so wait for an idle class there too. Refer to the [runner API reference](https://circleci.com/docs/reference/runner-api/).

#### Optional: an image that lets a job finish after a stop (DIY)

You can lift the limit with your own image. The image sets the registry value `WaitToKillServiceTimeout` once, at build time. The value is in milliseconds, so set at least the longest job that you allow plus a margin. This example uses 18,300,000, which is 5 hours and 5 minutes, the `max_run_time` of the runner plus 5 minutes:

```dockerfile
FROM mcr.microsoft.com/windows/servercore:ltsc2022
RUN reg add HKLM\SYSTEM\CurrentControlSet\Control /v WaitToKillServiceTimeout /t REG_SZ /d 18300000 /f
```

> [!NOTE]
> Set the value at build time. We tested setting it at run time with `reg add` inside a running container, for example from the first step of a job, and it does not work. Windows reads the value only when the container boots, so a value that you change later has no effect on that container.

Use the image as the `image:` of the service. The service still mounts the runner and Git and sets `PATH`, as in the shipped stack file. Build one image for each Server Core tag, push it to a registry that every Windows node can reach, and rebuild it after each Patch Tuesday update of the base image.

> [!WARNING]
> Never use `New-Item -Force` on an existing registry key, in an image build or in a running container. It replaces the key and deletes its values and subkeys. On the `cexecsvc` service key, it makes the container fail to start with `hcs::System::Start: context deadline exceeded`. Use `reg add` or `Set-ItemProperty`, which set one value.

An image like this is not part of the default path, and this repository does not build or test it. Before you rely on a long runner drain, test it. Run a job of a few minutes on a node that is not in production, force an update of its service with `docker service update --force`, and check that the job finishes.

## Recycle a class

A forced update replaces every replica of a service, one at a time, each with a runner drain. Use it to move a persistent class to a new runner version, or to reset it.

```console
$ docker service update --force runners_linux-persistent
```

A persistent class keeps state between jobs, and recycling removes only the container filesystem. The named volume survives, so `/home/circleci` on Linux and `C:\cache` on Windows keep their files. To reset the volume as well, scale the service to 0. Then run `docker volume rm runners_persistent-home` (Linux) or `docker volume rm runners_windows-persistent-cache` (Windows) on the node that holds the volume, and scale the service back up.

On Linux, the runner of a persistent class does not clean its working directory. The runner user cannot remove files that the job user owns, so the stack sets `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` to `"false"`. Files from one job stay for the next job until the container is replaced. Start every job on that class with a step that removes what an earlier job left, and recycle the class on a schedule. Refer to [Working directory cleanup](security.md#working-directory-cleanup).

## Free disk space

Each finished job leaves a stopped container on the node until Swarm prunes its task. Keep the history short, and prune what Docker no longer needs.

```console
$ docker swarm update --task-history-limit 2
$ docker system df
$ docker image prune
```

On a node that runs a docker-build class, jobs also leave images, volumes, and build cache in the engine. Clean those with `docker builder prune` and `docker image prune`.

## Uninstall

1. Remove the stack. Swarm sends SIGTERM to the tasks, so running jobs get the grace period to finish.

   ```console
   $ docker stack rm runners
   ```

2. Remove the secrets, and the volumes of persistent classes.

   ```console
   $ docker secret rm linux-default-token linux-java-token linux-hardened-token
   $ docker volume rm runners_persistent-home
   ```

   The volume of the Windows persistent class is `runners_windows-persistent-cache`.

   The volume `runners_runner-bin` holds the runner (and Git on Windows) and stays on every node after `docker stack rm`. Remove it on every node, on Windows after the last container of the stack is gone:

   ```console
   $ docker volume rm runners_runner-bin
   ```

3. Remove the nodes from the Swarm. Run `docker swarm leave` on each worker, then `docker swarm leave --force` on the last manager. No node has files outside Docker to remove.
