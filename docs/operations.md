---
page-title: Operations
page-audience: admin
page-description: Check status and logs, upgrade the runner and images with rolling updates, rotate tokens, drain nodes for patching, and uninstall the stack.
---

# Operations

This page describes the day-to-day tasks for a running stack: checking status, upgrading, rotating tokens, patching nodes, and uninstalling. The commands use the stack name `smr` and the service names of the shipped files. Run them on a manager node.

## Check status and logs

List the services and the replicas that run:

```console
$ docker stack services smr
```

List the tasks, including the finished ones that Swarm keeps for a short time. The `ERROR` column shows why a task failed or stays pending.

```console
$ docker stack ps smr --no-trunc
$ docker service ps --no-trunc smr_linux-default
```

Read the runner output of a service. On Linux, the entrypoint prints one line that starts with `smr-entrypoint:`.

```console
$ docker service logs --tail 100 --follow smr_linux-default
```

Healthy single-task replicas show a steady stream of tasks that end in `Complete`, because every finished job ends a task. A task that ends in `Failed` with `task: non-zero exit` needs attention. Alert on these signals:

- Tasks that end with a non-zero exit code, including 80 and 1. Code 143 is the exception: a replica that gets SIGTERM while it still retries to reach CircleCI at start-up exits with 143, and needs no action.
- Log lines that start with `circleci-runner: error` or `smr-entrypoint: error`, and lines that contain `401`.
- Tasks that stay `Pending`.

In the web app, select **Runners** to see the replicas of each class in the inventory. A name that you do not recognize means that someone else holds a token of that class.

## Upgrade the runner and images

Swarm replaces containers one at a time. The stack files set `update_config` to `order: stop-first` and `parallelism: 1`. Swarm sends SIGTERM to a busy replica, the runner drains, which means it finishes the running job, and only then does Swarm start the new container. An idle replica stops within about 5 seconds and exits with code 0. A busy replica exits with code 0 when its job ends, so an update can take as long as your longest job, up to the `stop_grace_period` of 5 hours and 5 minutes. The command waits until the update finishes, unless you add `--detach`. This holds on Linux. On Windows, it holds only with the stop-timeout image or the baked image. Refer to [Windows drain](#windows-drain).

### Upgrade the runner on Linux

The runner binary lives on the host in `/opt/smr`, not in the images.

1. Pick the new version. Use the latest `3.1.x` or later, and never a version below 3.1.12. The [runner changelog](https://circleci.com/changelog/runner/) lists releases.
2. On every node, install the new version into `/opt/smr`. Repeat the commands of [Install the runner and the entrypoint](install-linux.md#3-install-the-runner-and-the-entrypoint) with the new `v`, or use the helper with the checksum from the release's `checksums.txt`:

   ```console
   $ sudo linux/setup.sh --install --version <new version> --sha256 <hash>
   ```

   Running containers keep the old binary until Swarm replaces them.

3. Check the version on each node:

   ```console
   $ /opt/smr/bin/circleci-runner --version
   ```

4. Replace the containers. Idle replicas exit after `CIRCLECI_RUNNER_IDLE_TIMEOUT` and pick up the new binary without help. To roll a service now, force an update:

   ```console
   $ docker service update --force smr_linux-default
   ```

5. To roll back, install the previous version on every node and force the update again.

### Upgrade the runner on Windows

> [!IMPORTANT]
> A rolling update stops containers, and a stock Server Core container ends about 5 seconds after a stop. On the plain Microsoft image, every update kills the running jobs of the replica that it replaces. Run stock-image services on the stop-timeout image, or change a service only while its class runs no job. Refer to [Windows drain](#windows-drain).

Windows cannot replace files that a running container uses, so never overwrite `C:\smr`. Stage the new version in a new directory on every Windows node, then point the stack at it.

1. Stage the new directory with the steps of [Stage the runner and Git](install-windows.md#3-stage-the-runner-and-git), with `$smr = 'C:\smr-<new version>'` and the new runner version. The helper does the same:

   ```powershell
   .\windows\Setup.ps1 -InstallDir C:\smr-<new version> -RunnerVersion <new version> -StageOnly
   ```

2. Deploy with `SMR_DIR` set, and with the same `-c` files as before. Swarm performs a rolling update, one replica at a time.

   ```powershell
   $env:SMR_DIR = 'C:\smr-<new version>'
   docker stack deploy -c windows\stack\runners.yaml -c windows\stack\persistent.yaml smr
   ```

3. Set `SMR_DIR` again on every later deploy, or edit the default in your copy of the file.
4. To roll back, deploy again with the previous `SMR_DIR`.
5. Delete the old directory when no container uses it.

### Update the images

- **Linux and Windows stock images.** Change the tag or digest of `image` in your stack file, and run `docker stack deploy`. Swarm resolves a tag to its digest when you deploy, so deploy again to pick up a tag that the publisher re-pushed.
- **Your own images.** Rebuild, push, change the tag, and deploy. Rebuild on a schedule, for example monthly, and when the base image or a tool changes.
- **Windows base images.** Microsoft republishes the Server Core tags each Patch Tuesday. Pin by digest, and rebuild the stop-timeout image and the baked image after each update. Both set the registry value with `reg add`. If you change the build, never use `New-Item -Force` on an existing registry key, because it deletes the values in the key.

For a single service, you can also run `docker service update --image <new image> smr_<service>`. Record the change in your stack file, so that the next deploy does not undo it.

### Upgrade to a new release of this repository

1. Read the [changelog](../CHANGELOG.md). Entries marked `[BREAKING]` say what to change.
2. Compare your stack file with the file of the new release, and merge the differences.
3. Install the new `smr-entrypoint` on every Linux node. The install step copies the runner and the entrypoint together. A new release can change the entrypoint, and the stack runs the copy in `/opt/smr`.
4. Run `docker stack deploy` with the same set of `-c` files as before.

## Rotate a runner token

Swarm secrets are immutable. To rotate a token, create a second secret and swap it into the service. The rolling update replaces one replica at a time, and busy runners finish their job first.

1. Create a new token in CircleCI. Keep the old token until the swap is complete.

   ```console
   $ circleci runner token create <namespace>/linux-default --nickname "linux-default-<date>"
   ```

2. Create a secret with the new token. Use a new name, such as `linux-default-token-v2`.

   ```bash
   read -rsp 'New token: ' TOKEN; echo
   printf 'api:\n  auth_token: %s\n' "$TOKEN" | docker secret create linux-default-token-v2 -
   unset TOKEN
   ```

3. Swap the secrets in the service. On Linux:

   ```console
   $ docker service update \
       --secret-rm linux-default-token \
       --secret-add source=linux-default-token-v2,target=circleci_runner_config.yaml,uid=2000,gid=2000,mode=0400 \
       smr_linux-default
   ```

   On Windows, secrets have no `uid`, `gid`, or `mode`:

   ```powershell
   docker service update `
     --secret-rm windows-default-token `
     --secret-add source=windows-default-token-v2,target=circleci_runner_config.yaml `
     smr_windows-default
   ```

4. Wait until the update completes. The state is `completed`:

   ```console
   $ docker service inspect --format '{{.UpdateStatus.State}}' smr_linux-default
   ```

5. Record the new name in your stack file: change `source:` and the entry under the top-level `secrets:`. A later `docker stack deploy` from the old file then does not revert the swap.
6. Revoke the old token in CircleCI, and remove the old secret.

   ```console
   $ circleci runner token list <namespace>/linux-default
   $ circleci runner token delete <token ID>
   $ docker secret rm linux-default-token
   ```

If a token leaked, create the new token first, swap it as above, and delete the old token at once.

## Drain a node for patching

Draining a node stops its tasks and keeps new tasks away. Swarm sends SIGTERM and waits for the grace period, so a running job finishes. On Windows, this holds only on the stop-timeout image or the baked image. Refer to [Windows drain](#windows-drain). Restarting the Docker daemon stops every running container, because live restore does not work in Swarm mode, so always drain before you patch Docker or reboot.

```console
$ docker node update --availability drain <node name>
$ docker node ps <node name>
```

Wait until `docker node ps` shows no running tasks. Swarm starts the replacement tasks on other nodes at once. If the other nodes lack capacity, the replacements stay `Pending` until the drained tasks exit. Patch and reboot the node, and then return it to service:

```console
$ docker node update --availability active <node name>
```

Tasks do not move back to the node by themselves. Single-task replicas restart after every job, so new tasks spread over the nodes again within a short time. Patch managers one at a time, so the cluster keeps its quorum. Refer to [Managers and quorum](multi-node.md#managers-and-quorum).

### Windows drain

On Linux, a stop lets the running job finish. On Windows, a stop kills the job after about 5 seconds unless the image sets the registry value `WaitToKillServiceTimeout`.

When Docker stops a container, Windows sends the shutdown event to it. The runner turns the event into SIGTERM and drains: it accepts no new job and lets the running job finish. On Server Core, Windows waits only `WaitToKillServiceTimeout` before it ends the processes. The default is 5 seconds, whatever `docker stop -t` or `stop_grace_period` says. The engine waits for the full time, but the container ends its processes first. The container then exits with the code 3221225786 (`0xC000013A`), and the job dies with it.

Every one of these actions stops containers in the same way:

- A rolling update, with `docker stack deploy` or `docker service update`.
- `docker service scale` to a lower number, and `docker stack rm`.
- `docker node update --availability drain`, and a restart of the Docker service.

| Image | A stop while a job runs |
|---|---|
| Stock `mcr.microsoft.com/windows/servercore` | The job is killed after about 5 seconds, with exit code 3221225786 |
| The stop-timeout image (`windows\images\stop-timeout`) | The runner drains and the job finishes, up to `SHUTDOWN_TIMEOUT_SECONDS`. The default is 18300 seconds |
| The baked image | The same, because the baked image sets the value too |

The two images set the value as the registry entry `WaitToKillServiceTimeout`, in milliseconds, under `HKLM\SYSTEM\CurrentControlSet\Control`. Choose a value that is at least the longest job that you allow plus the drain margin. The default of 18300 seconds is `max_run_time` of 5 hours plus 5 minutes. Refer to [Build the stop-timeout image](install-windows.md#4-build-the-stop-timeout-image) and [The baked image](images.md#windows-the-baked-image).

> [!WARNING]
> Never use `New-Item -Force` on an existing registry key, in an image build or in a running container. It replaces the key and deletes its values and subkeys. On the `cexecsvc` service key, it makes the container fail to start with `hcs::System::Start: context deadline exceeded`. Use `reg add` or `Set-ItemProperty`, which set one value.

Microsoft describes the same limit in [hcsshim pull request 1416](https://github.com/microsoft/hcsshim/pull/1416) and in [Windows-Containers issue 164](https://github.com/microsoft/Windows-Containers/issues/164). Microsoft fixed it only in the containerd shim, and Swarm uses the runtime of the Docker engine, which does not have that fix.

The tests stop a container during a job that runs for less than a minute. They do not run a job for hours. Before you rely on a long drain, test it. Run a job of a few minutes on a node that is not in production, force an update of its service with `docker service update --force`, and check that the job finishes.

#### Change a service on the plain Microsoft image

If you run the plain Microsoft image, change a service only while its class runs no job. The runner API shows what a class is doing. Use a personal API token, not a resource class token.

```powershell
$h = @{ 'Circle-Token' = $env:CIRCLECI_API_TOKEN }
Invoke-RestMethod -Headers $h -Uri 'https://runner.circleci.com/api/v3/runner/tasks/running?resource-class=<namespace>/windows-default'
Invoke-RestMethod -Headers $h -Uri 'https://runner.circleci.com/api/v3/runner/tasks?resource-class=<namespace>/windows-default'
```

The first call returns `running_runner_tasks`, and the second returns `unclaimed_task_count`. Wait for `running_runner_tasks` to be 0 in a quiet period, and then run `docker service update` or `docker stack deploy`. A rolling update replaces one replica at a time and interrupts only that replica. Single-task runners also recycle after every job and at the idle timeout, so an idle class is easy to find. A drain of a node and `docker service scale` to a lower number kill running jobs in the same way, so wait for an idle class there too. Refer to the [runner API reference](https://circleci.com/docs/reference/runner-api/).

## Recycle a class

A forced update replaces every replica of a service, one at a time and with a drain. Use it to pick up a new runner binary on the host, or to reset a persistent class.

```console
$ docker service update --force smr_linux-persistent
```

A persistent class keeps state between jobs, and recycling removes only the container filesystem. The named volume survives, so `/home/circleci` on Linux and `C:\cache` on Windows keep their files. To reset the volume as well, scale the service to 0. Then run `docker volume rm smr_smr-persistent-home` (Linux) or `docker volume rm smr_windows-persistent-cache` (Windows) on the node that holds the volume, and scale the service back up.

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
   $ docker stack rm smr
   ```

2. Remove the secrets, and the volumes of persistent classes.

   ```console
   $ docker secret rm linux-default-token linux-java-token linux-hardened-token
   $ docker volume rm smr_smr-persistent-home
   ```

   The volume of the Windows persistent class is `smr_windows-persistent-cache`.

3. Remove the nodes from the Swarm. Run `docker swarm leave` on each worker, then `docker swarm leave --force` on the last manager.
4. Remove the host files:

   ```console
   $ sudo rm -rf /opt/smr
   ```

   ```powershell
   Remove-Item C:\smr -Recurse -Force
   ```

5. Remove the images that you no longer need with `docker image rm`.
6. In CircleCI, delete the tokens and then the resource classes. A class cannot be deleted while it has tokens.

   ```console
   $ circleci runner token list <namespace>/linux-default
   $ circleci runner token delete <token ID>
   $ circleci runner resource-class delete <namespace>/linux-default
   ```

7. On Windows, keep BitLocker on if the host holds other data.
