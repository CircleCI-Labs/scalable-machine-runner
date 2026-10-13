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

Healthy single-task replicas show a steady stream of tasks that end in `Complete`, because every finished job ends a task. A task that ends in `Failed` with `task: non-zero exit` needs attention. Alert on these signals:

- Tasks that end with a non-zero exit code, including 80 and 1. Code 143 is the exception: a replica that gets SIGTERM while it still retries to reach CircleCI at start-up exits with 143, and needs no action.
- Log lines that start with `circleci-runner: error` or `circleci-runner-entrypoint: error`, and lines that contain `401`.
- Tasks that stay `Pending`.

In the web app, select **Runners** to see the replicas of each class in the inventory. A name that you do not recognize means that someone else holds a token of that class.

## Run the cluster

The sections below cover what a team that runs the stack in production needs beyond the day-one commands: logs that survive, signals to watch, capacity, backups, certificates, and what a failure costs.

### Ship the logs

`docker service logs` reads the logs of the tasks that Swarm still holds. Every finished job ends a task, and the task history limit of 2 makes Swarm prune old tasks and their containers, so the log of a job is gone after a few more jobs. The stack files keep the logs on the node, with the `local` driver on Linux (3 files of 20 MB) and `json-file` on Windows, and rotate them.

To keep logs for incidents, move them off the node. Choose one:

- **A logging driver.** Change `logging:` in your copy of every stack file to a driver that ships logs, such as `syslog`, `fluentd`, or `gelf`. The stack files set the driver per service, so a default in `daemon.json` does not apply. `docker service logs` then works only for drivers that can be read back, which these are not.
- **A log agent on every node.** Run an agent that reads container logs through the Docker API and forwards them. The stack files stay as they are, and `docker service logs` keeps working.

Keep the lines that start with `circleci-runner-entrypoint:` and `circleci-runner:`, and alert on the signals in [Check status and logs](#check-status-and-logs).

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

Managers go one at a time so the quorum holds: with three managers, one is down at most. Leave mixed Docker versions in place only for the length of the upgrade. The runner and the entrypoint upgrade separately, with no stop. Refer to [Upgrade the runner on Linux](#upgrade-the-runner-on-linux).

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

> [!NOTE]
> Draft of a new default: with the [runner distributor](runner-distributor.md) there is no install on the host, and an upgrade is a change of three pins and `docker stack deploy`. The steps below stay valid until it replaces them.

The runner lives on the host in `/opt/machine-runner-swarm/<version>/bin`, not in the images. The stack mounts the link `/opt/machine-runner-swarm/current` at `/opt/machine-runner-swarm`. An upgrade installs the new version next to the old one and moves the link. Docker follows the link when it creates a container, so every new container, which is the next job of every replica, runs the new version. A job that runs now finishes on the old version, because its container keeps the directory that it started with. Nothing stops, so no job is interrupted.

1. Pick the new version. Use the latest `3.1.x` or later, and never a version below 3.1.12. The [runner changelog](https://circleci.com/changelog/runner/) lists releases.
2. On every node, install the new version and move the link. The helper downloads the runner, verifies the checksum from the release's `checksums.txt`, installs it into `/opt/machine-runner-swarm/<new version>`, and then replaces the link with one atomic rename:

   ```console
   $ sudo linux/setup.sh --install --version <new version> --sha256 <hash>
   ```

   The hash is the one of the `circleci-runner_linux_<arch>.tar.gz` file of the node's architecture. To do it by hand, repeat the commands of [Install the runner and the entrypoint](install-linux.md#3-install-the-runner-and-the-entrypoint) with the new directory, and then move the link: `ln -s <new version> /opt/machine-runner-swarm/.current.new && mv -T /opt/machine-runner-swarm/.current.new /opt/machine-runner-swarm/current`.

3. Check the version on each node:

   ```console
   $ readlink /opt/machine-runner-swarm/current
   $ /opt/machine-runner-swarm/current/bin/circleci-runner --version
   ```

4. Move the replicas that already wait for a job. A replica that is idle keeps the old version until it claims a job or exits after `CIRCLECI_RUNNER_IDLE_TIMEOUT`, which is 1 hour in the stack files. A persistent class runs one container for all jobs, so it keeps the old version until you recycle it. To move a service now, force an update. An idle replica stops within seconds, and a busy one finishes its job first:

   ```console
   $ docker service update --force runners_linux-default
   ```

5. To roll back, run the same command with the previous version. A version that is installed is not downloaded again, and the command only moves the link back. Then force the update again.

   ```console
   $ sudo linux/setup.sh --install --version <previous version>
   ```

6. Delete the old version when no container uses it: `sudo rm -rf /opt/machine-runner-swarm/<old version>`. The entrypoint always comes from the checkout that you run the helper from, and every run copies it into the version directory.

#### Install on every node with one command

A Swarm global job runs a short script on every node from a small image, so you do not log in to each node. The script `linux/install-job.sh` does what `setup.sh --install` does with the tools of Alpine (BusyBox): `wget`, `sha256sum`, and `tar`. It reads the architecture from `uname -m`. The job mounts `/opt` of the node, and the entrypoint reaches it as a Swarm config, because it comes from this repository and not from the runner release. Run it on a manager node:

```console
$ docker config create machine-runner-swarm-entrypoint-<date> linux/entrypoint/circleci-runner-entrypoint
$ docker service create --name runner-install --mode global-job --restart-condition none \
    --constraint node.platform.os==linux \
    --mount type=bind,source=/opt,target=/host-opt \
    --config source=machine-runner-swarm-entrypoint-<date>,target=/circleci-runner-entrypoint,mode=0444 \
    --env MACHINE_RUNNER_SWARM_VERSION=<new version> \
    --env MACHINE_RUNNER_SWARM_SHA256_AMD64=<hash> --env MACHINE_RUNNER_SWARM_SHA256_ARM64=<hash> \
    alpine:3.22 sh -c "$(cat linux/install-job.sh)"
$ docker service ps runner-install
$ docker service rm runner-install
```

`docker service ps` shows one task for each node, and every task ends in `Complete`. Read `docker service logs runner-install` for the line `[ ok ] ... current -> <version>` of each node. Then continue with step 4 above. Notes:

- A global job runs on the nodes that exist when you create it. A node that joins later has no install, so run the helper on it, or remove the job and create it again.
- Swarm configs are immutable. Create a new config, with a new name, for each change of the entrypoint.
- To roll back, create the job again with the previous version. An installed version is only switched to.
- The job runs as root and writes to `/opt` of every node, so start it only from a manager that you trust. Pin the image by digest in production. Every node needs HTTPS access to `circleci-binary-releases.s3.amazonaws.com`.

### Upgrade the runner on Windows

The layout is the one of Linux. Each version has its own directory, `C:\machine-runner-swarm\<version>`, and the junction `C:\machine-runner-swarm\current` points to the installed version. The stack mounts the junction. Docker follows it when it creates a container, so the next container, which is the next job, runs the new version, and a job that runs now keeps the directory that it started with. `windows\tests\Test-Upgrade.ps1` checks this in CI. Windows cannot replace files that a running container uses, so never overwrite a version directory.

1. On every Windows node, stage the new version next to the old one. The helper downloads the runner and Git, verifies the checksums, and moves the junction:

   ```powershell
   .\windows\Setup.ps1 -RunnerVersion <new version> -StageOnly
   ```

   By hand, repeat the steps of [Stage the runner and Git](install-windows.md#3-stage-the-runner-and-git) with the new `$runnerVersion`.

2. Check the version on each node:

   ```powershell
   (Get-Item C:\machine-runner-swarm\current).Target
   C:\machine-runner-swarm\current\bin\circleci-runner.exe --version
   ```

3. A replica that already waits for a job keeps the old version until it claims a job or exits after `CIRCLECI_RUNNER_IDLE_TIMEOUT`, which is 1 hour in the stack file. A forced update replaces it at once, but it also stops the containers of the service, which kills a running job after about 5 seconds. Force the update only while the class is idle. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container).

   ```powershell
   docker service update --force runners_windows-default
   ```

4. To roll back, run the helper with the previous version. It is staged already, so the command only moves the junction back:

   ```powershell
   .\windows\Setup.ps1 -RunnerVersion <previous version> -StageOnly
   ```

5. Delete the old version directory when no container uses it.

A junction cannot be replaced in one step, so for a moment `current` does not exist. A container that Swarm creates in that moment does not start, and Swarm starts the next one after the restart delay of 10 seconds. The window is a few milliseconds long.

### Update the images

- **Linux and Windows stock images.** Change the tag or digest of `image` in your stack file, and run `docker stack deploy`. Swarm resolves a tag to its digest when you deploy, so deploy again to pick up a tag that the publisher re-pushed.
- **Your own images.** Rebuild, push, change the tag, and deploy. Rebuild on a schedule, for example monthly, and when the base image or a tool changes.
- **Windows base images.** Microsoft republishes the Server Core tags each Patch Tuesday. Pin by digest, and rebuild your own images on top of them after each update. Change a Windows service only while its class is idle. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container).

For a single service, you can also run `docker service update --image <new image> runners_<service>`. Record the change in your stack file, so that the next deploy does not undo it.

### Upgrade to a new release of this repository

1. Read the [changelog](../CHANGELOG.md). Entries marked `[BREAKING]` say what to change.
2. Compare your stack file with the file of the new release, and merge the differences.
3. Install the new `circleci-runner-entrypoint` on every Linux node. The install step copies the runner and the entrypoint together into the version directory. A new release can change the entrypoint, and the stack runs the copy behind `/opt/machine-runner-swarm/current`. Run `sudo linux/setup.sh --install --version <installed version>` from the new checkout, which refreshes the entrypoint and keeps the version.
4. Run `docker stack deploy` with the same set of `-c` files as before.

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

A forced update replaces every replica of a service, one at a time, each with a runner drain. Use it to pick up a new runner binary on the host, or to reset a persistent class.

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

3. Remove the nodes from the Swarm. Run `docker swarm leave` on each worker, then `docker swarm leave --force` on the last manager.
4. Remove the host files:

   ```console
   $ sudo rm -rf /opt/machine-runner-swarm
   ```

   ```powershell
   cmd /c rmdir C:\machine-runner-swarm\current
   Remove-Item C:\machine-runner-swarm -Recurse -Force
   ```

5. Remove the images that you no longer need with `docker image rm`.
6. In CircleCI, delete the tokens and then the resource classes. A class cannot be deleted while it has tokens.

   ```console
   $ circleci runner token list --resource-class <namespace>/linux-default
   $ circleci runner token delete <token ID>
   $ circleci runner resource-class delete <namespace>/linux-default
   ```

7. On Windows, keep BitLocker on if the host holds other data.
