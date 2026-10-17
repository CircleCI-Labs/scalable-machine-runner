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

### Monitor the token proxy

Every claim of a single-task class goes through the service `token-proxy` (on Windows `token-proxy-windows`, with `docker service ps runners_token-proxy-windows`, the same log lines, and the health check `curl.exe` against `/healthz`). It runs as one replica, and the runners cannot claim without it. Refer to [The token proxy](concepts.md#the-token-proxy). Check it with:

```console
$ docker service ps runners_token-proxy
$ docker service logs --tail 30 runners_token-proxy
```

The proxy answers `GET /healthz` with 200 when every class has a usable token file. Swarm runs the check every 10 seconds, shows `healthy` in `docker ps` on the node, and restarts the task after 3 failures. A start can take up to 25 seconds before the proxy listens (it asks CircleCI about every class at once, then gives up on a class that does not answer), so the check has a `start_period` of 30 seconds on Linux and 40 on Windows. The log has one line for each event, and never a token:

| Log line | Meaning |
|---|---|
| `listening on :8080, upstream <host>, classes tasks.linux-default,...` | The proxy started, with the classes it serves: one for every secret `<service>-token` that it holds. A class that is missing here is a class whose runners get 403, and its secret is not mounted in `token-proxy` (or is not named `<service>-token`) |
| `claim from <ip> (tasks.<service>): upstream status 204` | A runner polled and there was no task. Normal, about every 5 seconds for each idle runner |
| `claim from <ip> (tasks.<service>): upstream status 200` | A claim returned a task, and the runner at that address cannot claim again |
| `released <ip> (tasks.<service>)` | DNS has not listed the address for 30 seconds in a row: the container is gone, and a new container on that address can claim |
| `claim from <ip> refused: not a runner of any class (tasks.<service> lists [...], ...)` | A container that is not a runner of a configured class, or a runner that DNS does not list yet. The line names what DNS lists for every class, so compare the address with it. Look for a class that you added without adding it to the proxy, or for a container that does not belong on a class network |
| `claim from <ip> refused: this runner has already claimed a task` | A second claim from one container. After a proxy restart every runner that was idle gets this until Swarm replaces it. Refer to [Restart the proxy](#restart-the-proxy) |
| `claim from <ip> refused: too many claims` | One container sent more than 2 claims a second (answer 429). A runner claims about every 5 seconds, so this is not a runner that works |
| `state: cannot write it: ...`, and `claim from <ip> refused: the state cannot be written` | The proxy cannot save its state (the volume `proxy-state` is full or gone). A claim that has already been answered by CircleCI gets 503 instead of its task, the proxy removes `state.json` and reports unhealthy, and Swarm restarts it after 3 failed checks. Refer to [When the proxy cannot save its state](#when-the-proxy-cannot-save-its-state) |
| `poll: cannot resolve the runners, no latch is released: ...` | Swarm DNS fails. No latch is released while it fails (at most one line a minute) |
| `claim from <ip> (tasks.<service>): upstream status 401` | CircleCI rejects the class token. The token was deleted, or the secret holds another class's token. Refer to [The runner log shows 401](troubleshooting.md#the-runner-log-shows-401) |
| `upstream error: ...` | The node of the proxy cannot reach `runner.circleci.com`. The runners get 502 |
| `cannot resolve the runners`, or `token file` | Swarm DNS or a class secret is unavailable. The runners get 503 |

**If the proxy is down.** Runners cannot claim, so CircleCI keeps the jobs queued. Idle runners keep polling and fail, and they do not go around the proxy, because they hold only the placeholder. A runner that is running a job keeps its container: the runner and the task agent call the API through the proxy too, because the runner hands its own API URL to the agent, and those calls fail while the proxy is down. `linux/tests/proxy.sh` measures this with the real runner: a proxy that restarts while jobs run does not end them, and a proxy that is down when the jobs end, and for a while after, only delays the report: the runner sends the end of the job (step end and cleanup) once the proxy is back, and exits 0. The end-to-end test on CircleCI restarts the proxy in the middle of a real job on a real agent as well (the probe `b2`). Swarm restarts a failed proxy task after 5 seconds, and a restart takes a few seconds, so an outage of that length is harmless. Do not leave the proxy down for long while jobs run: how long the real task agent keeps retrying is not documented.

#### Restart the proxy

A restart is safe at any time, on the same node. The proxy keeps the addresses of the runners that have claimed in the volume `proxy-state` and refuses only those after the restart. A runner that has not claimed, idle or just started, may claim afterwards, so no restart, deploy, or node reboot locks a runner out. The start line of the log says what the proxy found, and then what it did for every class:

| Log line at start | State |
|---|---|
| `state restored; <class>: N runner(s) have claimed and stay refused; the others may claim` | The normal case: the state was read, and N addresses of that class have claimed. All N stay refused, also those that Swarm DNS does not list at that moment (an empty or partial answer right after a restart), until DNS has not listed them for 30 seconds in a row |
| `no state (a first start); <class>: CircleCI reports 0 running tasks, ...: the N runner(s) present may claim` | `proxy-state` was empty, and CircleCI says that no task of the class runs, so no runner present can be holding one |
| `no state (a first start); <class>: CircleCI reports M running task(s), ...: failing safe, latching the N runner(s) present` | `proxy-state` was empty, and tasks of the class run: the proxy cannot tell which runners hold them, so it refuses every runner present until Swarm replaces it |
| `...: CircleCI does not say how many tasks run (<error>): failing safe, latching the N runner(s) present` | The same, because the call to CircleCI failed or its answer had no count of running tasks |
| `state lost; ...` and `no state directory; ...` | The marker is there but the state file is not (damaged or removed), or the proxy has no state directory at all: the same decision for every class, from what CircleCI says |

**With no state the proxy asks CircleCI.** For each class that has runners present, it calls `GET /api/v3/runner/scale` on the runner API with the token of that class, up to three times, for all classes at once and within 25 seconds in all. The answer must hold `data.attributes.running_task_count` and `data.attributes.unclaimed_task_count`, each a whole number of 0 or more. With no running task, the runners present may claim. With a running task, or when the call fails, is late, or answers anything else, the proxy latches every runner of that class present, so a runner that already holds a job cannot claim a second one. A refused runner gets 403 (`this runner has already claimed a task`) until it recycles: at its idle timeout (1 hour in the shipped files), or at once with the command below.

**Why 403, and not 401.** A refused runner keeps its container and polls again until its idle timeout. It was tested whether an answer of 401 would make the runner exit at once, so that Swarm replaces it with a container on a new address: the real runner 3.1.13, in single-task mode against the fake API, answers a 401 on a claim, and a 403, in the same way. It logs the error, claims again about every 5 seconds, and exits 0 only when its idle timeout ends (checked with an idle timeout of 5 minutes and 61 claims, all answered 401). The proxy therefore keeps 403, and replacing the idle runners is the command below, or a shorter `CIRCLECI_RUNNER_IDLE_TIMEOUT`. A runner that is running a job is not affected, and a runner that starts after the proxy is allowed. A class that is new to the state (you added it with an add-on stack file) is treated the same way.

Replace the idle runners of a class at once with:

```console
$ docker service update --force --update-parallelism 0 runners_linux-default
```

A busy replica finishes its job before Swarm replaces it. Restart the proxy for a rotation, for a new binary, or for a change of its settings:

```console
$ docker service update --force runners_token-proxy
```

A stop (this command, a deploy, or a node that shuts down) lets the claims in flight finish, for 8 seconds at most, before the proxy exits: a claim that CircleCI has answered, and that is saved, reaches its runner. The default grace of Swarm is 10 seconds.

The proxy runs from its image, so a restart does not change its version: the same tag or digest as before, unless the tag has moved since (`latest` moves with a release, `edge` with a merge to the main branch that passed the end-to-end tests). [Upgrade the token proxy](#upgrade-the-token-proxy) says how to change the image on purpose.

#### When the proxy cannot save its state

The proxy saves a runner's address before it hands the task to the runner. If the save fails (the volume `proxy-state` is full, read-only or gone), it does not hand the task over: the runner gets 503, and it stays refused (403) from then on, and every other claim gets 503 without reaching CircleCI. The proxy also deletes `state.json`, so that no restart can read a state that is behind, and reports unhealthy. CircleCI has already allocated that one task to the runner, which never runs it, so the job waits for CircleCI to give up on it: rerun the job if it does not. Swarm restarts the proxy after 3 failed health checks, and, because the state file is gone, the restart takes the same path as a lost state: it asks CircleCI, and refuses every runner of a class that has running tasks. Mend the volume (free space, or fix the mount) before or right after: the proxy refuses to start when it cannot write its state directory, and it writes the whole state again with the next claim or poll that succeeds.

#### Where the proxy runs, and when it moves

The proxy runs on a manager by default (`node.role == manager`), with no label. In a cluster with one manager it never moves. Its state, the addresses of the runners that have claimed, is the volume `proxy-state` of the node that it runs on.

**The worst case.** If the proxy moves to another node, its state is lost: the new node has an empty volume. A move happens by itself when its node is down and another manager matches, and it happens by hand when you change the placement. The proxy then asks CircleCI for each class (the previous section), and what the runners see depends on the answer:

- **No running task in the class.** Every runner present may claim, which is right: none of them holds a job.
- **Running tasks in the class, or no answer.** The proxy **refuses the existing runners** of that class (403, `this runner has already claimed a task`) until they recycle. A runner that is running a job is not affected. Replace the idle ones at once with `docker service update --force --update-parallelism 0 runners_<service>` for each class. This is the safe side: no runner can claim twice.

There is nothing to set before a planned move. To move the proxy by hand:

```console
$ docker service update --constraint-rm 'node.role == manager' --constraint-add 'node.hostname == <new manager>' runners_token-proxy
```

If no node matches (the only manager is down), the service stays pending and no runner can claim in the meantime.

**Several managers.** The default lets the proxy start on any of them, so a failure of its node moves it. To keep it on one, label that manager and say so at deploy time, in the environment of `docker stack deploy`:

```console
$ docker node update --label-add machine-runner-swarm.proxy=true <manager>
$ sudo env MACHINE_RUNNER_SWARM_PROXY_PLACEMENT='node.labels.machine-runner-swarm.proxy == true' docker stack deploy -c deploy/runners.yaml runners
```

The label then pins the proxy to a node of your choice, a manager or a worker. If that node dies, the service stays pending until you label another one, and the move is the planned one above. Keep a manager that runs few jobs for the proxy: it holds every class token.

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

#### The version policy

The runner version is operator-pinned, as it is for CircleCI's own runners. The default is an exact pin, and a floating value is an opt-in:

| `MACHINE_RUNNER_SWARM_RUNNER_VERSION` | What the nodes run | Does it change by itself |
|---|---|---|
| An exact version, `3.1.13` (the default) | That version. The default is the newest runner version that the CI of this repository tests, and each release of this repository bumps it ([how](releasing.md#bump-the-runner-version)). The stack file carries the SHA-256 values of its tarballs, so the install does not rest on the manifest | Never. Once the version is installed, the distributor makes no request for it |
| `3.1` | The newest `3.1.x` of CircleCI's manifest | Yes: at every `MACHINE_RUNNER_SWARM_CHECK_INTERVAL` (default 24 hours) |
| `3` | The newest `3.x.y` of the manifest | Yes, at every check interval |
| `current` | CircleCI's current release, within `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` (default `3`) | Yes, at every check interval |

The distributor resolves a floating value from the manifest of CircleCI, and asks the manifest again at every check interval **only for a floating value**. An exact pin never changes by itself: a new release of the runner, or of this repository, changes nothing on your nodes until you change the pin or deploy a release that carries a newer one. In a stack file, put a floating value in quotes (`"3.1"`), because YAML reads an unquoted `3.1` as a number, and `3.10` as `3.1`.

**Floating is weaker.** The default pin is checked against the SHA-256 values in the stack file, which come with the release of this repository that you deployed. A floating value cannot keep such a list, because the version is not known in advance: the distributor ignores the default list (it names the pinned version only) and takes the SHA-256 of each tarball from the `manifest.json` of CircleCI. That file comes from the same release bucket as the tarball, so whoever can change one can change both, and the check then proves only that the download is whole. Choose a floating value for a class that may run whatever CircleCI releases, and keep the default pin for the rest.

An upgrade, a pin, and a rollback change the distributor only, whatever the policy is: the runner services never restart.

#### How this compares with machine runner 3, container runner and the orchestrator

CircleCI's own runners leave the version to the operator as well, and differ in what they offer to float on:

| | How the version is chosen | Floating |
|---|---|---|
| Machine runner 3 on a host | The operating system package (`apt`, `yum`, Homebrew) or a manual install. The runner has no auto-update, so you update the package yourself | The package manager's latest, when you run it |
| Container runner | The `tag` of the image in the Helm values. You set it, and the Helm chart is pinned to a major version tag | The image has a floating tag for each major and minor version (`kubernetes-3`, `kubernetes-3.0`), and a fixed tag for each patch release |
| Machine runner orchestrator | The Helm chart, and the container disk image of the pool | The default image tag floats to the latest published image, and each release has a dated tag that pins it |
| This repository | `MACHINE_RUNNER_SWARM_RUNNER_VERSION` of the distributor service | `3.1`, `3` and `current` float. The default is an exact pin |

This is the model of container runner: an exact pin for production, a floating tag when you want the newest patch release of a line. The default here is the exact pin, so a deploy of the same files always gives the same runner. Choose `3.1` to take patch releases of the line that you have tested, and `current` only for a class that may run whatever CircleCI releases.

#### Settings of the distributor

The settings are variables of `docker stack deploy`. They apply to the distributor service only. The file `linux/stack/runners.yaml` reads them in `x-distributor-env` and sets the defaults.

| Variable | Default | Effect |
|---|---|---|
| `MACHINE_RUNNER_SWARM_RUNNER_VERSION` | An exact version, the newest that CI tests (`3.1.13` in this release) | An exact version pins it. `3.1`, `3` and `current` float: [the version policy](#the-version-policy) |
| `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` | `3` | The major version that `current` may adopt |
| `MACHINE_RUNNER_SWARM_CHECK_INTERVAL` | `24h` | How often a floating version asks the manifest again, and how often the distributor verifies the installed copy of a pin. A number of seconds, or a number with `s`, `m`, `h`, or `d` |
| `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` | `https://circleci-binary-releases.s3.amazonaws.com/circleci-runner` | Where `manifest.json` and the tarballs are. Set it for a [mirror](#run-the-downloads-from-a-mirror). It must be an `https://` URL, unless a SHA-256 list is set |
| `MACHINE_RUNNER_SWARM_RUNNER_SHA256` | The four tarball SHA-256 values of the pinned version (`amd64`, `arm64`, `ppc64le`, `s390x`) | A comma-separated list for an exact pin, for every architecture of your nodes. The distributor installs nothing else, whatever the manifest says. An exact version of your own needs its own values (from the `checksums.txt` of its release), or the word `manifest` (no list: the hash of the manifest is trusted, which is weaker). A floating value ignores any list. Refer to [Runner binary integrity on Linux](security.md#runner-binary-integrity-on-linux) |
| `MACHINE_RUNNER_SWARM_ALLOW_HTTP` | Not set | `true` accepts an `http://` download base without a SHA-256 list. For a lab: the hash of the manifest then protects nothing against someone on the path |

The token proxy is not a setting of the distributor: it is an image. [Upgrade the token proxy](#upgrade-the-token-proxy) has its variable.

The architectures are those of CircleCI's manifest, found with `uname -m`: `amd64`, `arm64`, `ppc64le` and `s390x`. The runner tarball of a node is the one of its own architecture, and a host with another one stops the distributor with `unsupported architecture`. The token proxy image has the same four Linux platforms in one tag, so it needs no setting.

A command that sets a variable must reach `docker stack deploy`. A host with `sudo` drops the environment, so pass the variable with `env`, or run the command as a user in the `docker` group. Set the same variables on every later deploy, because a deploy without them sets the defaults again.

```console
$ sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1 docker stack deploy -c deploy/runners.yaml runners
$ sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1 linux/setup.sh --deploy --stack-file deploy/runners.yaml
```

#### What the default does

The default is an exact pin. The distributor takes the SHA-256 of the tarball from the list in the stack file (your `MACHINE_RUNNER_SWARM_RUNNER_SHA256`, when you set one), so it asks no manifest for it. It downloads the tarball, checks it, extracts the runner, records the SHA-256 of the binary, checks the copy in place again, and moves the link `current` with one atomic rename. Every one of these steps is checked: a full disk or a link that cannot move fails the check, with a line in the log, and does not end in a log line that says `[ ok ]`. When the version is installed and verified, it makes no further request: the check at every interval compares the active binary with its record, and installs the version again only when the binary changed. A new release of the runner reaches your nodes when you change the pin, or when you deploy a release of this repository that carries a newer one.

With a floating value the distributor reads `manifest.json` when it starts and at every check interval, and picks the newest version of the line (`3.1` is the newest `3.1.x`, `3` the newest `3.x.y`). With `current` it finds the version that `current` names by matching the SHA-256 of `current` to a versioned entry of the manifest, and adopts it only when its major version equals `MACHINE_RUNNER_SWARM_RUNNER_MAJOR`. For another major version it logs `not adopting it` and keeps what it has. A new release reaches every node within one check interval, with no redeploy.

To move the replicas that already wait for a job, force an update. An idle replica stops within seconds, and a busy one finishes its job first:

```console
$ docker service update --force runners_linux-default
```

A persistent class runs one container for all jobs, so it keeps its version until its container restarts. Recycle it in a quiet moment, for example with `docker service update --force runners_linux-persistent`. Refer to [Recycle a class](#recycle-a-class).

#### Pin a version

An exact version such as `3.1.12` pins that version, and the default is such a pin. The distributor installs it and never moves to another version by itself. Pin a version when a change of the runner must go through your own change process, and then upgrade by changing the pin, or by taking a newer release of this repository, which bumps its default. The list `MACHINE_RUNNER_SWARM_RUNNER_SHA256` of the stack file belongs to the default pin, so a pin of your own needs its own values, set in the same command. Take them from the `checksums.txt` of that release of the runner, for every architecture of your nodes:

```console
$ sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 \
    MACHINE_RUNNER_SWARM_RUNNER_SHA256=<sha256 of amd64>,<sha256 of arm64> \
    docker stack deploy -c deploy/runners.yaml runners
```

The distributor then installs only a tarball with one of these values, whatever the manifest says. Without the list it refuses the tarball (`SHA-256 mismatch`), and the nodes keep the version that runs. To trust the manifest instead, which is weaker ([the version policy](#the-version-policy)), set `MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest`. The same applies if you edit the pin in your copy of the stack file: change the default of `MACHINE_RUNNER_SWARM_RUNNER_VERSION` and the default of `MACHINE_RUNNER_SWARM_RUNNER_SHA256` together, in `x-distributor-env` (and in `x-env` of `microvm.yaml`, which downloads the runner itself).

The distributor switches to a version that is installed already without any network access, when the hash list is `manifest` or names that version. Use `3.1.12` or later: it fixes the enforcement of `max_run_time`.

#### Freeze the nodes now

To stop all change at once, pin the version that the nodes run now. That version is installed, so the pin needs no network. Read it first, as in [See what runs](#see-what-runs), and then update the distributor. The list of SHA-256 values belongs to the default pin, so name the hash policy together with the version (`manifest` makes no request for a version that is installed):

```console
$ docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 --env-add MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest runners_runner-distributor
```

Set the same values in the environment of your next `docker stack deploy`. A deploy without them sets the default pin and its list from the stack file again, which undoes the freeze.

#### Roll back

A rollback is a pin of an older version. The distributor keeps the last 3 versions that were active, so a rollback to one of them only moves the link: no download, and no network. A version that was removed is downloaded again, and its hash comes from the manifest or from a list that you give. The hash policy goes with the version, because the default list names the pinned version only:

```console
$ docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 --env-add MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest runners_runner-distributor
```

The next container of every runner service runs the old version. Running jobs are not affected. Set the same values in the environment of your next `docker stack deploy`, as for the pin above.

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
    for arch in amd64 arm64; do   # the architectures of your nodes
      curl -fsSL "$base/$v/circleci-runner_linux_$arch.tar.gz" -o "mirror/$v/circleci-runner_linux_$arch.tar.gz"
    done
  done
```

Serve the directory `mirror`, and point the distributor at it:

```console
$ sudo env MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=https://mirror.example.com/circleci-runner docker stack deploy -c deploy/runners.yaml runners
```

- Copy the tarballs of the architectures that your nodes have (`amd64`, `arm64`, `ppc64le`, `s390x`). With an exact pin, copy that version. With a floating version, copy the versions of its line, and copy `manifest.json` again when you want the nodes to adopt a new release. With `current`, copy the version that `current` names. The command `jq -r '.releases as $r | $r.current.linux.amd64.sha256 as $s | $r | to_entries[] | select(.key | test("^[0-9]")) | select(.value.linux.amd64.sha256 == $s) | .key' mirror/manifest.json` prints that version.
- The distributor downloads with the `wget` of the stock Alpine image and its CA bundle, so an `https` mirror needs a certificate from a public certificate authority.
- A mirror over plain `http` needs a usable SHA-256 list for an exact pin (the default one, for the pinned version, is enough): the distributor refuses an `http://` base URL without one, because the manifest would then be the only root of trust and would travel unprotected. With the list, the manifest does not decide what is installed. A floating value has no list, so it is refused over `http` for the same reason. `MACHINE_RUNNER_SWARM_ALLOW_HTTP=true` accepts it anyway, for a lab.
- The mirror replaces the runner download only. Every runner container still downloads its task agent from `circleci-binary-releases.s3.amazonaws.com`, and every node still pulls the `alpine` image of the distributor from a registry. Refer to [Does it work on hosts without internet access?](faq.md#does-it-work-on-hosts-without-internet-access).

### Upgrade the runner on Windows

The service `runner-distributor-windows` is the only way a runner and Git reach a Windows node. It works as the [Linux distributor](#upgrade-the-runner-on-linux): the same variables, the same policy, and the same rule that a runner service carries no version and no hash. An upgrade, a pin, and a rollback therefore change the distributor only. **No runner service restarts, so no busy job is killed**, which a stop would do after about 5 seconds. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container).

The distributor installs into the volume `runner-bin`, next to the versions that exist: `versions\<version>` for the runner, `git\<git version>` for portable Git. The links `current` and `git\current` are relative directory symbolic links to them, and the runner services mount the volume read-only through them: `current` at `C:\machine-runner-swarm`, and `git\current` at `C:\Program Files\Git`. Docker resolves a link when it creates a container, so the next container, which is the next job, runs the new version, and a job that runs now keeps the directory that it started with. Windows cannot replace or delete files that a running container uses, so the distributor never overwrites a version and never removes one that is in use: it tries again at its next check. `windows\tests\Test-Distributor.ps1` checks all of this in CI.

The settings are the variables of [the Linux table](#settings-of-the-distributor), set in `x-distributor-env` of `windows\stack\runners.yaml` and read from the environment of `docker stack deploy`, plus one for the pinned downloads of Git and 7-Zip:

| Variable | Effect |
|---|---|
| `MACHINE_RUNNER_SWARM_RUNNER_VERSION` | An exact version is a pin, and the default: the newest that CI tests (`3.1.13` in this release). `3.1`, `3` and `current` float, and the distributor then looks at the manifest again every `MACHINE_RUNNER_SWARM_CHECK_INTERVAL` (default `24h`): [the version policy](#the-version-policy). `current` stays within `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` (default `3`) |
| `MACHINE_RUNNER_SWARM_RUNNER_SHA256` | A comma-separated list for an exact pin. The default is the two values (`amd64`, `arm64`) of the pinned version, so the pinned install does not rest on the manifest. An exact version of your own needs its own values, or the word `manifest` (no list: the hash of the manifest is trusted, which is weaker). A floating value ignores any list |
| `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` | A mirror: `manifest.json` and `<version>/circleci-runner_windows_<arch>.tar.gz` below this URL. It must be an `https://` (or `file://`) URL, unless a SHA-256 list is set. `MACHINE_RUNNER_SWARM_ALLOW_HTTP=true` accepts `http://` for a lab |
| `MACHINE_RUNNER_SWARM_TOOLS_BASE_URL` | A directory URL that holds `PortableGit-<version>-64-bit.7z.exe` (arm64: `-arm64.7z.exe`) and `7zr.exe`, the two downloads that the script pins by SHA-256. Without it they come from GitHub |

The architecture is `amd64` or `arm64`, read from `PROCESSOR_ARCHITECTURE`. CI runs the distributor on amd64 hosts only: the arm64 file names and manifest entries are tested there, and no Windows arm64 host runs the stack in CI.

In PowerShell, set the variables in the environment of the shell that runs the deploy:

```powershell
$env:MACHINE_RUNNER_SWARM_RUNNER_VERSION = '3.1'   # trusts the hash of the manifest: weaker
docker stack deploy -c deploy\runners.yaml runners
```

- **Upgrade.** The default is an exact pin, so the nodes change version only when you change it, or when you deploy a release of this repository that carries a newer one. With `3.1`, `3` or `current`, a new release reaches every node within one check interval, with no redeploy. A deploy without the variables sets the default pin and its SHA-256 list again, so set the same values on every deploy.
- **Freeze the nodes now.** Pin the version that the nodes run now. It is installed, so the pin needs no network: `docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 --env-add MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest runners_runner-distributor-windows`.
- **Roll back.** Pin an older version, with the hash policy of that version as on Linux (`manifest`, or its own values). The distributor keeps the last 3 versions that were active, so a rollback to one of them only moves the link, with no network. A version that was removed is downloaded again.
- **See what runs.** `docker service logs runners_runner-distributor-windows` shows each flip. On the node, `docker run --rm --mount type=volume,source=runners_runner-bin,target=C:\v,readonly mcr.microsoft.com/windows/servercore:ltsc2022 powershell -Command "Get-Content C:\v\history; (Get-Item C:\v\current).Target"` shows the history and the active version.
- **Replicas that wait for a job** keep the old version until they claim a job or exit after `CIRCLECI_RUNNER_IDLE_TIMEOUT`, which is 1 hour in the stack file. A forced update replaces them at once, but it also stops the containers of the service, which kills a running job after about 5 seconds. Force the update only while the class is idle: `docker service update --force runners_windows-default`.
- **A mirror.** Copy `manifest.json` and the tarballs as for [Linux](#run-the-downloads-from-a-mirror), with `windows` and `amd64` (or `arm64`) in the names, and copy the two pinned Git downloads into the tools directory. The distributor downloads with PowerShell, so an `https` mirror needs a certificate that the stock Server Core image trusts.

A link cannot be replaced in one step on Windows, so for a moment `current` does not exist. A container that Swarm creates in that moment does not start, and Swarm starts the next one after the restart delay of 10 seconds. The window is a few milliseconds long. On a new node, the runner tasks fail in the same way until the first download of the distributor is done. The runner has no start-time check of the binary on Windows, because no entrypoint script exists: the distributor compares the active binary with its record at every check and installs it again when it changed. Refer to [Runner binary integrity on Windows](security.md#runner-binary-integrity-on-windows).

### Upgrade the token proxy

The token proxy is the image `ccilabs/machine-runner-swarm-proxy`, and the service `token-proxy` (Windows: `token-proxy-windows`) reads it from `MACHINE_RUNNER_SWARM_PROXY_IMAGE`. The tags are `X.Y.Z` (a release, which never moves), `X.Y`, `X`, `latest` (the newest release), `edge` (the newest commit of the main branch that passed the end-to-end tests, for testing main) and `sha-<12 characters>` ([The token proxy image](install-linux.md#the-token-proxy-image)). The default of a release bundle is its own release, by tag and digest. A checkout defaults to `latest`, which only a release moves.

- **Upgrade with the release.** Deploy the stack files of the new release ([Upgrade to a new release of this repository](#upgrade-to-a-new-release-of-this-repository)). They name the new image.
- **Pin a digest.** Run the proxy from `ccilabs/machine-runner-swarm-proxy@sha256:<digest>`, set in the environment of every `docker stack deploy`. A digest never changes, and it is the only pin that a re-pushed tag cannot move. Read the digest of a release in its notes and in the bundle (`grep MACHINE_RUNNER_SWARM_PROXY_IMAGE stack/runners.yaml`), or with `docker buildx imagetools inspect ccilabs/machine-runner-swarm-proxy:<version>`, and check the signature before you trust it ([Verify the token proxy image](security.md#verify-the-token-proxy-image)).
- **Change the image of the running service.** `docker service update --image <image> runners_token-proxy`. Swarm stops the old proxy and starts the new one (`stop-first`: a second proxy would allow a second claim), so the runners cannot claim for the few seconds of the change, and every runner that has claimed stays refused ([Restart the proxy](#restart-the-proxy)). Record the change in your deploy, so that the next deploy does not undo it. A tag such as `latest` is resolved to a digest when you deploy: run `docker stack deploy` again to pick up a newer one.
- **Roll back.** Deploy the previous digest or version the same way.

An air-gapped site mirrors the image: `docker pull`, then `docker tag` and `docker push` to your registry (`docker buildx imagetools create --tag <your registry>/<name>:<tag> ccilabs/machine-runner-swarm-proxy:<version>` keeps every platform), and `MACHINE_RUNNER_SWARM_PROXY_IMAGE=<your registry>/<name>:<tag>`. Keep the signature with it: `cosign copy` copies the image with its signature.

### Update the images

- **Linux and Windows stock images.** Change the tag or digest of `image` in your stack file, and run `docker stack deploy`. Swarm resolves a tag to its digest when you deploy, so deploy again to pick up a tag that the publisher re-pushed.
- **The distributor image.** The service `runner-distributor` runs `alpine:3`, pinned by digest. Change the digest in your stack file to move to a newer Alpine, and deploy. The distributor restarts on every node at once, and no running job is affected.
- **Your own images.** Rebuild, push, change the tag, and deploy. Rebuild on a schedule, for example monthly, and when the base image or a tool changes.
- **Windows base images.** Microsoft republishes the Server Core tags each Patch Tuesday. Pin by digest, and rebuild your own images on top of them after each update. Change a Windows service only while its class is idle. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container).

For a single service, you can also run `docker service update --image <new image> runners_<service>`. Record the change in your stack file, so that the next deploy does not undo it.

### Upgrade to a new release of this repository

1. Read the [changelog](../CHANGELOG.md). Entries marked `[BREAKING]` say what to change.
2. Compare your stack file with the file of the new release, and merge the differences. Look at the defaults of `x-distributor-env` first: a release bumps the runner version and its `MACHINE_RUNNER_SWARM_RUNNER_SHA256` values together, and your copy keeps the old pair until you merge both.
3. Decide what the nodes run, and write it down in your copy of the stack file, so that no one has to remember a variable. Take the pin of the new release by merging both defaults, or keep your own pin by setting its two defaults (the version, and the list of SHA-256 values or `manifest`). A pin, a freeze or a rollback that you made only with `docker service update` is not in the file: the next `docker stack deploy` sets the defaults of the file again and undoes it silently.
4. Run `docker stack deploy` with the same set of `-c` files as before, and with the same distributor variables as before (a variable of the deploy beats the default of the file).
5. Check what the nodes run: `docker service logs --tail 5 runners_runner-distributor` shows the version that the distributor selected, and [See what runs](#see-what-runs) the version that is active.

The entrypoint and the script of the distributor are Swarm configs, so this command is the whole upgrade. A Swarm config cannot change, so the name of each config carries the first 12 hex digits of the SHA-256 of its file. A release that changes the entrypoint or the script has new names. `docker stack deploy` creates the new config and updates the services that use it: the runner services one replica at a time, as in [Upgrade the runner and images](#upgrade-the-runner-and-images), and the distributor on every node.

If you edit one of these files in your own copy, rename the config in your stack file after each edit, or Swarm keeps the old file. The new name is the old prefix and the first 12 digits of the new hash:

```console
$ sha256sum linux/stack/circleci-runner-entrypoint | cut -c1-12
$ sha256sum linux/stack/runner-distributor.sh | cut -c1-12
```

In a clone of this repository, `ci/config-names.sh --write` renames the configs of the shipped stack files.

## Rotate a runner token

Swarm secrets are immutable. To rotate a token, create a second secret and swap it into the service that holds it. On Linux, that is the `token-proxy` service for a single-task class: one replica, so the swap takes seconds, and the runners are not touched. For a persistent class and on Windows it is the service of the class itself. The rolling update replaces one replica at a time, and busy runners finish their job first. The update is serial per replica: the shipped stack files set `update_config.parallelism: 1`, and a busy replica is replaced only after its job ends, which takes up to the grace period of 5 hours and 5 minutes. A service with N replicas can therefore take up to N times that long to finish the swap. To shorten it, raise `update_config.parallelism` in the stack file, or pass `--update-parallelism <number>` to `docker service update` for one update (`0` replaces every replica at once).

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

3. Swap the secrets in the service. On Linux, for a single-task class, swap it in the proxy. Keep the `target`: the proxy names a class after the file `<service>-token`, and a new name makes a new class that no runner belongs to:

   ```console
   $ docker service update \
       --secret-rm linux-default-token \
       --secret-add source=linux-default-token-v2,target=linux-default-token,uid=65534,gid=65534,mode=0400 \
       runners_token-proxy
   ```

   The proxy restarts, and the idle runners of every class get 403 until Swarm replaces them. Replace them at once with `docker service update --force --update-parallelism 0 runners_<service>` for each class, or wait for their idle timeout. Refer to [Restart the proxy](#restart-the-proxy).

   On Linux, for a persistent class, swap it in the service itself:

   ```console
   $ docker service update \
       --secret-rm linux-persistent-token \
       --secret-add source=linux-persistent-token-v2,target=circleci_runner_config.yaml,uid=2000,gid=2000,mode=0400 \
       runners_linux-persistent
   ```

   On Windows, a single-task class is swapped in the proxy as well (secrets have no `uid`, `gid`, or `mode`, and the target is the file of the class in the proxy):

   ```powershell
   docker service update `
     --secret-rm windows-default-token `
     --secret-add source=windows-default-token-v2,target=windows-default-token `
     runners_token-proxy-windows
   ```

   On Windows, for the persistent class, swap it in the service itself, with the target `circleci_runner_config.yaml`.

4. Wait until the update completes. The state is `completed`:

   ```console
   $ docker service inspect --format '{{.UpdateStatus.State}}' runners_token-proxy
   ```

5. Record the new name in your stack file: change `source:` and the entry under the top-level `secrets:` (for the proxy, the `source:` of the class under `token-proxy`). A later `docker stack deploy` from the old file then does not revert the swap.
6. Revoke the old token in CircleCI, and remove the old secret.

   ```console
   $ circleci runner token list --resource-class <namespace>/linux-default
   $ circleci runner token delete <token ID>
   $ docker secret rm linux-default-token
   ```

### If a token leaked

Do not swap first. Until the old token is deleted in CircleCI, it stays valid for anyone who holds it. For a class that holds its token in its runners (a persistent class, or Windows), the swap above can take up to N times 5 hours and 5 minutes for N replicas, because it replaces one replica at a time and each busy replica finishes its job first. For a single-task class on Linux the swap is in the proxy and takes seconds, but the leak itself means that someone reached the proxy's node or the secret, so read the end of this section. Delete the token as soon as its replacement exists:

1. Create the new token, and the secret with the new token. Use the steps 1 and 2 above. Nothing uses the new secret yet.
2. Delete the old token at once.

   ```console
   $ circleci runner token list --resource-class <namespace>/linux-default
   $ circleci runner token delete <token ID>
   ```

   CircleCI stops accepting the old token for new claims, so nobody can start a runner on the class with it. Jobs that already run continue until they end. A proxy that still holds the old secret, or idle runners of a persistent class or Windows that still hold it, fail with 401 until the swap, so the class claims no new jobs until step 3 completes.
3. Swap the secrets. For a single-task class on Linux, swap it in the proxy with the command of step 3 above, and replace the idle runners (`docker service update --force --update-parallelism 0 runners_<service>`). For the other classes, replace every replica at once so that the class recovers soon:

   ```console
   $ docker service update --update-parallelism 0 \
       --secret-rm linux-default-token \
       --secret-add source=linux-default-token-v2,target=circleci_runner_config.yaml,uid=2000,gid=2000,mode=0400 \
       runners_linux-default
   ```

   Each replica still finishes the job that it runs before Swarm replaces it. On Windows, drop `uid`, `gid`, and `mode`, and expect the update to end a running job after about 5 seconds: rerun those jobs. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container).
4. Do steps 4 and 5 above (wait for the update, record the new name in your stack file), and remove the old secret with `docker secret rm linux-default-token`. Then look for what the leaked token did: the runner inventory in CircleCI for names you do not know, and the jobs that ran on the class.

A leaked token of a single-task class on Linux did not come from a job in a runner container, because those hold no token. Look at who can read Swarm secrets (the `docker` group on a manager), at the node that runs the proxy, and at the backups of the managers. Rotate the tokens of every class whose secret that path reached, because the proxy holds all of them.

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

Draining the node that runs `token-proxy` moves the proxy to another node that matches its placement, and its state stays behind ([Where the proxy runs, and when it moves](#where-the-proxy-runs-and-when-it-moves)). Draining every manager, or the only node that can run it, leaves the proxy `Pending` and stops every claim: keep one node undrained for it ([the warning in Multi-Node Clusters](multi-node.md#managers-and-quorum)).

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
   $ docker secret rm linux-default-token runner-placeholder-token   # and the <service>-token of every other class you deployed
   $ docker volume rm runners_persistent-home runners_proxy-state
   ```

   The volume of the Windows persistent class is `runners_windows-persistent-cache`, and the Windows proxy keeps its state in `runners_proxy-state` too.

   The volume `runners_runner-bin` holds the runner (and Git on Windows) and stays on every node after `docker stack rm`. Remove it on every node, on Windows after the last container of the stack is gone:

   ```console
   $ docker volume rm runners_runner-bin
   ```

3. Remove the nodes from the Swarm. Run `docker swarm leave` on each worker, then `docker swarm leave --force` on the last manager. No node has files outside Docker to remove.
