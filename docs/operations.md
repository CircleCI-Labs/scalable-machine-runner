---
page-title: Operations
page-audience: admin
page-description: Status and logs, monitoring, capacity, backups, runner upgrades, token rotation, node drain, and uninstall for the Swarm runner stack.
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
- Many tasks of one node that end within seconds, one after another. A node can stay `Ready` and still fail every job it claims. Refer to [Many jobs fail within seconds on one node](troubleshooting.md#many-jobs-fail-within-seconds-on-one-node).

In the web app, select **Runners** to see the replicas of each class in the inventory. A name that you do not recognize means that someone else holds a token of that class.

## Run the cluster

The sections below cover what a team that runs the stack in production needs beyond the day-one commands: logs that survive, signals to watch, capacity, backups, certificates, and what a failure costs.

### Ship the logs

`docker service logs` reads the logs of the tasks that Swarm still holds. Every finished job ends a task, and the task history limit of 2 makes Swarm prune old tasks and their containers, so the log of a job is gone after a few more jobs. The stack files keep the logs on the node, with the `local` driver on Linux (3 files of 20 MB) and `json-file` on Windows, and rotate them.

The token proxy writes one line for every claim it forwards, a 204 included: about one line for each idle runner every 5 seconds, roughly 85 bytes each. With 50 idle runners that is about 70 MB a day, so the 60 MB of the three `local` files of the Linux proxy wrap in less than a day, and the 10 MB of the two `json-file` files of the Windows proxy in a few hours. The lines that matter after an incident (`refused`, `state restored`, `released`) are among the first to be lost. Ship the log of the proxy off the node before the fleet is large, or raise `max-file` of `token-proxy` in your copy of the stack file.

To keep logs for incidents, move them off the node. Choose one:

- **A logging driver.** Change `logging:` in your copy of every stack file to a driver that ships logs, such as `syslog`, `fluentd`, or `gelf`. The stack files set the driver per service, so a default in `daemon.json` does not apply. `docker service logs` then works only for drivers that can be read back, which these are not.
- **A log agent on every node.** Run an agent that reads container logs through the Docker API and forwards them. The stack files stay as they are, and `docker service logs` keeps working.

Keep the lines that start with `circleci-runner-entrypoint:`, `circleci-runner:`, and `runner-distributor:`, and alert on the signals in [Check status and logs](#check-status-and-logs).

### Monitor the cluster

Watch the Swarm and CircleCI. The Swarm commands run on a manager, and they need nothing but Docker.

```console
$ docker service ls
$ docker node ls
$ docker stack ps runners --filter desired-state=running --format '{{.Name}} {{.Node}} {{.CurrentState}}' | grep -v Running
```

The next command counts, for each node, the tasks that ended within the last minute or so. Every finished job ends a task, so a node with many `Complete` or `Failed` tasks that ended seconds ago either fails its jobs, or has more work than the others. Compare the nodes. Refer to [Many jobs fail within seconds on one node](troubleshooting.md#many-jobs-fail-within-seconds-on-one-node).

```console
$ docker stack ps runners --format '{{.Node}} {{.CurrentState}}' | grep -E ' (Complete|Failed) [0-9]+ seconds? ago' | cut -d' ' -f1 | sort | uniq -c | sort -rn
```

The runner API shows what CircleCI sees. It needs a personal API token. Refer to the [runner API reference](https://circleci.com/docs/reference/runner-api/). Set the host of the runner API first: `runner.circleci.com` for CircleCI cloud, and the runner API URL of your installation for CircleCI server (refer to [CircleCI server, proxies, and hosts without internet](#circleci-server-proxies-and-hosts-without-internet)).

```console
$ RUNNER_API=https://runner.circleci.com
$ curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" \
    "$RUNNER_API/api/v3/runner?resource-class=<namespace>/linux-default" \
    | jq -r '.items[] | "\(.name) \(.last_connected)"'
$ curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" \
    "$RUNNER_API/api/v3/runner/tasks?resource-class=<namespace>/linux-default"
$ curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" \
    "$RUNNER_API/api/v3/runner/tasks/running?resource-class=<namespace>/linux-default"
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
| Disk | `df -h /var/lib/docker` on every node, and `docker system df` | Above 80 percent on a worker, above 70 percent on a manager. Refer to [Free disk space](#free-disk-space) |
| A node that fails jobs | The tasks that ended within seconds, for each node (the command above) | One node far above the others, or a node with tasks that end in `Failed` over and over. Refer to [Many jobs fail within seconds on one node](troubleshooting.md#many-jobs-fail-within-seconds-on-one-node) |
| Token proxy | `docker service ps runners_token-proxy`, `docker stats --no-stream` on its node, and the summary line of its log | Restarts, CPU near the limit, or a rising count of refused claims. Refer to [Monitor the token proxy](#monitor-the-token-proxy) |
| A job that starts | A canary job for each class (below) | The canary fails, or does not start within a few minutes |

**A canary job.** Every signal above is a part. A job that runs through the whole path (the web app, CircleCI, the proxy, a node, a runner) tells you in one signal that it works. Put a project of your own on a schedule that runs this job for each class, and alert when it fails or has not started after a few minutes. Replace `<namespace>/linux-default` with the class:

```yaml
version: 2.1
jobs:
  canary:
    machine: true
    resource_class: <namespace>/linux-default
    steps:
      - run: echo ok
workflows:
  canary:
    when:
      equal: [scheduled_pipeline, << pipeline.trigger_source >>]
    jobs:
      - canary
```

The canary sees problems that the Swarm view does not: a proxy that is healthy and still refuses every runner, a class whose token CircleCI rejects, and a plan that has no concurrency left. It does not say which node is at fault: for that, use the per-node count above.

### Monitor the token proxy

Every claim of a single-task class goes through the service `token-proxy` (on Windows `token-proxy-windows`, with `docker service ps runners_token-proxy-windows` and the same log lines). It runs as one replica, and the runners cannot claim without it. Refer to [The token proxy](concepts.md#the-token-proxy). Check it with:

```console
$ docker service ps runners_token-proxy
$ docker service logs --tail 30 runners_token-proxy
```

The proxy answers `GET /healthz` with 200 when every class has a usable token file. The health check is the proxy binary itself with the flag `-healthcheck` (`/machine-runner-swarm-proxy` on Linux, `C:\machine-runner-swarm-proxy.exe` on Windows), because the images have no `curl` or `wget`. Swarm runs the check every 10 seconds, shows `healthy` in `docker ps` on the node, and restarts the task after 3 failures. A start can take up to 25 seconds before the proxy listens (it asks CircleCI about every class at once, then gives up on a class that does not answer), so the check has a `start_period` of 30 seconds on Linux and 40 on Windows. The log has one line for each event, and never a token:

| Log line | Meaning |
|---|---|
| `listening on :8080, upstream <host>, classes tasks.linux-default,...` | The proxy started, with the classes it serves: one for every secret `<service>-token` that it holds. A class that is missing here is a class whose runners get 403, and its secret is not mounted in `token-proxy` (or is not named `<service>-token`) |
| `claim from <ip> (tasks.<service>): upstream status 204` | A runner polled and there was no task. Normal, about every 5 seconds for each idle runner |
| `claim from <ip> (tasks.<service>): upstream status 200` | A claim returned a task, and the runner at that address cannot claim again |
| `released <ip> (tasks.<service>)` | DNS has not listed the address for 30 seconds in a row: the container is gone, and a new container on that address can claim |
| `claim from <ip> refused: not a runner of any class (tasks.<service> lists [...], ...)` | A container that is not a runner of a configured class, or a runner that DNS does not list yet. The line names what DNS lists for every class, so compare the address with it. Look for a class that you added without adding it to the proxy, or for a container that does not belong on a class network |
| `claim from <ip> refused: this runner has already claimed a task` | A second claim from one container. After a proxy restart a runner that has claimed gets this until Swarm replaces it; with no saved state, every runner of a class that has running tasks gets it until Swarm replaces it. Refer to [Restart the proxy](#restart-the-proxy) |
| `claim from <ip> refused: too many claims` | One container sent more than 2 claims a second (answer 429). A runner claims about every 5 seconds, so this is not a runner that works |
| `state: cannot write it: ...`, and `claim from <ip> refused: the state cannot be written` | The proxy cannot save its state (the volume `proxy-state` is full or gone). A claim that has already been answered by CircleCI gets 503 instead of its task, the proxy removes `state.json` and reports unhealthy, and Swarm restarts it after 3 failed checks. Refer to [When the proxy cannot save its state](#when-the-proxy-cannot-save-its-state) |
| `poll: cannot resolve the runners, no latch is released: ...` | Swarm DNS fails. No latch is released while it fails (at most one line a minute) |
| `claim from <ip> (tasks.<service>): upstream status 401` | CircleCI rejects the class token. The token was deleted, or the secret holds another class's token. Refer to [The runner log shows 401](troubleshooting.md#the-runner-log-shows-401) |
| `upstream error: ...` | The node of the proxy cannot reach the runner API (`runner.circleci.com` on CircleCI cloud), or the connection broke. The runners get 502. A claim that had already reached CircleCI is latched ([A claim whose outcome is unknown](#a-claim-whose-outcome-is-unknown)) |
| One summary line a minute | The number of claims forwarded, latched and refused, with the refusals counted by reason. A count of refusals that rises while the runners are healthy is the first sign of the causes in the rows above. The exact wording can change between releases: alert on the numbers, and keep the line in your log search |
| `cannot resolve the runners`, or `token file` | Swarm DNS or a class secret is unavailable. The runners get 503 |

**Limits.** The proxy protects itself from a runner or a job that sends too many requests. Each client IP is limited to 2 claims a second (a burst of 10, answer 429, as in the table), and to 50 requests a second (a burst of 200) on all paths. The proxy serves at most 512 requests at the same time, and a request above that gets 503 with a `Retry-After` header. The proxy waits 60 seconds for the response headers of CircleCI. A runner and a job stay far below these numbers. [Capacity and concurrency](#capacity-and-concurrency) says what they mean for the size of a fleet.

**If the proxy is down.** Runners cannot claim, so CircleCI keeps the jobs queued. Idle runners keep polling and fail, and they do not go around the proxy, because they hold only the placeholder. A runner that is running a job keeps its container: the runner and the task agent call the API through the proxy too, because the runner hands its own API URL to the agent, and those calls fail while the proxy is down. `linux/tests/proxy.sh` measures this with the real runner: a proxy that restarts while jobs run does not end them, and a proxy that is down when the jobs end, and for a while after, only delays the report: the runner sends the end of the job (step end and cleanup) once the proxy is back, and exits 0. The end-to-end test on CircleCI restarts the proxy in the middle of a real job on a real agent as well (the probe `b2`). Swarm restarts a failed proxy task after 5 seconds on Linux and 10 on Windows, and a restart takes a few seconds, so an outage of that length is harmless. Do not leave the proxy down for long while jobs run: how long the real task agent keeps retrying is not documented.

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

Replace the idle runners of a Linux class at once with:

```console
$ docker service update --force --update-parallelism 0 runners_linux-default
```

A busy Linux replica finishes its job before Swarm replaces it. **Do not run this on a Windows class**: a busy Windows container is killed about 5 seconds after the stop, and the job with it. [Replace refused runners on Windows](#replace-refused-runners-on-windows) shows how to remove only the idle ones.

Restart the proxy for a rotation, for a new binary, or for a change of its settings:

```console
$ docker service update --force runners_token-proxy
```

A stop (this command, a deploy, or a node that shuts down) lets the claims in flight finish, for 8 seconds at most, before the proxy exits: a claim that CircleCI has answered, and that is saved, reaches its runner. The default grace of Swarm is 10 seconds. These figures are those of the Linux proxy. A Windows container can be ended about 5 seconds after a stop ([Stop a busy Windows container](#stop-a-busy-windows-container)), so a claim in flight on Windows can be cut off, and then it is the case in the next section.

#### Replace refused runners on Windows

`docker service update --force` replaces every container of a service at once, busy ones included, and a busy Windows container is killed about 5 seconds after the stop. The Windows classes are served by `token-proxy-windows`, so on Windows the command above would end the running jobs. A refused runner (403 `this runner has already claimed a task`) holds no task: its container is idle, and removing that one container is safe. Swarm starts a replacement for each container that you remove. These commands are not run by the CI. Check the result before you use them on a fleet.

1. On a manager, list the addresses that the proxy refused in the last minutes (PowerShell):

   ```powershell
   docker service logs --since 5m runners_token-proxy-windows 2>&1 |
     ForEach-Object { "$_" } |
     Select-String 'claim from (\S+) refused: this runner has already claimed a task' |
     ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
   ```

2. On each Windows node, show the containers of a class with their addresses, and find the ones from step 1:

   ```powershell
   docker ps -q --filter 'name=runners_windows-default' | ForEach-Object {
     docker inspect --format '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' $_ }
   ```

3. Remove only those containers, by the name from step 2:

   ```powershell
   docker rm -f <container name>
   ```

The alternative is to wait: a refused runner recycles by itself at its idle timeout (1 hour in the shipped files). Do not shorten the timeout at this point: a change of the stack file is a service update, and it stops the busy containers too.

#### A claim whose outcome is unknown

A claim can reach CircleCI while its answer is lost: the connection resets, or CircleCI sends no response headers within 60 seconds. The proxy cannot tell whether CircleCI handed a task to that runner. It treats the claim like one that did: it latches the runner, as for a claim that returned a task, and so it fails closed. The runner gets an error and no task, and every later claim of that container is refused (403) until Swarm replaces the container. The cost is one idle runner that is replaced. If CircleCI had allocated a task to that runner, the task never runs, and the job waits for CircleCI to give up on it: rerun the job if it does not. A claim that never reached CircleCI (the proxy cannot connect, for example) is not latched.

The proxy runs from its image, so a restart does not change its version: the same tag or digest as before, unless the tag has moved since (`latest` moves with a release, `edge` with a merge to the main branch that passed the end-to-end tests). [Upgrade the token proxy](#upgrade-the-token-proxy) says how to change the image on purpose.

#### When the proxy cannot save its state

The proxy saves a runner's address before it hands the task to the runner. If the save fails (the volume `proxy-state` is full, read-only or gone), it does not hand the task over: the runner gets 503, and it stays refused (403) from then on, and every other claim gets 503 without reaching CircleCI. The proxy also deletes `state.json`, so that no restart can read a state that is behind, and reports unhealthy. CircleCI has already allocated that one task to the runner, which never runs it, so the job waits for CircleCI to give up on it: rerun the job if it does not. Swarm restarts the proxy after 3 failed health checks, and, because the state file is gone, the restart takes the same path as a lost state: it asks CircleCI, and refuses every runner of a class that has running tasks. Mend the volume (free space, or fix the mount) before or right after: the proxy refuses to start when it cannot write its state directory, and it writes the whole state again with the next claim or poll that succeeds.

#### Where the proxy runs, and when it moves

The proxy runs on a manager by default (`node.role == manager`), with no label. In a cluster with one manager it never moves. Its state, the addresses of the runners that have claimed, is the volume `proxy-state` of the node that it runs on.

**The worst case.** If the proxy moves to another node, its state is lost: the new node has an empty volume. A move happens by itself when its node is down and another manager matches, and it happens by hand when you change the placement. The proxy then asks CircleCI for each class (the previous section), and what the runners see depends on the answer:

- **No running task in the class.** Every runner present may claim, which is right: none of them holds a job.
- **Running tasks in the class, or no answer.** The proxy **refuses the existing runners** of that class (403, `this runner has already claimed a task`) until they recycle. A runner that is running a job is not affected. Replace the idle ones at once with `docker service update --force --update-parallelism 0 runners_<service>` for each Linux class, and on Windows as in [Replace refused runners on Windows](#replace-refused-runners-on-windows). This is the safe side: no runner can claim twice.

There is nothing to set before a planned move. To move the proxy by hand:

```console
$ docker service update --constraint-rm 'node.role == manager' --constraint-add 'node.hostname == <new manager>' runners_token-proxy
```

If no node matches (the only manager is down), the service stays pending and no runner can claim in the meantime.

**Several managers, or a cluster with workers.** The default lets the proxy start on any manager, so a failure of its node moves it, and the runners may share a node with the proxy. In a cluster, do two things: label the node that runs the proxy, and say so at deploy time, in the environment of `docker stack deploy` ([Keep the deploy variables in version control](#keep-the-deploy-variables-in-version-control) shows where to keep the variable):

```console
$ docker node update --label-add machine-runner-swarm.proxy=true <manager>
$ sudo env MACHINE_RUNNER_SWARM_PROXY_PLACEMENT='node.labels.machine-runner-swarm.proxy == true' docker stack deploy -c deploy/runners.yaml runners
```

The label does two things. The placement variable pins the proxy to a labelled node, a manager or a worker. And the runner services never run on a node that carries the label, so no job shares a node with the class tokens. A job that shares a node with the proxy would have a runner and a proxy in the same place, and the proxy holds every class token. On a single node, which has no label, nothing changes: the proxy and the runners share the node.

If the labelled node dies, the service stays pending until you label another one, and the move is the planned one above. Keep in mind that the labelled node runs no jobs: size the cluster so that the other nodes carry the replicas ([Capacity and concurrency](#capacity-and-concurrency)). Do not drain that node to patch it without reading the next paragraphs.

**Planned work on the node of the proxy.** The state of the proxy lives in the volume of its node, and a reboot of that node keeps it. A move to another node loses it. So there are two cases:

- **The proxy is pinned (the label and the placement above).** Drain the node, patch it, and set it `active` again. While it is out, the proxy is pending, and no runner can claim: jobs wait, and running jobs wait for the proxy at the end. The proxy then starts on the same node with its state. Do this in a quiet period, and keep the downtime to the length of the patch. Patch the node last, after the others.
- **The default placement, with other managers.** Draining the node moves the proxy to another manager with an empty state, the worst case above. Pin it first, or accept the replacement of the refused runners afterwards.

[Drain a node for patching](#drain-a-node-for-patching) has the full procedure.

### Capacity and concurrency

The replicas of a class are the jobs it runs at the same time, and the sum over all classes is the capacity of the cluster. A job with `parallelism: n` is `n` tasks, so it needs `n` replicas at once.

Two limits sit above the replicas, and both are set on the CircleCI side:

- **The runner concurrency of your plan**, which all self-hosted runner jobs of the organization share.
- **`maxConcurrentTasks` of the resource class**, which is 20 by default and which CircleCI support raises. A class with more than 20 replicas leaves the extra replicas idle until it is raised.

Queued tasks count against concurrency, and the runner inventory shows running tasks only, so runners can look idle while jobs wait. A job for a class that has no runner queues indefinitely and holds concurrency. Check `unclaimed_task_count`, and cancel the tasks of a class that no longer has runners. Refer to [Jobs wait while the runners are idle](troubleshooting.md#jobs-wait-while-the-runners-are-idle).

On the Swarm side, the reservations of the replicas on a node must fit in the node. Refer to [Size the limits](resource-classes.md#size-the-limits).

**The replicas are fixed, and the nodes are yours.** The stack does not scale by itself. It has no autoscaling and no integration with a cloud provider: a class runs the number of replicas that its stack file says, on the nodes that you joined to the swarm, and a node that dies is not replaced. Raise the replicas with `docker service scale` or in the stack file (a change of the file is the durable one), and add nodes yourself. Plan for one node less than you have: the replicas of a class must still fit when any one node is gone, and the node of the token proxy, when it is labelled, carries none of them ([Where the proxy runs, and when it moves](#where-the-proxy-runs-and-when-it-moves)).

**One proxy for the fleet.** There is one `token-proxy` replica for all classes of an OS, by design: a second replica would not share the list of the runners that have claimed. All idle runners poll through it, about one claim every 5 seconds for each, so 100 idle runners are 20 claims a second. The calls of the runners and task agents of the running jobs go through it as well. It limits itself ([Monitor the token proxy](#monitor-the-token-proxy)): 50 requests a second for each client IP, and 512 requests at once. The shipped limits of its container are 0.5 CPU and 128 MB on Linux, and 1 CPU and 512 MB on Windows.

This project has not load-tested the proxy and states no tested fleet size. The CI runs fleets of a few replicas. Before you run a fleet of more than a few dozen replicas, test it with your own load and watch the proxy:

- `docker stats --no-stream <container>` on its node: CPU near its limit, or memory near the limit (a kill for memory restarts the task on the same node, with its state).
- 503 answers with `Retry-After` in the log of the runners, which say that the limit of 512 requests at once is reached.
- A rising count of claims in the summary line, with idle runners.

Raise the `limits` of `token-proxy` in your copy of the stack file if the proxy is the bottleneck. If one proxy is not enough, the project has no tested way to scale it. A second stack, with another name, its own proxy, and its own classes and tokens, is the structure to try, and it is not tested.

### Keep the deploy variables in version control

The variables of `docker stack deploy` are the only record of your choices that the stack files do not hold: the runner pin and its SHA-256 values, the token proxy image, and the proxy placement. A deploy that leaves them out sets the defaults again, with no message: the pin of the shipped file, the tag `latest` of the proxy image, and the placement `node.role == manager`. The last one can move the proxy to a node without its state ([Where the proxy runs, and when it moves](#where-the-proxy-runs-and-when-it-moves)). A change that you made with `docker service update` is lost in the same way, because the next deploy returns the stack to its files.

So keep the variables in a file in your own repository, next to your stack files, and never deploy by hand. `linux/setup.sh --deploy` prints a warning when `MACHINE_RUNNER_SWARM_PROXY_IMAGE` is not pinned by digest.

`deploy/deploy.env` (no secrets in it, only pins and placement):

```sh
MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.13
MACHINE_RUNNER_SWARM_RUNNER_SHA256=<the SHA-256 values of the pin, comma-separated>
MACHINE_RUNNER_SWARM_PROXY_IMAGE=ccilabs/machine-runner-swarm-proxy@sha256:<digest>
MACHINE_RUNNER_SWARM_PROXY_PLACEMENT='node.labels.machine-runner-swarm.proxy == true'
```

`deploy/deploy.sh`, which is the only way to deploy (on Linux):

```sh
#!/bin/sh
set -eu
cd "$(dirname "$0")"
set -a
. ./deploy.env
set +a
exec docker stack deploy -c runners.yaml runners
```

Add the `-c` files of your add-on stack files to the last line. Run it with `sudo ./deploy/deploy.sh`: the script reads the file itself, so `sudo` does not need to keep the environment. Before the first deploy, and after every edit of the file, check that the values reach the stack:

```console
$ (set -a; . deploy/deploy.env; set +a; docker stack config -c deploy/runners.yaml) | grep -E 'machine-runner-swarm.proxy ==|image: ccilabs'
```

On Windows, load the file into the environment of the session, and deploy from the same session:

```powershell
Get-Content deploy\deploy.env | ForEach-Object {
  if ($_ -match '^\s*([^#=\s]+)\s*=\s*(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2].Trim("'") }
}
docker stack deploy -c deploy\runners.yaml runners
```

Change a pin or the proxy image in the file, review the change like code, and run the script. [Upgrade the runner](#upgrade-the-runner-and-images) and [Upgrade the token proxy](#upgrade-the-token-proxy) show the values.

### Back up the managers, and recover

The state of the cluster is the directory `/var/lib/docker/swarm` of each manager. It holds the Raft log with every Swarm secret, so **the backup holds every runner token**. Keep it as you keep a password vault, and delete old copies.

The method needs a second manager: Docker stops on the manager that you copy, and the other managers must keep the quorum. A cluster with one manager has no safe way to take this copy while it runs. Keep your stack files and your deploy variables in version control ([Keep the deploy variables in version control](#keep-the-deploy-variables-in-version-control)) and rely on the redeploy below.

1. If the managers use autolock, save the unlock key first: `docker swarm unlock-key`.
2. Choose a manager that is not the leader (`docker node ls`, the column `MANAGER STATUS`), and that does not run `token-proxy` (`docker service ps runners_token-proxy`). Stopping Docker on the node of the proxy stops the proxy for the length of the copy, and a move of the proxy to another node loses its state ([Where the proxy runs, and when it moves](#where-the-proxy-runs-and-when-it-moves)). Use three managers, so that the quorum stands while one is stopped.
3. If the manager runs jobs, drain it first and wait until its tasks are gone, because stopping Docker ends every container on the node (Swarm mode does not support live restore). A manager that carries the proxy label runs no jobs. Refer to [Drain a node for patching](#drain-a-node-for-patching).
4. Stop Docker, copy the whole directory, start Docker again, and set the node `active` again:

   ```console
   $ sudo systemctl stop docker
   $ sudo tar -czf swarm-backup-$(date +%F).tar.gz -C /var/lib/docker swarm
   $ sudo systemctl start docker
   $ docker node update --availability active <node name>
   ```

For this stack, **disaster recovery means redeploying and issuing new tokens**, because the stack files hold the whole desired state and the tokens are the only secrets:

1. Create a new Swarm on a new manager, and join the nodes. Refer to [Create the swarm](multi-node.md#create-the-swarm). Label the node of the proxy again ([Where the proxy runs, and when it moves](#where-the-proxy-runs-and-when-it-moves)).
2. Create a new token for each class, delete the old tokens, and create the secrets. Refer to [Rotate a runner token](#rotate-a-runner-token). Create the secret `runner-placeholder-token` as well, which every runner reads in place of a token, or the deploy fails with `secret not found`: `printf %s machine-runner-swarm-placeholder | linux/setup.sh --secret runner-placeholder` on Linux, and the placeholder step of `windows/Setup.ps1` on Windows. Refer to [The token proxy](concepts.md#the-token-proxy).
3. Deploy the same stack files with your deploy variables, the same list of `-c` files, and the same pins. The volumes are not recovered: the proxy starts with no state and asks CircleCI, and a persistent class starts with an empty volume.

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

Upgrade one node at a time, and wait until the cluster is healthy before the next node. Take the managers first and then the workers, but take the node of the token proxy **last** ([Where the proxy runs, and when it moves](#where-the-proxy-runs-and-when-it-moves)); `docker service ps runners_token-proxy` shows it (on Windows, `runners_token-proxy-windows`).

1. Drain the node, as in [Drain a node for patching](#drain-a-node-for-patching). On Windows, do not drain a node that runs jobs: pause it and wait.
2. Upgrade Docker and reboot. Unlock a manager that uses autolock.
3. Return the node to service (`docker node update --availability active <node name>`), and check that `docker node ls` shows it `Ready`, and a manager `Reachable` or `Leader`.
4. After the node of the proxy, check the log of the proxy: the start line must say `state restored`. A line that says `no state` means that the proxy moved or lost its volume, and runners are refused until they recycle ([Restart the proxy](#restart-the-proxy)).

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

**Floating is weaker.** The default pin is checked against the SHA-256 values in the stack file, which come with the release of this repository that you deployed. A floating value cannot keep such a list, because the version is not known in advance: the distributor ignores the default list (it names the pinned version only) and takes the SHA-256 of each tarball from the `manifest.json` of CircleCI. That file comes from the same release bucket as the tarball, so whoever can change one can change both, and the check then proves only that the download is whole. Choose a floating value for a class that may run whatever CircleCI releases, and keep the default pin for the rest. A floating value also brings a runner that this release of the proxy has not been tested with: [Compatibility with CircleCI](#compatibility-with-circleci) says what the CI tests and what can break.

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

A command that sets a variable must reach `docker stack deploy`, and it must reach every later deploy too, because a deploy without it sets the default again. Keep the variables in a file and deploy with it: [Keep the deploy variables in version control](#keep-the-deploy-variables-in-version-control). The commands below show a single variable, for a try. A host with `sudo` drops the environment, so pass the variable with `env`, or run the command as a user in the `docker` group.

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

Put the same two lines in `deploy/deploy.env` and deploy with `deploy.sh` ([Keep the deploy variables in version control](#keep-the-deploy-variables-in-version-control)): the file is then the record of the pin. The distributor then installs only a tarball with one of these values, whatever the manifest says. Without the list it refuses the tarball (`SHA-256 mismatch`), and the nodes keep the version that runs. To trust the manifest instead, which is weaker ([the version policy](#the-version-policy)), set `MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest`. The same applies if you edit the pin in your copy of the stack file: change the default of `MACHINE_RUNNER_SWARM_RUNNER_VERSION` and the default of `MACHINE_RUNNER_SWARM_RUNNER_SHA256` together, in `x-distributor-env` (and in `x-env` of `microvm.yaml`, which downloads the runner itself).

The distributor switches to a version that is installed already without any network access, when the hash list is `manifest` or names that version. Use `3.1.12` or later: it fixes the enforcement of `max_run_time`.

#### Freeze the nodes now

To stop all change at once, pin the version that the nodes run now. That version is installed, so the pin needs no network. Read it first, as in [See what runs](#see-what-runs), and then update the distributor. The list of SHA-256 values belongs to the default pin, so name the hash policy together with the version (`manifest` makes no request for a version that is installed):

```console
$ docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 --env-add MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest runners_runner-distributor
```

A freeze is an emergency step, so the command is quick and changes nothing in your files. Put the same two values in `deploy/deploy.env` straight away: a deploy without them sets the default pin and its list from the stack file again, which undoes the freeze.

#### Roll back

A rollback is a pin of an older version. The distributor keeps the last 3 versions that were active, so a rollback to one of them only moves the link: no download, and no network. A version that was removed is downloaded again, and its hash comes from the manifest or from a list that you give. The hash policy goes with the version, because the default list names the pinned version only:

```console
$ docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 --env-add MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest runners_runner-distributor
```

The next container of every runner service runs the old version. Running jobs are not affected. Put the same values in `deploy/deploy.env`, as for the pin above, or the next deploy undoes the rollback.

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

A site without a route to the release bucket of CircleCI serves the tarball `<version>/circleci-runner_linux_<arch>.tar.gz` of every version that the nodes may run from an internal HTTP server, and, for some settings, `manifest.json`. The distributor builds the address of a tarball from the base URL and the version, and it does not follow the `url` fields of the manifest, so a mirror may hold a copy of `manifest.json` unchanged. What the mirror must hold depends on the setting:

| Setting | The distributor reads `manifest.json` | The mirror must hold |
|---|---|---|
| An exact pin with its SHA-256 list (the default) | Never | The tarballs of the pinned version, for each architecture of your nodes |
| An exact pin of your own with `manifest` instead of a list | Only when the version is not installed on the node yet | The tarballs, and `manifest.json` with an entry for that version |
| A floating value (`3.1`, `3`, `current`) | At every start and every check interval | `manifest.json`, kept current, and the tarballs of the versions it may pick |

A mirror therefore needs `manifest.json` for a floating value, and for a pin that has no list, and it does not need it for the default.

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

- Copy the tarballs of the architectures that your nodes have (`amd64`, `arm64`, `ppc64le`, `s390x`). With an exact pin, copy that version, and keep the previous one for a rollback. With a floating version, copy the versions of its line, and copy `manifest.json` again when you want the nodes to adopt a new release. With `current`, copy the version that `current` names. The command `jq -r '.releases as $r | $r.current.linux.amd64.sha256 as $s | $r | to_entries[] | select(.key | test("^[0-9]")) | select(.value.linux.amd64.sha256 == $s) | .key' mirror/manifest.json` prints that version.
- The distributor downloads with the `wget` of the stock Alpine image and its CA bundle, so an `https` mirror needs a certificate from a public certificate authority. A mirror with a certificate from your own authority fails with a download error. The options are an `http://` mirror with the SHA-256 list (the list, and not the transport, is then what you trust), or an image of your own for the service `runner-distributor` (`FROM` the pinned Alpine, with your CA added), set as its `image` in your copy of the stack file. The second is not tested here.
- Do not set a proxy for the distributor that you also use for the mirror. Its `wget` reads only the lowercase variable `http_proxy`, sends an `https://` URL to the proxy as a plain `GET https://...` and not as a `CONNECT`, and ignores `no_proxy`. [Proxies and certificate authorities, component by component](#proxies-and-certificate-authorities-component-by-component) has the table.
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

In PowerShell, set the variables in the environment of the shell that runs the deploy, and keep them in a file so that every deploy has them ([Keep the deploy variables in version control](#keep-the-deploy-variables-in-version-control)):

```powershell
$env:MACHINE_RUNNER_SWARM_RUNNER_VERSION = '3.1'   # trusts the hash of the manifest: weaker
docker stack deploy -c deploy\runners.yaml runners
```

- **Upgrade.** The default is an exact pin, so the nodes change version only when you change it, or when you deploy a release of this repository that carries a newer one. With `3.1`, `3` or `current`, a new release reaches every node within one check interval, with no redeploy. A deploy without the variables sets the default pin and its SHA-256 list again, so keep the values in `deploy\deploy.env` and use it on every deploy.
- **Freeze the nodes now.** Pin the version that the nodes run now. It is installed, so the pin needs no network: `docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 --env-add MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest runners_runner-distributor-windows`.
- **Roll back.** Pin an older version, with the hash policy of that version as on Linux (`manifest`, or its own values). The distributor keeps the last 3 versions that were active, so a rollback to one of them only moves the link, with no network. A version that was removed is downloaded again.
- **See what runs.** `docker service logs runners_runner-distributor-windows` shows each flip. On the node, `docker run --rm --mount type=volume,source=runners_runner-bin,target=C:\v,readonly mcr.microsoft.com/windows/servercore:ltsc2022 powershell -Command "Get-Content C:\v\history; (Get-Item C:\v\current).Target"` shows the history and the active version.
- **Replicas that wait for a job** keep the old version until they claim a job or exit after `CIRCLECI_RUNNER_IDLE_TIMEOUT`, which is 1 hour in the stack file. A forced update replaces them at once, but it also stops the containers of the service, which kills a running job after about 5 seconds. Force the update only while the class is idle: `docker service update --force runners_windows-default`.
- **A mirror.** Copy the tarballs (and `manifest.json`, when the table of the [Linux mirror](#run-the-downloads-from-a-mirror) says that it is needed) with `windows` and `amd64` (or `arm64`) in the names, and copy the two pinned Git downloads into the tools directory. The distributor downloads with PowerShell, so an `https` mirror needs a certificate that the stock Server Core image trusts: the Windows certificate store of the container, which does not hold your own authority. Use an `http://` mirror with the SHA-256 list, or an image of your own. The Windows distributor reads only `HTTPS_PROXY` (and no `NO_PROXY`).

A link cannot be replaced in one step on Windows, so for a moment `current` does not exist. A container that Swarm creates in that moment does not start, and Swarm starts the next one after the restart delay of 10 seconds. The window is a few milliseconds long. On a new node, the runner tasks fail in the same way until the first download of the distributor is done. The runner has no start-time check of the binary on Windows, because no entrypoint script exists: the distributor compares the active binary with its record at every check and installs it again when it changed. Refer to [Runner binary integrity on Windows](security.md#runner-binary-integrity-on-windows).

### Upgrade the token proxy

The token proxy is the image `ccilabs/machine-runner-swarm-proxy`, and the service `token-proxy` (Windows: `token-proxy-windows`) reads it from `MACHINE_RUNNER_SWARM_PROXY_IMAGE`. The tags are `X.Y.Z` (a release, which never moves), `X.Y`, `X`, `latest` (the newest release), `edge` (the newest commit of the main branch that passed the end-to-end tests, for testing main) and `sha-<12 characters>` ([The token proxy image](install-linux.md#the-token-proxy-image)). The default of a release bundle is its own release, by tag and digest. A checkout defaults to `latest`, which only a release moves.

- **Upgrade with the release.** Deploy the stack files of the new release ([Upgrade to a new release of this repository](#upgrade-to-a-new-release-of-this-repository)). They name the new image.
- **Pin a digest.** Run the proxy from `ccilabs/machine-runner-swarm-proxy@sha256:<digest>`, set in the environment of every `docker stack deploy` (in `deploy/deploy.env`: [Keep the deploy variables in version control](#keep-the-deploy-variables-in-version-control)). `linux/setup.sh --deploy` prints a warning when `MACHINE_RUNNER_SWARM_PROXY_IMAGE` is not pinned by digest. A digest never changes, and it is the only pin that a re-pushed tag cannot move. Read the digest of a release in its notes and in the bundle (`grep MACHINE_RUNNER_SWARM_PROXY_IMAGE stack/runners.yaml`), or with `docker buildx imagetools inspect ccilabs/machine-runner-swarm-proxy:<version>`, and check the signature before you trust it ([Verify the token proxy image](security.md#verify-the-token-proxy-image)).
- **Change the image of the running service.** `docker service update --image <image> runners_token-proxy`. Swarm stops the old proxy and starts the new one (`stop-first`: a second proxy would allow a second claim), so the runners cannot claim for the few seconds of the change, and every runner that has claimed stays refused ([Restart the proxy](#restart-the-proxy)). Record the change in `deploy/deploy.env`, so that the next deploy does not undo it. A tag such as `latest` is resolved to a digest when you deploy: run `docker stack deploy` again to pick up a newer one.
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
3. Decide what the nodes run, and write it down in `deploy/deploy.env` or in your copy of the stack file, so that no one has to remember a variable. Take the pin of the new release by merging both defaults, or keep your own pin by setting its two values (the version, and the list of SHA-256 values or `manifest`). A pin, a freeze or a rollback that you made only with `docker service update` is not in the file: the next `docker stack deploy` sets the defaults of the file again and undoes it silently.
4. Run `docker stack deploy` (with `deploy/deploy.sh`) with the same set of `-c` files as before, and with the same variables as before (a variable of the deploy beats the default of the file).
5. Check what the nodes run: `docker service logs --tail 5 runners_runner-distributor` shows the version that the distributor selected, and [See what runs](#see-what-runs) the version that is active.

The entrypoint and the script of the distributor are Swarm configs, so this command is the whole upgrade. A Swarm config cannot change, so the name of each config carries the first 12 hex digits of the SHA-256 of its file. A release that changes the entrypoint or the script has new names. `docker stack deploy` creates the new config and updates the services that use it: the runner services one replica at a time, as in [Upgrade the runner and images](#upgrade-the-runner-and-images), and the distributor on every node.

If you edit one of these files in your own copy, rename the config in your stack file after each edit, or Swarm keeps the old file. The new name is the old prefix and the first 12 digits of the new hash:

```console
$ sha256sum linux/stack/circleci-runner-entrypoint | cut -c1-12
$ sha256sum linux/stack/runner-distributor.sh | cut -c1-12
```

In a clone of this repository, `ci/config-names.sh --write` renames the configs of the shipped stack files.

## Compatibility with CircleCI

The token proxy sits between the runner and CircleCI, so it depends on the runner API more closely than a plain runner install does. This section lists what it relies on, what the CI tests, and what fails when one of them changes.

### What the proxy relies on

| Call | Who sends it | What the proxy does, and what it reads |
|---|---|---|
| `POST /api/v3/runner/claim` | A runner, to claim a task | The only call that the proxy changes. It accepts the claim from a runner address that Swarm DNS lists for a class, adds the token of that class, and forwards it. It reads the status of the answer: a 2xx other than 204 means that CircleCI handed a task to the runner, and the proxy latches that runner. 204 means no task. Any other status passes through, and nothing is latched |
| `GET /api/v3/runner/scale` | The proxy itself, with the token of a class, at a start that has no state for the class | It reads `data.attributes.running_task_count` and `data.attributes.unclaimed_task_count`, each a whole number of 0 or more. Anything else is an error, and the proxy then latches the runners present |
| Every other call of the runner and its task agent | The runner and the task agent | Forwarded unchanged, with the token that the caller sent (the placeholder, for the runner). The proxy relies on the runner passing `CIRCLECI_RUNNER_API_URL` on to its task agent, so that these calls go through the proxy too |

The claim and scale calls are the internal protocol of the runner, and they are not in CircleCI's public [runner API reference](https://circleci.com/docs/reference/runner-api/). CircleCI does not promise that they stay as they are.

### What is tested

- **The runner version.** The exact pin of the stack files, `3.1.13` in this release. The CI runs the real runner binary of that version against a fake API (`task.sh`, `proxy.sh` and others), and the end-to-end jobs run real jobs on CircleCI cloud through the proxy, on Linux amd64 and arm64 and on Windows Server 2022 and 2025. The distributor test also installs the version before it (`3.1.11`) for the rollback, and installs the version that CircleCI names as `current` in the live manifest, and checks its record.
- **Not tested.** A real job on a floating version (`3.1`, `3`, `current`) or on any runner version other than the pin. CircleCI server. A runner API of another host name than `runner.circleci.com`.
- **The task agent** is not pinned by this project: the runner downloads the version that CircleCI serves, at the start of each container.

### What fails when it changes

| Change | What you see | What to do |
|---|---|---|
| CircleCI or a runner version moves the claim to another path | The runner logs `401`, and the proxy log has no `claim from` lines for it: the call is forwarded with the placeholder, and CircleCI rejects it | Pin the previous runner version ([Roll back](#roll-back)) |
| A claim with no task is answered with a 2xx other than 204 | Each runner is latched after its first poll. The log shows `upstream status 200` and then `this runner has already claimed a task` for runners that hold no job. No runner claims | Pin the previous runner version. Replace the runners ([Restart the proxy](#restart-the-proxy)) |
| The answer of `scale` has another shape | A proxy that starts with no state logs `CircleCI does not say how many tasks run`, and refuses the runners present until they recycle. A proxy with state is not affected | Open an issue with the log line. A refused runner recycles at its idle timeout, or at once ([Restart the proxy](#restart-the-proxy)) |
| The runner stops passing its API URL to the task agent, or the task agent calls another host | The job starts, and its steps fail with `401` against CircleCI | Pin the previous runner version |
| The runner API of CircleCI is not reachable from the node of the proxy | The runners get 502 and `upstream error` is in the log | [Monitor the token proxy](#monitor-the-token-proxy) |

Before you move to a runner version that this project has not tested, which includes any floating value: pin it on one class, run the [canary](#monitor-the-cluster) and a real job through it, read the log of the proxy, and keep the previous version installed so that the rollback needs no network. The runner API hosts that the nodes must reach are in [Egress hosts](security.md#egress-hosts), with their source, CircleCI's [runner FAQ](https://circleci.com/docs/guides/execution-runner/runner-faqs/), and in the table below.

## CircleCI server, proxies, and hosts without internet

Two setups are **not tested yet**: CircleCI server, and an installation with no route to the internet. This section says what that means, what works today, and what each part needs from the network. Nothing here promises that a server or an air-gapped installation works.

### What is not supported yet

- **CircleCI server.** The proxy takes the address of the runner API in its `-upstream` argument, in the `command` of `token-proxy` in the stack file. The CI runs the proxy and the runners against CircleCI cloud and a fake API, and never against a server installation. Open questions are whether the claim and scale calls of the proxy match your server version, which runner versions your server accepts (the default pin is tested against cloud only), and whether the proxy and the runner trust the certificate of your server ([the table below](#proxies-and-certificate-authorities-component-by-component)). If you try it, run the [canary](#monitor-the-cluster) first, and do not assume that anything on this page was checked for your version.
- **An air-gapped installation.** It does not work with this release. Every runner container downloads its task agent from `circleci-binary-releases.s3.amazonaws.com` when it starts, and this project has no setting that redirects that download. A site must let the nodes reach that host, directly or through a proxy that the runner honours.

### What needs the internet

| Needed by | Host | When | Can it be mirrored here? |
|---|---|---|---|
| The token proxy (claims), and the runner and task agent (their calls go through the proxy) | `runner.circleci.com`, or the runner API of your server | Always | No: it is the API |
| Every runner container (the task agent) | `circleci-binary-releases.s3.amazonaws.com` | At every container start | No |
| The runner distributor | The same host | At the first install and at an upgrade. With a floating version, at every check interval. With the default pin, never once it is installed | Yes: `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` ([mirror](#run-the-downloads-from-a-mirror)) |
| The Windows distributor | `github.com`: PortableGit and 7-Zip | When it installs a version of Git | Yes: `MACHINE_RUNNER_SWARM_TOOLS_BASE_URL` |
| The jobs | `circleci-tasks-prod.s3.us-east-1.amazonaws.com` for the cache, workspaces and artifacts, your VCS provider for the checkout, and whatever the commands of the job fetch | During a job | Not part of this project |
| Docker on each node | The registries of the `image:` lines: Docker Hub for `alpine`, `ccilabs/machine-runner-swarm-proxy` and the job images, and the registry of the Windows base images | At a deploy, when a node joins, and when an image changes | Yes: copy the images to a registry of yours and change `image:` |
| The MicroVM install | `github.com`: the Kata tarball | At install | Yes: copy the tarball in ([MicroVM](microvm.md)) |
| Verification of a release or an image | The Sigstore services that `cosign` uses | When you verify | See below |

### What works today

- **A mirror of the runner download** for the distributor, on Linux and on Windows ([Run the downloads from a mirror](#run-the-downloads-from-a-mirror)).
- **A mirror of the images.** Copy each image with its digest to a registry that the nodes reach, for example with `docker buildx imagetools create --tag <your registry>/<name>:<tag> <source image>`, which keeps every platform, and change the `image:` line of every stack file and `MACHINE_RUNNER_SWARM_PROXY_IMAGE`. Deploy with `--resolve-image never` if the manager cannot reach the registry to resolve tags. The images are `alpine` of the distributor (by digest), the token proxy image, the images of your classes, and on Windows the Server Core image. Refer to [Registry needs](multi-node.md#registry-needs).
- **Proxies and your own certificate authority** for some components, as the next table says.

### Proxies and certificate authorities, component by component

Each component has its own network stack, so a variable that works for one does nothing for another. Only the row for the Linux distributor was tested, with BusyBox 1.37.0 of `alpine:3` against a stub proxy and not against a real corporate proxy. The other rows follow from how each program is written, and the CI does not test them.

| Component | Proxy variables | Your own certificate authority |
|---|---|---|
| The Docker engine of each node (every image pull) | The settings of the engine itself: `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` in a systemd drop-in of `docker.service`, or `proxies` in `daemon.json`. The stack files set nothing | The trust store of the node. For a private registry, `/etc/docker/certs.d/<registry>/ca.crt` |
| `runner-distributor` on Linux | Its `wget` is BusyBox. It reads only the lowercase `http_proxy`, sends an `https://` URL to the proxy as `GET https://...` (not `CONNECT`), and ignores `no_proxy`. `HTTPS_PROXY` does nothing. In practice a proxy rarely works: use a mirror that the node reaches without a proxy | The CA bundle of the Alpine image only. Use an `http://` mirror with the SHA-256 list, or an image of your own for the service |
| `runner-distributor-windows` | `HTTPS_PROXY` only, for every download. `NO_PROXY` is not read | The Windows certificate store of the container, which does not hold your authority. Use an `http://` mirror with the SHA-256 list, or an image of your own |
| `token-proxy` | A Go program: `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` apply to its calls to CircleCI. Set them under `environment` of the service. The lookups in Swarm DNS do not use them | Linux: the image has the public roots. `SSL_CERT_FILE` **replaces** them, so mount one bundle with the public roots and yours (as a Swarm config), and set `SSL_CERT_FILE` to it. Windows: the Windows certificate store of the container |
| The runner and its task agent | Go programs: `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` under `environment` of the class, and jobs inherit them. Add `token-proxy` (Windows: `token-proxy-windows`) to `NO_PROXY`, so that the calls to the proxy stay on the overlay network | The image of the class: add the authority to its system store ([Images](images.md#private-certificate-authorities)). `SSL_CERT_FILE` replaces the roots of a Go program on Unix. On Windows, Go reads the Windows certificate store, so the authority must be in the image |
| The steps of a job | Whatever the tools of the job read. The variables of the class are inherited | The system store of the image |

### What to copy into the site

For a site that has a route to CircleCI through a proxy, or that mirrors what it can, copy in:

1. The release bundle of this repository (the stack files), from the GitHub release, and the `SHA256SUMS` with its bundle.
2. The images, by digest: `alpine` of the distributor, the token proxy image (with its signature: `cosign copy`), your job images, and on Windows the Server Core image.
3. The runner tarballs, for each architecture of the nodes, for the pinned version and the one before it. `manifest.json` too, for a floating version.
4. On Windows, the two Git downloads for the tools directory.
5. For a MicroVM class, the Kata tarball.

### Verify a release without internet

`cosign verify-blob` and `cosign verify` check a keyless signature against the Sigstore trust root, and by default they fetch it over the network. This project has not tested an offline verification. Two ways that work are:

- **Verify on a host that has access, and carry the result in.** Download the release, check `SHA256SUMS` with the bundle (as in [Verify a release](install-linux.md#verify-a-release)), and copy the verified files and the images by digest into the site. On the site, check the files against `SHA256SUMS` (`sha256sum -c SHA256SUMS`) and the images against the digests that the verified release names.
- **Offline verification with a trust root file.** Recent versions of `cosign` can verify a bundle against a trusted root that you carry in (`--trusted-root`). Refer to the documentation of your `cosign` version. Test it with a known release before you rely on it.

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

   The proxy restarts and reads the state from `proxy-state`, so runners that have not claimed may claim again. Recycle runners only when the start log says `no state` or `state lost`: `docker service update --force --update-parallelism 0 runners_<service>` for each affected Linux class, or wait for their idle timeout. On Windows, remove only the refused containers ([Replace refused runners on Windows](#replace-refused-runners-on-windows)), or wait. Refer to [Restart the proxy](#restart-the-proxy).

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
3. Swap the secrets. For a single-task class on Linux, swap it in the proxy with the command of step 3 above, and replace the idle runners (`docker service update --force --update-parallelism 0 runners_<service>`; on Windows, as in [Replace refused runners on Windows](#replace-refused-runners-on-windows)). For the other classes, replace every replica at once so that the class recovers soon:

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

A node drain (`docker node update --availability drain`) stops the tasks of a node and keeps new tasks away. On Linux, Swarm sends SIGTERM and waits for the grace period, so a running job finishes. **On Windows, a drain kills a running job after about 5 seconds**, so use the procedure for a Windows node below. Refer to [Stop a busy Windows container](#stop-a-busy-windows-container). Restarting the Docker daemon stops every running container, because live restore does not work in Swarm mode, so always empty the node before you patch Docker or reboot.

```console
$ docker node update --availability drain <node name>
$ docker node ps <node name>
```

Wait until `docker node ps` shows no running tasks. Swarm starts the replacement tasks on other nodes at once. If the other nodes lack capacity, the replacements stay `Pending` until the drained tasks exit. Patch and reboot the node, and then return it to service:

```console
$ docker node update --availability active <node name>
```

Tasks do not move back to the node by themselves. Single-task replicas restart after every job, so new tasks spread over the nodes again within a short time. Patch managers one at a time, so the cluster keeps its quorum. Refer to [Managers and quorum](multi-node.md#managers-and-quorum).

### A Windows node

A drain kills a busy Windows container, and no setting changes that. Use `pause`, which keeps new tasks away and stops nothing:

```console
$ docker node update --availability pause <node name>
$ docker node ps <node name> --filter desired-state=running
```

A running job keeps its container. Each replica that finishes its job exits, and Swarm starts its replacement on another node, so the node empties by itself. An idle replica exits only at its idle timeout (1 hour in the shipped files), and it can still claim a job until then. So the upper bound is the idle timeout plus the longest job. Wait until the second command prints nothing, then drain the node (no job is left to kill), patch it, and set it `active`.

### No unattended changes

An update that restarts the Docker daemon or the node by itself ends every container on it, and on Windows that kills the jobs. Switch off everything that patches or restarts a node without you, on every node:

- **Windows.** Set the Windows Update policy to download and notify, so that it never installs an update or restarts the node on its own. Install and reboot only in the procedure above.
- **Debian and Ubuntu.** Set `Unattended-Upgrade::Automatic-Reboot "false"`. Hold the Docker packages, because an upgrade of `docker-ce` restarts the daemon: `sudo apt-mark hold docker-ce docker-ce-cli containerd.io`, and `sudo apt-mark unhold ...` for the planned upgrade. Set `needrestart` to list only (`$nrconf{restart} = 'l';`), so that it does not restart the daemon after another upgrade.
- **RHEL and its clones.** Turn off the automatic installation of `dnf-automatic` (or limit it to a download), and hold the Docker packages with a version lock of your package manager.

Do the planned upgrade with the node emptied, as above.

### The node of the proxy

Draining the node that runs `token-proxy` stops the proxy, and the placement decides what follows. A proxy that is pinned to a labelled node stays `Pending` until that node is `active` again, and then starts there with its state. No claim is possible in between, so choose a quiet period, and patch that node last. A proxy with the default placement moves to another manager, and its state stays behind ([Where the proxy runs, and when it moves](#where-the-proxy-runs-and-when-it-moves)). Draining every manager, or the only node that can run the proxy, stops every claim: keep one node undrained for it ([the warning in Multi-Node Clusters](multi-node.md#managers-and-quorum)).

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
$api = 'https://runner.circleci.com'   # the runner API of your installation, for CircleCI server
Invoke-RestMethod -Headers $h -Uri "$api/api/v3/runner/tasks/running?resource-class=<namespace>/windows-default"
Invoke-RestMethod -Headers $h -Uri "$api/api/v3/runner/tasks?resource-class=<namespace>/windows-default"
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

On Windows, a forced update kills a running job after about 5 seconds, so recycle a Windows class only while it is idle ([Stop a busy Windows container](#stop-a-busy-windows-container)).

A persistent class keeps state between jobs, and recycling removes only the container filesystem. The named volume survives, so `/home/circleci` on Linux and `C:\cache` on Windows keep their files. To reset the volume as well, scale the service to 0. Then run `docker volume rm runners_persistent-home` (Linux) or `docker volume rm runners_windows-persistent-cache` (Windows) on the node that holds the volume, and scale the service back up.

On Linux, the runner of a persistent class does not clean its working directory. The runner user cannot remove files that the job user owns, so the stack sets `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` to `"false"`. Files from one job stay for the next job until the container is replaced. Start every job on that class with a step that removes what an earlier job left, and recycle the class on a schedule. Refer to [Working directory cleanup](security.md#working-directory-cleanup).

## Free disk space

A full disk is the most common way a node stops running jobs, and a full manager disk can break Swarm itself. This section says where the space goes, how to keep it from filling, and what to do when it is full.

### Where the space goes

- **Stopped containers.** A job runs in the writable layer of its container, and the layer stays until Swarm prunes the task. A slot keeps its running task and up to `task-history-limit` finished ones, so a class of R replicas can hold R times (1 plus the limit) layers. The default limit of Swarm is 5. A job that leaves gigabytes behind makes this the largest item.
- **Images.** Each tag that a job image has had, and each version of your own images, stays on the node until something removes it. `docker image prune` removes only images with no tag.
- **Logs.** The stack files cap the log of each container: 3 files of 20 MB (60 MB) for a runner on both systems and for the Linux proxy, and 10 MB for the Windows proxy. A log goes with its container.
- **The engine of a docker-build node.** Images, volumes and build cache that jobs leave there.
- **The Raft log and the state of Swarm**, in `/var/lib/docker/swarm` of each manager, on the same disk as everything else.

### Prevent it

1. **Set the task history limit on the cluster.** `docker swarm update --task-history-limit 2` keeps at most 2 finished tasks for each slot. The single-node setup of `linux/setup.sh` sets it, and a swarm that you create yourself does not: refer to [Create the swarm](multi-node.md#create-the-swarm).
2. **Give Docker its own filesystem, and keep managers free of jobs.** Put `/var/lib/docker` on a separate volume, so that nothing else fills it, and size it for the worst case in the list above: replicas, times the largest workspace, times (1 plus the history limit), plus the images. A manager that carries the proxy label runs no jobs ([Where the proxy runs, and when it moves](#where-the-proxy-runs-and-when-it-moves)).
3. **Prune the images on every node, on a schedule.** Swarm has no command that runs on every node, and a global service with the Docker socket would be root on every node, so use the scheduler of the node (a configuration management tool, or a systemd timer on each Linux node). The first file removes the images that no container uses and that are older than a week, and the second runs it every Sunday:

   ```ini
   # /etc/systemd/system/docker-image-prune.service
   [Unit]
   Description=Remove unused Docker images older than a week

   [Service]
   Type=oneshot
   ExecStart=/usr/bin/docker image prune --all --force --filter until=168h
   ```

   ```ini
   # /etc/systemd/system/docker-image-prune.timer
   [Unit]
   Description=Weekly removal of unused Docker images

   [Timer]
   OnCalendar=Sun 03:00
   RandomizedDelaySec=1h
   Persistent=true

   [Install]
   WantedBy=timers.target
   ```

   ```console
   $ sudo systemctl daemon-reload
   $ sudo systemctl enable --now docker-image-prune.timer
   ```

   `until` filters by the creation time of the image, and not by its last use, and `--all` skips every image that a container, a stopped one included, still uses. An image that is removed and needed again is pulled again, so a mirror ([What needs the internet](#what-needs-the-internet)) must be up. On a node of a docker-build class, add `docker builder prune --force --filter until=168h`. On Windows, run the same `docker image prune` command from a scheduled task. The Server Core image and the distributor image are in use while the stack runs, so a prune does not remove them.
4. **Alert on the disk of every node** (`df -h /var/lib/docker`): above 80 percent on a worker, and above 70 percent on a manager ([Monitor the cluster](#monitor-the-cluster)).

> [!WARNING]
> Do not run `docker volume prune` or `docker system prune --volumes` on a node of this stack. The named volumes hold `runner-bin`, `proxy-state` and the persistent classes. A volume that no container uses at that moment, for example a persistent class that you scaled to 0, is deleted with its data. Leave `docker container prune` to the task history as well, except in an emergency.

### When the disk is full

A node with a full disk fails tasks, with `no space left on device` in the log of the runner or in `docker stack ps --no-trunc`, and Docker commands on it fail. A full manager disk comes first, because Swarm cannot write its log.

1. Find out which node: `df -h /var/lib/docker` on each, and the `ERROR` column of `docker stack ps runners --no-trunc`.
2. Stop it from claiming more jobs. On Linux, drain the node. On Windows, pause it, because a drain kills the running jobs ([A Windows node](#a-windows-node)):

   ```console
   $ docker node update --availability drain <node name>
   ```

3. See what takes the space:

   ```console
   $ docker system df
   $ docker ps -a --size --format '{{.Size}}\t{{.Names}}' | sort -hr | head
   ```

4. Free it, starting with what is cheapest to get back:

   ```console
   $ docker image prune --all --force
   $ docker builder prune --force
   $ docker container prune --force
   ```

   `docker container prune` removes the stopped containers of finished tasks, which Swarm does not need. It removes no running container. Do not prune volumes.
5. If the disk is a manager, check the cluster before you go on: `docker node ls` and `docker service ls` must answer, and the proxy must be running (`docker service ps runners_token-proxy`).
6. Return the node to service (`docker node update --availability active <node name>`), set the task history limit if it is not set, and add the scheduled prune above.

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
