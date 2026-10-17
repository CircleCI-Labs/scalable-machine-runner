---
page-title: Operations
page-audience: admin
page-description: Runbooks for status and logs, capacity, upgrades, token rotation, proxy restarts, and node drains, then reference for monitoring, backups, compatibility, and uninstall.
---

# Operations

Day-2 tasks for a running stack: the common runbooks first, then reference. Commands use the stack name `runners` and the shipped service names, and run on a manager node.

| Task | Section |
|---|---|
| See what runs, read logs | [Check status and logs](#check-status-and-logs) |
| Add replicas | [Capacity and concurrency](#capacity-and-concurrency) |
| Change the runner, proxy or images | [Upgrade the runner and images](#upgrade-the-runner-and-images) |
| Replace a class token | [Rotate a runner token](#rotate-a-runner-token) |
| Restart the token proxy | [Restart the proxy](#restart-the-proxy) |
| Patch or reboot a node | [Drain a node for patching](#drain-a-node-for-patching) |

On Windows, change a class only while it is idle ([why](#stop-a-busy-windows-container)).

## Check status and logs

1. List services, replicas and tasks (finished tasks stay for a short time, and the `ERROR` column says why a task failed or stays pending):

   ```sh
   docker stack services runners
   docker stack ps runners --no-trunc
   ```

2. Read a class. On Linux, entrypoint lines start with `circleci-runner-entrypoint:`:

   ```sh
   docker service logs --tail 100 --follow runners_linux-default
   ```

3. On Linux, read the distributor. Its `runner-distributor:` lines say which version the node installs and when the link `current` moves:

   ```sh
   docker service logs --tail 50 runners_runner-distributor
   ```

In the web app, **Runners** lists the replicas of each class. A name you do not recognize means someone else holds a token of that class. Healthy single-task replicas show a steady stream of tasks ending in `Complete`, because every finished job ends a task. Alert on:

- Tasks that end with a non-zero exit code, including 80 and 1. Exit code 143 needs no action: a replica that gets SIGTERM while it still retries to reach CircleCI at start-up exits with 143.
- Log lines that start with `circleci-runner: error` or `circleci-runner-entrypoint: error`, and lines with `401`. In the distributor log: `cannot download`, `SHA-256 mismatch`, `error`.
- Tasks that stay `Pending`.
- Many tasks of one node that end within seconds: a node can stay `Ready` and fail every job it claims ([Many jobs fail within seconds on one node](troubleshooting.md#many-jobs-fail-within-seconds-on-one-node)).

## Capacity and concurrency

The replicas of a class are the jobs it runs at once. A job with `parallelism: n` needs `n` replicas. To add replicas:

1. Check demand. `unclaimed_task_count` above 0 for several minutes with every replica busy means the class is full. The API needs a personal API token ([runner API reference](https://circleci.com/docs/reference/runner-api/)):

   ```sh
   RUNNER_API=https://runner.circleci.com
   CLASS=<NAMESPACE>/linux-default
   curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" "$RUNNER_API/api/v3/runner/tasks?resource-class=$CLASS"
   ```

2. Scale, then set the same `replicas` in your stack file:

   ```sh
   docker service scale runners_linux-default=<REPLICAS>
   ```

3. Check that the new replicas run. If they stay `Pending`, the node lacks CPU or memory for the reservations ([Size the limits](resource-classes.md#size-the-limits)):

   ```sh
   docker service ps runners_linux-default --filter desired-state=running
   ```

Two limits sit above the replicas, both on the CircleCI side: the **runner concurrency of your plan** (shared by all self-hosted runner jobs of the organization) and **`maxConcurrentTasks` of the resource class** (20 by default, raised by CircleCI support). Queued tasks count against concurrency, and the inventory shows running tasks only, so runners can look idle while jobs wait. A job for a class with no runner queues indefinitely and holds concurrency: cancel it ([Jobs wait while the runners are idle](troubleshooting.md#jobs-wait-while-the-runners-are-idle)).

The stack has no autoscaling and no cloud integration, and a dead node is not replaced. Plan for one node less than you have. A labeled node of the token proxy carries no replicas ([Where the proxy runs, and when it moves](#where-the-proxy-runs-and-when-it-moves)).

One `token-proxy` replica serves all classes of an OS, because a second would not share the list of runners that have claimed.

- Limits: 0.5 CPU and 128 MB on Linux, 1 CPU and 512 MB on Windows.
- Load: 100 idle runners make 20 claims a second, plus the calls of running jobs. No fleet size is load-tested (CI runs a few replicas).
- Before more than a few dozen replicas, test with your load. Watch `docker stats --no-stream <CONTAINER>` on its node, 503 answers with `Retry-After` in runner logs, and the claim count in its summary line.
- If the proxy is the bottleneck, raise its `limits` in your copy of the stack file. A second stack (own name, proxy, classes and tokens) is untested.

## Upgrade the runner and images

Swarm replaces containers one at a time (`order: stop-first`, `parallelism: 1`). A busy replica gets SIGTERM, drains (finishes its job, takes no new one), and is then replaced. An idle replica stops within about 5 seconds with exit code 0. A busy one exits 0 when its job ends, so an update can take as long as your longest job, up to the `stop_grace_period` of 5 hours and 5 minutes. `docker service update` waits unless you add `--detach`.

| Goal | Section |
|---|---|
| Take a new release | [Upgrade to a new release](#upgrade-to-a-new-release-of-this-repository) |
| Change the runner version only | [Linux](#upgrade-the-runner-on-linux), [Windows](#upgrade-the-runner-on-windows) |
| Change the token proxy | [Upgrade the token proxy](#upgrade-the-token-proxy) |
| Change job or base images | [Update the images](#update-the-images) |

### Upgrade to a new release of this repository

1. Read the [changelog](../CHANGELOG.md). `[BREAKING]` entries say what to change.
2. Merge the differences between your stack file and the new release. Start with the defaults of `x-distributor-env`: a release bumps the runner version and its `MACHINE_RUNNER_SWARM_RUNNER_SHA256` values together.
3. Record the new pin (both defaults merged), or your own pin with its two values, in `deploy/deploy.env` ([why](#keep-the-deploy-variables-in-version-control)).
4. Deploy with the same `-c` files and variables as before:

   ```sh
   sudo ./deploy/deploy.sh
   ```

5. Check the version the distributor selected, then the active one ([See what runs](#see-what-runs)):

   ```sh
   docker service logs --tail 5 runners_runner-distributor
   ```

The entrypoint and distributor script are Swarm configs, and a config cannot change, so its name carries the first 12 hex digits of the SHA-256 of its file. A release that changes a file has new names, and the deploy updates the services that use them: runner services one replica at a time, the distributor on every node. If you edit one of these files in your own copy, rename its config after each edit (old prefix plus the first 12 digits of the new hash), or Swarm keeps the old file:

```sh
sha256sum linux/stack/circleci-runner-entrypoint | cut -c1-12
sha256sum linux/stack/runner-distributor.sh | cut -c1-12
```

In a clone of this repository, `ci/config-names.sh --write` renames the configs of the shipped stack files.

### Upgrade the runner on Linux

The `runner-distributor` service is the only way a runner reaches a Linux node and the only place that sets its version. Runner services carry no version and no hash, so an upgrade, pin or rollback changes the distributor only: no runner service restarts and no job is interrupted ([The runner distributor on Linux](concepts.md#the-runner-distributor-on-linux)).

1. On a node, read the active version ([See what runs](#see-what-runs)).
2. Set the new version and its SHA-256 values in `deploy/deploy.env`. The default is an exact pin that each release bumps, so deploying a newer release is also an upgrade.
3. Deploy:

   ```sh
   sudo ./deploy/deploy.sh
   ```

4. Read the distributor log: it names the version it selects and each flip.
5. Optional: replace the replicas that wait for a job now. An idle replica stops within seconds, a busy one finishes its job first:

   ```sh
   docker service update --force runners_linux-default
   ```

A container resolves the link `current` once, at start. A running job keeps its version, and the next container (next job) gets the new one. Idle replicas keep the old binary until they claim a job or exit after `CIRCLECI_RUNNER_IDLE_TIMEOUT` (1 hour). A persistent class runs one container for all jobs: recycle it ([Recycle a class](#recycle-a-class)).

#### The version policy

The runner version is operator-pinned, as for CircleCI's own runners. The default is an exact pin. A floating value is an opt-in.

| `MACHINE_RUNNER_SWARM_RUNNER_VERSION` | What the nodes run | Changes by itself |
|---|---|---|
| An exact version, `3.1.13` (the default) | That version: the newest the CI tests, bumped by each release ([how](releasing.md#bump-the-runner-version)). The stack file carries the SHA-256 of its tarballs | Never. Once installed, the distributor makes no request for it |
| `3.1` | The newest `3.1.x` in CircleCI's manifest | At every `MACHINE_RUNNER_SWARM_CHECK_INTERVAL` (default 24 hours) |
| `3` | The newest `3.x.y` in the manifest | At every check interval |
| `current` | CircleCI's current release, within `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` (default `3`) | At every check interval |

An exact pin takes the tarball SHA-256 from the stack file, so it asks no manifest. Once verified, each interval it only compares the active binary with its record, and reinstalls if the binary changed. A floating value reads `manifest.json` at start and every interval. `current` is matched to a versioned manifest entry by SHA-256 and adopted only within `MACHINE_RUNNER_SWARM_RUNNER_MAJOR`; another major logs `not adopting it` and keeps what is installed. A release reaches every node within one interval, with no redeploy. In a stack file, quote a floating value (`"3.1"`): YAML reads `3.1` as a number and `3.10` as `3.1`.

**Floating is weaker.** A floating value cannot keep a SHA-256 list, so the distributor ignores the default list and takes each tarball's SHA-256 from CircleCI's `manifest.json`. That file comes from the same bucket as the tarball, so whoever can change one can change both, and the check proves only that the download is whole. Use it only for a class that may run whatever CircleCI releases. It can also bring a runner this release has not been tested with ([Compatibility with CircleCI](#compatibility-with-circleci)).

#### Settings of the distributor

Variables of `docker stack deploy`, for the distributor service only. `linux/stack/runners.yaml` reads them in `x-distributor-env`.

| Variable | Default | Effect |
|---|---|---|
| `MACHINE_RUNNER_SWARM_RUNNER_VERSION` | The newest version CI tests (`3.1.13` in this release) | An exact version pins it. `3.1`, `3` and `current` float ([the version policy](#the-version-policy)) |
| `MACHINE_RUNNER_SWARM_RUNNER_MAJOR` | `3` | The major version `current` may adopt |
| `MACHINE_RUNNER_SWARM_CHECK_INTERVAL` | `24h` | How often a floating version asks the manifest again, and how often a pin's installed copy is verified. Seconds, or a number with `s`, `m`, `h` or `d` |
| `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` | `https://circleci-binary-releases.s3.amazonaws.com/circleci-runner` | Where `manifest.json` and the tarballs are ([mirror](#run-the-downloads-from-a-mirror)). Must be `https://`, unless a SHA-256 list is set |
| `MACHINE_RUNNER_SWARM_RUNNER_SHA256` | The four tarball SHA-256 values of the pinned version (`amd64`, `arm64`, `ppc64le`, `s390x`) | A comma-separated list for an exact pin, covering every architecture of your nodes. The distributor installs nothing else, whatever the manifest says. A version of your own needs its own values (the `checksums.txt` of its release) or `manifest` (the manifest hash is trusted: weaker). A floating value ignores any list ([Runner binary integrity on Linux](security.md#runner-binary-integrity-on-linux)) |
| `MACHINE_RUNNER_SWARM_ALLOW_HTTP` | Not set | `true` accepts an `http://` base without a SHA-256 list. For a lab: the manifest hash then protects nothing against someone on the path |

The token proxy is an image, not a distributor setting ([Upgrade the token proxy](#upgrade-the-token-proxy)). The architectures are those of CircleCI's manifest (`uname -m`). Another one stops the distributor with `unsupported architecture`.

A variable must reach every `docker stack deploy`, because a deploy without it sets the default again: keep them in a file. For a try, pass one with `env`, because `sudo` drops the environment:

```sh
sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1 docker stack deploy -c deploy/runners.yaml runners
sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1 linux/setup.sh --deploy --stack-file deploy/runners.yaml
```

#### Pin a version

The default is an exact pin. Pin when a runner change must go through your change process, then upgrade by changing the pin or taking a newer release. The default SHA-256 list belongs to the default pin, so a pin of your own needs its values in the same command, from the `checksums.txt` of that runner release, for every architecture of your nodes:

```sh
sudo env MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 MACHINE_RUNNER_SWARM_RUNNER_SHA256=<SHA256_AMD64>,<SHA256_ARM64> docker stack deploy -c deploy/runners.yaml runners
```

Put the same two values in `deploy/deploy.env`. The distributor installs only a tarball with one of these values. Without the list it refuses the tarball (`SHA-256 mismatch`) and the nodes keep the running version. `MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest` trusts the manifest instead (weaker). If you edit the pin in your copy of the stack file, change both defaults together in `x-distributor-env` (and in `x-env` of `microvm.yaml`, which downloads the runner itself). Use `3.1.12` or later: it fixes the enforcement of `max_run_time`.

**Freeze the nodes now.** Pin the version the nodes run now ([See what runs](#see-what-runs)). It is installed, so no network is needed. Record the same two values in `deploy/deploy.env`:

```sh
docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=<VERSION> --env-add MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest runners_runner-distributor
```

#### Roll back

A rollback is a pin of an older version, with its hash policy:

```sh
docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=<VERSION> --env-add MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest runners_runner-distributor
```

The distributor keeps the last 3 active versions (about 75 MB each) and never removes the active one. A rollback to a kept version only moves the link: no download, no network. A removed version is downloaded again, with its hash from the manifest or from a list you give. The file `history` in the volume lists the flips. The next container of every runner service runs the old version, and running jobs are unaffected. Record the same values in `deploy/deploy.env`.

#### See what runs

```sh
docker service logs --tail 20 runners_runner-distributor
```

The volume `runners_runner-bin` exists on every node. On the node to inspect:

```sh
docker run --rm -v runners_runner-bin:/v:ro alpine readlink /v/current
docker run --rm -v runners_runner-bin:/v:ro alpine cat /v/history
docker top <CONTAINER_ID> | grep circleci-runner
```

The last command names the version directory that a container resolved at start. When a node gets no runner or a download is refused, refer to [The runner waits for the distributor, and then exits with code 80](troubleshooting.md#the-runner-waits-for-the-distributor-and-then-exits-with-code-80).

#### Run the downloads from a mirror

A site without a route to CircleCI's release bucket serves `<VERSION>/circleci-runner_linux_<ARCH>.tar.gz` for every version the nodes may run from an internal HTTP server. The distributor builds the tarball address from the base URL and version and ignores the manifest's `url` fields, so a copy of `manifest.json` stays unchanged.

| Setting | Reads `manifest.json` | The mirror must hold |
|---|---|---|
| An exact pin with its SHA-256 list (the default) | Never | The pinned version's tarballs, per node architecture |
| An exact pin of your own with `manifest` instead of a list | Only when the version is not installed yet | The tarballs, and `manifest.json` with an entry for that version |
| A floating value | At every start and check interval | `manifest.json`, kept current, and the tarballs it may pick |

```sh
base=https://circleci-binary-releases.s3.amazonaws.com/circleci-runner
mkdir -p mirror && curl -fsSL "$base/manifest.json" -o mirror/manifest.json
jq -r '.releases | keys[] | select(test("^[0-9]"))' mirror/manifest.json
for v in 3.1.12 3.1.13; do
  mkdir -p "mirror/$v"
  for arch in amd64 arm64; do
    curl -fsSL "$base/$v/circleci-runner_linux_$arch.tar.gz" -o "mirror/$v/circleci-runner_linux_$arch.tar.gz"
  done
done
```

Serve `mirror` and point the distributor at it:

```sh
sudo env MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=https://mirror.example.com/circleci-runner docker stack deploy -c deploy/runners.yaml runners
```

- With an exact pin, keep the previous version too, for a rollback. With a floating version, copy its line's versions and refresh `manifest.json` to let nodes adopt a release. With `current`, copy the version it names:

  ```sh
  jq -r '.releases as $r | $r.current.linux.amd64.sha256 as $s | $r | to_entries[] | select(.key | test("^[0-9]")) | select(.value.linux.amd64.sha256 == $s) | .key' mirror/manifest.json
  ```

- The distributor uses the `wget` and CA bundle of the stock Alpine image, so an `https` mirror needs a certificate from a public authority. Otherwise use an `http://` mirror with the SHA-256 list (the list, not the transport, is what you trust), or an image of your own for `runner-distributor` (`FROM` the pinned Alpine, your CA added; not tested). Do not use one proxy for both the distributor and the mirror ([Proxies and certificate authorities, component by component](#proxies-and-certificate-authorities-component-by-component)).
- Over plain `http`, an exact pin needs a usable SHA-256 list (the default one is enough), because the manifest would otherwise be the only root of trust and would travel unprotected. A floating value has no list, so it is refused. `MACHINE_RUNNER_SWARM_ALLOW_HTTP=true` accepts it for a lab.
- The mirror replaces the runner download only. Every runner container still downloads its task agent from `circleci-binary-releases.s3.amazonaws.com`, and every node still pulls `alpine` from a registry ([Does it work on hosts without internet access?](faq.md#does-it-work-on-hosts-without-internet-access)).

### Upgrade the runner on Windows

The service `runner-distributor-windows` is the only way a runner and Git reach a Windows node. It works like the [Linux distributor](#upgrade-the-runner-on-linux): same variables ([table](#settings-of-the-distributor)), same policy, no version in the runner services. An upgrade, pin or rollback changes the distributor only, so **no runner service restarts and no busy job is killed.**

It installs into the volume `runner-bin` (`versions\<VERSION>` for the runner, `git\<GIT_VERSION>` for portable Git) and mounts the links `current` and `git\current` read-only at `C:\machine-runner-swarm` and `C:\Program Files\Git`. Docker resolves a link when it creates a container, so the next job runs the new version and a running job keeps its directory. The distributor never overwrites a version or removes one in use (Windows cannot replace files a running container uses): it tries again at its next check. During a flip `current` is missing for a few milliseconds, and a container created then does not start (Swarm retries after the restart delay of 10 seconds). On a new node, runner tasks fail the same way until the first download is done.

Differences from Linux, in `x-distributor-env` of `windows\stack\runners.yaml`:

- `MACHINE_RUNNER_SWARM_RUNNER_SHA256` defaults to the two values (`amd64`, `arm64`) of the pinned version.
- `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` holds `manifest.json` and `<VERSION>/circleci-runner_windows_<ARCH>.tar.gz`. It must be `https://` (or `file://`), unless a SHA-256 list is set.
- `MACHINE_RUNNER_SWARM_TOOLS_BASE_URL` is a directory URL with `PortableGit-<VERSION>-64-bit.7z.exe` (arm64: `-arm64.7z.exe`) and `7zr.exe`, the two downloads the script pins by SHA-256. Without it they come from GitHub.
- The architecture is `amd64` or `arm64`. CI runs the distributor on amd64 hosts only: arm64 file names and manifest entries are tested, and no Windows arm64 host runs the stack.
- There is no start-time binary check (no entrypoint script): the distributor compares the active binary with its record at every check and reinstalls it if it changed ([Runner binary integrity on Windows](security.md#runner-binary-integrity-on-windows)).
- A mirror needs the `windows` tarballs, the two Git downloads in the tools directory, and `manifest.json` where the [Linux mirror table](#run-the-downloads-from-a-mirror) says. The distributor downloads with PowerShell, so an `https` mirror needs a certificate the stock Server Core image trusts (not your own authority): otherwise use an `http://` mirror with the SHA-256 list, or an image of your own. It reads only `HTTPS_PROXY`.

Set the variables in the shell that runs the deploy, and keep them in a file ([Keep the deploy variables in version control](#keep-the-deploy-variables-in-version-control)). `3.1` trusts the manifest hash (weaker):

```powershell
$env:MACHINE_RUNNER_SWARM_RUNNER_VERSION = '3.1'
docker stack deploy -c deploy\runners.yaml runners
```

To freeze the nodes or roll back, pin the installed or an older version (no network for a kept version; the last 3 active versions are kept), with the hash policy as on Linux:

```powershell
docker service update --env-add MACHINE_RUNNER_SWARM_RUNNER_VERSION=<VERSION> --env-add MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest runners_runner-distributor-windows
```

`docker service logs runners_runner-distributor-windows` shows each flip. On the node, this shows the history and the active version:

```powershell
docker run --rm --mount type=volume,source=runners_runner-bin,target=C:\v,readonly mcr.microsoft.com/windows/servercore:ltsc2022 powershell -Command "Get-Content C:\v\history; (Get-Item C:\v\current).Target"
```

Waiting replicas keep the old version until they claim a job or exit after `CIRCLECI_RUNNER_IDLE_TIMEOUT` (1 hour). To replace them at once, force an update only while the class is idle (`docker service update --force runners_windows-default`).

### Upgrade the token proxy

The proxy is the image `ccilabs/machine-runner-swarm-proxy`, read from `MACHINE_RUNNER_SWARM_PROXY_IMAGE` by the service `token-proxy` (Windows: `token-proxy-windows`). Tags: `X.Y.Z` (a release, never moves), `X.Y`, `X`, `latest` (the newest release), `edge` (the newest main-branch commit that passed the end-to-end tests) and `sha-<12 characters>` ([The token proxy image](install-linux.md#the-token-proxy-image)). A release bundle defaults to its own release by tag and digest. A checkout defaults to `latest`, which only a release moves.

- **With the release.** Deploy the stack files of the new release ([Upgrade to a new release of this repository](#upgrade-to-a-new-release-of-this-repository)).
- **Pin a digest.** Set `ccilabs/machine-runner-swarm-proxy@sha256:<DIGEST>` in the environment of every deploy (`deploy/deploy.env`). A digest is the only pin a re-pushed tag cannot move. Read it in the release notes, in the bundle (`grep MACHINE_RUNNER_SWARM_PROXY_IMAGE stack/runners.yaml`), or with the command below, and check the signature first ([Verify the token proxy image](security.md#verify-the-token-proxy-image)):

  ```sh
  docker buildx imagetools inspect ccilabs/machine-runner-swarm-proxy:<VERSION>
  ```

- **Change the running service.** Swarm stops the old proxy before it starts the new one (a second proxy would allow a second claim). Runners cannot claim for a few seconds, and every runner that has claimed stays refused ([Restart the proxy](#restart-the-proxy)). Record it in `deploy/deploy.env`. A tag such as `latest` is resolved to a digest at deploy: deploy again to pick up a newer one.

  ```sh
  docker service update --image <IMAGE> runners_token-proxy
  ```

- **Roll back.** Deploy the previous digest or version.

An air-gapped site mirrors the image (this keeps every platform), copies its signature with `cosign copy`, and sets `MACHINE_RUNNER_SWARM_PROXY_IMAGE=<REGISTRY>/<NAME>:<TAG>`:

```sh
docker buildx imagetools create --tag <REGISTRY>/<NAME>:<TAG> ccilabs/machine-runner-swarm-proxy:<VERSION>
```

### Update the images

- **Stock and your own images.** Change the tag or digest of `image` in your stack file and deploy. Swarm resolves a tag to a digest at deploy: deploy again to pick up a re-pushed tag. Rebuild your own images on a schedule (for example monthly) and when the base image or a tool changes.
- **The distributor image.** `runner-distributor` runs `alpine:3`, pinned by digest. Change the digest and deploy. It restarts on every node at once, and no running job is affected.
- **Windows base images.** Microsoft republishes the Server Core tags each Patch Tuesday. Pin by digest, rebuild your images on top, and change a Windows service only while its class is idle.

For one service: `docker service update --image <IMAGE> runners_<SERVICE>`. Record it in your stack file.

## Rotate a runner token

Swarm secrets are immutable: create a second secret and swap it into the service that holds the token. Single-task classes (Linux and Windows) hold it in `token-proxy` (Windows: `token-proxy-windows`), one replica, so the swap takes seconds and runners are not touched. Persistent classes hold it in the class service, which updates one replica at a time: a busy replica is replaced after its job ends (up to 5 hours and 5 minutes), so N replicas can take N times that. Raise `update_config.parallelism` in the stack file, or pass `--update-parallelism <NUMBER>` once (`0` replaces every replica at once).

1. Create a new token in CircleCI. Keep the old one until the swap is complete:

   ```sh
   circleci runner token create <NAMESPACE>/linux-default --nickname "linux-default-<DATE>"
   ```

2. Create a secret with a new name, such as `linux-default-token-v2`:

   ```sh
   printf 'New token (hidden): '; stty -echo; IFS= read -r TOKEN; stty echo; echo
   [ -n "$TOKEN" ] && printf 'api:\n  auth_token: %s\n' "$TOKEN" | docker secret create linux-default-token-v2 -
   unset TOKEN
   ```

3. Swap the secret. Single-task class on Linux, in the proxy. Keep the `target`: the proxy names a class after the file `<SERVICE>-token`, and a new name makes a new class that no runner belongs to:

   ```sh
   docker service update \
     --secret-rm linux-default-token \
     --secret-add source=linux-default-token-v2,target=linux-default-token,uid=65534,gid=65534,mode=0400 \
     runners_token-proxy
   ```

   Single-task class on Windows, in `token-proxy-windows` (Windows secrets have no `uid`, `gid` or `mode`):

   ```powershell
   docker service update `
     --secret-rm windows-default-token `
     --secret-add source=windows-default-token-v2,target=windows-default-token `
     runners_token-proxy-windows
   ```

   Persistent class on Linux, in the service (on Windows, the same without `uid`, `gid` and `mode`):

   ```sh
   docker service update \
     --secret-rm linux-persistent-token \
     --secret-add source=linux-persistent-token-v2,target=circleci_runner_config.yaml,uid=2000,gid=2000,mode=0400 \
     runners_linux-persistent
   ```

   The proxy restarts with its state from `proxy-state`, so only runners that have not claimed may claim. Recycle runners only when the start log says `no state` or `state lost` ([Restart the proxy](#restart-the-proxy), and on Windows [Replace refused runners on Windows](#replace-refused-runners-on-windows)), or wait for the idle timeout.

4. Wait until the update state is `completed`:

   ```sh
   docker service inspect --format '{{.UpdateStatus.State}}' runners_token-proxy
   ```

5. Record the new name in your stack file: `source:` and the entry under the top-level `secrets:` (for the proxy, the `source:` of the class under `token-proxy`). Otherwise a later deploy from the old file reverts the swap.
6. Revoke the old token and remove the old secret:

   ```sh
   circleci runner token list --resource-class <NAMESPACE>/linux-default
   circleci runner token delete <TOKEN_ID>
   docker secret rm linux-default-token
   ```

### If a token leaked

The old token stays valid for anyone who holds it until it is deleted in CircleCI, so delete it before the swap. Delete it as soon as its replacement exists.

1. Create the new token and secret (steps 1 and 2 above).
2. Delete the old token at once (the commands of step 6). CircleCI stops accepting it for new claims, and running jobs continue. A proxy or persistent runner that still holds the old secret fails with 401, so the class claims no new jobs until step 3 completes.
3. Swap the secret as in step 3. Then replace the idle runners of a single-task class (`docker service update --force --update-parallelism 0 runners_<SERVICE>`; on Windows, [Replace refused runners on Windows](#replace-refused-runners-on-windows)). In a persistent class, add `--update-parallelism 0` to the swap command so that every replica is replaced at once, each after its running job (on Windows, a running job ends: rerun it).
4. Do steps 4 and 5, and remove the old secret. Then look for what the token did: unknown names in the runner inventory in CircleCI, and the jobs that ran on the class.

A leaked single-task token did not come from a job in a runner container, because those hold no token. Look at who can read Swarm secrets (the `docker` group on a manager), at the proxy node, and at manager backups. Rotate the tokens of every class whose secret that path reached, because the proxy holds all of them.

## Restart the proxy

A restart is safe at any time, on the same node. The proxy keeps the addresses of runners that have claimed in the volume `proxy-state` and refuses only those afterwards. A runner that has not claimed may claim, so no restart, deploy or reboot locks a runner out.

1. Restart (Windows: `runners_token-proxy-windows`):

   ```sh
   docker service update --force runners_token-proxy
   ```

2. Read the start line:

   ```sh
   docker service logs --tail 30 runners_token-proxy
   ```

3. `state restored; <CLASS>: N runner(s) have claimed and stay refused` means you are done. `no state` or `state lost` with running tasks at CircleCI means the runners present are refused (403) until they recycle. Replace the idle ones on a Linux class:

   ```sh
   docker service update --force --update-parallelism 0 runners_linux-default
   ```

   A busy Linux replica finishes its job first. On a Windows class, use [Replace refused runners on Windows](#replace-refused-runners-on-windows) instead.

The image does not change on restart (same tag or digest, unless the tag moved): see [Upgrade the token proxy](#upgrade-the-token-proxy). A stop (this command, a deploy, a node shutdown) lets claims in flight finish, for 8 seconds at most, so a claim CircleCI has answered and that is saved reaches its runner. That is the Linux figure. On Windows, a stop can cut off a claim in flight ([A claim whose outcome is unknown](#a-claim-whose-outcome-is-unknown)).

The start line names one of these states for each class:

- **`state restored`.** All N latched addresses stay refused, also those DNS does not list yet, until DNS has not listed them for 30 seconds in a row.
- **`no state (a first start)` with `CircleCI reports 0 running tasks`.** `proxy-state` was empty and no task of the class runs, so the runners present may claim.
- **`no state (a first start)` with `CircleCI reports M running task(s)`, or `CircleCI does not say how many tasks run`.** The proxy cannot tell which runners hold the tasks, so it fails safe and latches every runner present until Swarm replaces it.
- **`state lost; ...` or `no state directory; ...`.** The state file is damaged or removed, or there is no state directory: the same decision for every class, from what CircleCI says.

With no state the proxy asks CircleCI (`GET /api/v3/runner/scale` with each class's token, up to three times, within 25 seconds in all). With no running task the runners present may claim. With a running task, or when the call fails, is late or answers anything else, the proxy latches every runner of that class present, so a runner that holds a job cannot claim a second one. A refused runner gets 403 until it recycles: at its idle timeout (1 hour in the shipped files) or at once with the command above.

## Drain a node for patching

Restarting the Docker daemon stops every container (live restore does not work in Swarm mode), so empty the node before you patch Docker or reboot. On Linux, a drain sends SIGTERM and waits for the grace period, so running jobs finish. On Windows, use [A Windows node](#a-windows-node) instead.

1. Drain:

   ```sh
   docker node update --availability drain <NODE>
   ```

2. Wait until no task runs on it. Swarm starts replacements elsewhere at once. If the other nodes lack capacity, they stay `Pending` until the drained tasks exit:

   ```sh
   docker node ps <NODE>
   ```

3. Patch and reboot. Unlock a manager that uses autolock ([Unlock a locked swarm](#unlock-a-locked-swarm)).
4. Return the node to service:

   ```sh
   docker node update --availability active <NODE>
   ```

Tasks do not move back by themselves, but single-task replicas restart after every job, so new tasks spread out again soon. Patch managers one at a time to keep the quorum ([Managers and quorum](multi-node.md#managers-and-quorum)), and the proxy node last ([The node of the proxy](#the-node-of-the-proxy)).

### A Windows node

Use `pause`, which keeps new tasks away and stops nothing:

```powershell
docker node update --availability pause <NODE>
docker node ps <NODE> --filter desired-state=running
```

A running job keeps its container. Each replica that finishes exits, and Swarm starts its replacement elsewhere, so the node empties by itself. An idle replica exits only at its idle timeout (1 hour) and can claim a job until then, so the upper bound is the idle timeout plus the longest job. When the second command prints nothing, drain the node (no job is left to kill), patch it and set it `active`.

### No unattended changes

An update that restarts the Docker daemon or the node ends every container on it (on Windows that kills jobs). On every node, switch off whatever patches or restarts without you:

- **Windows.** Set the Windows Update policy to download and notify. Install and reboot only in the procedure above.
- **Debian and Ubuntu.** Set `Unattended-Upgrade::Automatic-Reboot "false"`. Hold the Docker packages, because a `docker-ce` upgrade restarts the daemon: `sudo apt-mark hold docker-ce docker-ce-cli containerd.io` (and `unhold` for the planned upgrade). Set `needrestart` to list only: `$nrconf{restart} = 'l';`.
- **RHEL and its clones.** Turn off automatic installation in `dnf-automatic` (or limit it to a download), and version-lock the Docker packages.

### The node of the proxy

Draining the node that runs `token-proxy` stops the proxy. A proxy pinned to a labeled node stays `Pending` until that node is `active`, then starts there with its state. No claim is possible meanwhile, so choose a quiet period and patch that node last. A proxy with the default placement moves to another manager and its state stays behind ([Where the proxy runs, and when it moves](#where-the-proxy-runs-and-when-it-moves)). Draining every manager, or the only node that can run the proxy, stops every claim: keep one node undrained for it ([the warning in Multi-Node Clusters](multi-node.md#managers-and-quorum)).

### Stop a busy Windows container

On Linux, a stop lets the running job finish. On Windows, stopping a busy container from outside kills its job after about 5 seconds. The normal flow is unaffected: a job finishes, the runner exits, the container ends cleanly, and Swarm starts a new one.

When Docker stops a container, Windows sends it the shutdown event. The runner turns it into SIGTERM and drains, but on Server Core Windows waits only the registry value `WaitToKillServiceTimeout` before it ends the processes. The default is 5 seconds, whatever `docker stop -t` or `stop_grace_period` says. The container exits with code 3221225786 (`0xC000013A`) and the job dies with it. These stop containers this way: a rolling update (`docker stack deploy`, `docker service update`), `docker service scale` to a lower number, `docker node update --availability drain`, `docker stack rm`, and a restart of the Docker service. Roll out changes while the class is idle, or rerun the interrupted jobs.

Microsoft describes the limit in [hcsshim pull request 1416](https://github.com/microsoft/hcsshim/pull/1416) and [Windows-Containers issue 164](https://github.com/microsoft/Windows-Containers/issues/164). It is fixed only in the containerd shim, and Swarm uses the Docker engine runtime. [`Test-StopHandling.ps1`](../windows/tests/Test-StopHandling.ps1) measures the rule in every CI run with a fake 40 second job.

To find an idle class, use a personal API token (on CircleCI server, set `$api` to your runner API URL). Update or deploy when `running_runner_tasks` is 0:

```powershell
$h = @{ 'Circle-Token' = $env:CIRCLECI_API_TOKEN }
$api = 'https://runner.circleci.com'
Invoke-RestMethod -Headers $h -Uri "$api/api/v3/runner/tasks/running?resource-class=<NAMESPACE>/windows-default"
```

#### Optional: an image that lets a job finish after a stop (DIY)

Your own image can lift the limit by setting `WaitToKillServiceTimeout` once, at build time, in milliseconds: at least your longest job plus a margin. This example is 18,300,000 (5 hours and 5 minutes, the runner's `max_run_time` plus 5 minutes):

```dockerfile
FROM mcr.microsoft.com/windows/servercore:ltsc2022
RUN reg add HKLM\SYSTEM\CurrentControlSet\Control /v WaitToKillServiceTimeout /t REG_SZ /d 18300000 /f
```

> [!NOTE]
> Set the value at build time. Setting it at run time with `reg add` inside a running container does not work: Windows reads the value only when the container boots.

Use it as the `image:` of the service, which still mounts the runner and Git and sets `PATH` as in the shipped stack file. Build one image per Server Core tag, and rebuild it after each Patch Tuesday update of the base image.

> [!WARNING]
> Never use `New-Item -Force` on an existing registry key, in an image build or a running container. It replaces the key and deletes its values and subkeys. On the `cexecsvc` service key, the container then fails to start with `hcs::System::Start: context deadline exceeded`. Use `reg add` or `Set-ItemProperty`, which set one value.

Machine runner swarm does not build or test such an image. Before you rely on it, run a job of a few minutes on a non-production node, force an update of its service, and check that the job finishes.

## Run the cluster

Reference for production: logs that survive, signals to watch, deploy variables, backups, certificates and failures.

### Ship the logs

`docker service logs` reads only logs of tasks Swarm still holds. Every finished job ends a task, and the task history limit of 2 makes Swarm prune old tasks, so a job log is gone after a few more jobs. The stack files keep logs on the node (`local` driver on Linux, 3 files of 20 MB; `json-file` on Windows) and rotate them.

The token proxy logs one line (about 85 bytes) per forwarded claim, a 204 included: about one per idle runner every 5 seconds. With 50 idle runners that is about 70 MB a day, so the Linux proxy's 60 MB wrap in under a day and the Windows proxy's 10 MB in a few hours, and the lines that matter after an incident (`refused`, `state restored`, `released`) are among the first lost. Before the fleet is large, ship the proxy log off the node or raise `max-file` of `token-proxy` in your copy of the stack file. To keep logs, choose one:

- **A logging driver.** Change `logging:` in your copy of every stack file to a shipping driver such as `syslog`, `fluentd` or `gelf`. The stack files set the driver per service, so a default in `daemon.json` does not apply. `docker service logs` then fails for these drivers.
- **A log agent on every node.** It reads container logs through the Docker API and forwards them. The stack files stay as they are, and `docker service logs` keeps working.

### Monitor the cluster

On a manager:

```sh
docker service ls
docker node ls
docker stack ps runners --filter desired-state=running --format '{{.Name}} {{.Node}} {{.CurrentState}}' | grep -v Running
```

This counts, per node, the tasks that ended within the last minute or so. A node with many such tasks either fails its jobs or has more work than the others ([Many jobs fail within seconds on one node](troubleshooting.md#many-jobs-fail-within-seconds-on-one-node)):

```sh
docker stack ps runners --format '{{.Node}} {{.CurrentState}}' | grep -E ' (Complete|Failed) [0-9]+ seconds? ago' | cut -d' ' -f1 | sort | uniq -c | sort -rn
```

The runner API shows what CircleCI sees (personal API token; `runner.circleci.com` on cloud, or your server's runner API URL: [CircleCI server, proxies, and hosts without internet](#circleci-server-proxies-and-hosts-without-internet)). Set `RUNNER_API` and `CLASS` as in [Capacity and concurrency](#capacity-and-concurrency), then:

```sh
curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" "$RUNNER_API/api/v3/runner?resource-class=$CLASS" | jq -r '.items[] | "\(.name) \(.last_connected)"'
curl -s -H "Circle-Token: $CIRCLECI_API_TOKEN" "$RUNNER_API/api/v3/runner/tasks/running?resource-class=$CLASS"
```

| Signal | Where | Alert when |
|---|---|---|
| Replicas and nodes | `docker service ls`, `docker node ls` | Fewer replicas than desired for over 10 minutes ([A task stays pending](troubleshooting.md#a-task-stays-pending)), a node not `Ready`, a manager `Unreachable`, or no `Leader` |
| Runners connected | `/api/v3/runner`: `items`, `last_connected` | Fewer items than replicas, or `last_connected` older than 2 minutes |
| Jobs that wait or run | `/api/v3/runner/tasks`: `unclaimed_task_count`. `/api/v3/runner/tasks/running`: `running_runner_tasks` | `unclaimed_task_count` above 0 for several minutes ([concurrency](#capacity-and-concurrency)). `running_runner_tasks` equal to the replicas for a long time: the class is full |
| Task exits, distributor | `docker service ps`, `docker service ps runners_runner-distributor` | Exit code 80, a restart loop ([The container restarts every 10 seconds](troubleshooting.md#the-container-restarts-every-10-seconds)), fewer distributor tasks than Linux nodes, `cannot download`, `SHA-256 mismatch`, or `not adopting it` (`current` is not a version the distributor follows) |
| Disk | `df -h /var/lib/docker` on every node, `docker system df` | Above 80 percent on a worker, 70 percent on a manager ([Free disk space](#free-disk-space)) |
| Token proxy | `docker service ps runners_token-proxy`, `docker stats --no-stream` on its node, its summary line | Restarts, CPU near the limit, or rising refused claims ([Monitor the token proxy](#monitor-the-token-proxy)) |
| A job that starts | A canary job per class | The canary fails, or does not start within a few minutes |

A canary job runs the whole path (web app, CircleCI, proxy, node, runner), so it catches what the Swarm view does not: a healthy proxy that refuses every runner, a class whose token CircleCI rejects, and a plan with no concurrency left. It does not say which node is at fault. Run it on a schedule from a project of your own, per class:

```yaml
version: 2.1
jobs:
  canary:
    machine: true
    resource_class: <NAMESPACE>/linux-default
    steps:
      - run: echo ok
workflows:
  canary:
    when:
      equal: [scheduled_pipeline, << pipeline.trigger_source >>]
    jobs:
      - canary
```

### Monitor the token proxy

Every claim of a single-task class goes through the service `token-proxy` (Windows: `token-proxy-windows`, same log lines). It runs as one replica, and runners cannot claim without it ([The token proxy](concepts.md#the-token-proxy)).

```sh
docker service ps runners_token-proxy
docker service logs --tail 30 runners_token-proxy
```

`GET /healthz` answers 200 when every class has a usable token file. The health check is the proxy binary with `-healthcheck` (`/machine-runner-swarm-proxy` on Linux, `C:\machine-runner-swarm-proxy.exe` on Windows), because the images have no `curl` or `wget`. Swarm runs it every 10 seconds and restarts the task after 3 failures. A start can take up to 25 seconds before the proxy listens, so `start_period` is 30 seconds on Linux and 40 on Windows. The log has one line per event and never a token:

| Log line | Meaning |
|---|---|
| `listening on :8080, upstream <HOST>, classes tasks.linux-default,...` | Started. One class per secret `<SERVICE>-token` it holds. A class missing here gets 403 from its runners: its secret is not mounted in `token-proxy` or not named `<SERVICE>-token` |
| `claim from <IP_ADDRESS> (tasks.<SERVICE>): upstream status 204` or `200` | 204: no task (normal, about every 5 seconds per idle runner). 200: a task was handed out, and that runner cannot claim again |
| `released <IP_ADDRESS> (tasks.<SERVICE>)` | DNS has not listed the address for 30 seconds in a row: the container is gone, and a new one on that address may claim |
| `claim from <IP_ADDRESS> refused: not a runner of any class (tasks.<SERVICE> lists [...], ...)` | Not a runner of a configured class, or one DNS does not list yet. Compare with the addresses in the line. Look for a class added without adding it to the proxy |
| `claim from <IP_ADDRESS> refused: this runner has already claimed a task` | A second claim from one container. After a restart, a runner that has claimed gets this until Swarm replaces it ([Restart the proxy](#restart-the-proxy)) |
| `claim from <IP_ADDRESS> refused: too many claims` | More than 2 claims a second from one container (429) |
| `state: cannot write it: ...` | [When the proxy cannot save its state](#when-the-proxy-cannot-save-its-state) |
| `claim from <IP_ADDRESS> (tasks.<SERVICE>): upstream status 401` | CircleCI rejects the class token: deleted, or the secret holds another class's token ([The runner log shows 401](troubleshooting.md#the-runner-log-shows-401)) |
| `upstream error: ...` | The proxy node cannot reach the runner API, or the connection broke (runners get 502). A claim that had reached CircleCI is latched ([A claim whose outcome is unknown](#a-claim-whose-outcome-is-unknown)) |
| `cannot resolve the runners`, `token file` | Swarm DNS or a class secret is unavailable (runners get 503). No latch is released meanwhile |
| One summary line a minute | Claims forwarded, latched and refused, refusals by reason. Rising refusals while runners are healthy point to the causes above. The wording can change between releases: alert on the numbers |

**Limits.** Each client IP gets 2 claims a second (burst 10, answer 429) and 50 requests a second (burst 200) on all paths. At most 512 requests are served at once, and one above that gets 503 with `Retry-After`. The proxy waits 60 seconds for CircleCI's response headers. A runner and a job stay far below these numbers.

**If the proxy is down,** runners cannot claim and CircleCI keeps jobs queued. Idle runners keep polling and fail, and they cannot go around the proxy, because they hold only the placeholder. A runner that runs a job keeps its container, but its calls and its task agent's calls to the API fail meanwhile. `linux/tests/proxy.sh` measures this with the real runner: a proxy restart while jobs run does not end them, and a proxy down when jobs end only delays the report (the runner sends the end of the job once the proxy is back and exits 0). The end-to-end test restarts the proxy in the middle of a real job too (probe `b2`). Swarm restarts a failed proxy task after 5 seconds on Linux and 10 on Windows, so an outage that short is harmless. Do not leave the proxy down long while jobs run: how long the real task agent keeps retrying is not documented.

#### Replace refused runners on Windows

`docker service update --force` replaces every container of a service at once, busy ones included, so on a Windows class it ends running jobs. A refused runner (403 `this runner has already claimed a task`) holds no task, so removing that one container is safe, and Swarm starts a replacement. The CI does not run these commands: check the result before you use them on a fleet.

1. On a manager, list the addresses the proxy refused in the last minutes:

   ```powershell
   docker service logs --since 5m runners_token-proxy-windows 2>&1 |
     ForEach-Object { "$_" } |
     Select-String 'claim from (\S+) refused: this runner has already claimed a task' |
     ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
   ```

2. On each Windows node, list the class's containers with their addresses and find those from step 1:

   ```powershell
   docker ps -q --filter 'name=runners_windows-default' | ForEach-Object {
     docker inspect --format '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' $_ }
   ```

3. Remove only those, by name:

   ```powershell
   docker rm -f <CONTAINER_NAME>
   ```

Or wait: a refused runner recycles at its idle timeout (1 hour). Do not shorten the timeout now: a stack file change is a service update and stops the busy containers too.

#### A claim whose outcome is unknown

A claim can reach CircleCI while its answer is lost: the connection resets, or CircleCI sends no response headers within 60 seconds. The proxy cannot tell whether a task was handed over, so it latches the runner (fail closed): the runner gets an error and no task, and every later claim of that container is refused (403) until Swarm replaces it. The cost is one idle runner. If CircleCI had allocated a task to it, the task never runs: rerun the job if it does not end. A claim that never reached CircleCI (the proxy cannot connect) is not latched.

#### When the proxy cannot save its state

The proxy saves a runner's address before it hands the task over. If the save fails (the volume `proxy-state` is full, read-only or gone), that runner gets 503 and stays refused (403), every other claim gets 503 without reaching CircleCI, and the proxy deletes `state.json` (so no restart reads a stale state) and reports unhealthy. CircleCI has already allocated that task to the runner, which never runs it: rerun the job if it does not end. Swarm restarts the proxy after 3 failed health checks, and with the state file gone the restart asks CircleCI and refuses every runner of a class with running tasks. Mend the volume (free space, or fix the mount) before or right after: the proxy refuses to start when it cannot write its state directory.

#### Where the proxy runs, and when it moves

The proxy runs on a manager by default (`node.role == manager`), with no label. With one manager it never moves. Its state, the addresses of runners that have claimed, is the volume `proxy-state` of its node.

**The worst case.** If the proxy moves, its state is lost: the new node has an empty volume. A move happens by itself when its node is down and another manager matches, or by hand when you change the placement. The proxy then asks CircleCI for each class ([Restart the proxy](#restart-the-proxy)). With running tasks in a class, or no answer, it **refuses the existing runners** of that class (403) until they recycle (a runner that runs a job is unaffected). Replace the idle ones with `docker service update --force --update-parallelism 0 runners_<SERVICE>` per Linux class, and on Windows as in [Replace refused runners on Windows](#replace-refused-runners-on-windows). This is the safe side: no runner can claim twice.

To move the proxy by hand (if no node matches, the service stays pending and no runner can claim):

```sh
docker service update --constraint-rm 'node.role == manager' --constraint-add 'node.hostname == <NEW_MANAGER>' runners_token-proxy
```

**Several managers, or a cluster with workers.** The default lets the proxy start on any manager, and runners may share a node with it. In a cluster, label the proxy's node and say so at deploy time ([Keep the deploy variables in version control](#keep-the-deploy-variables-in-version-control)):

```sh
docker node update --label-add machine-runner-swarm.proxy=true <MANAGER>
sudo env MACHINE_RUNNER_SWARM_PROXY_PLACEMENT='node.labels.machine-runner-swarm.proxy == true' docker stack deploy -c deploy/runners.yaml runners
```

The placement variable pins the proxy to a labeled node (manager or worker), and runner services never run on a labeled node, so no job shares a node with the class tokens. On a single node, with no label, the proxy and runners share the node. If the labeled node dies, the service stays pending until you label another. The labeled node runs no jobs: size the cluster so the other nodes carry the replicas.

**Planned work on the proxy's node.** A reboot keeps the state, and a move loses it. If the proxy is pinned, drain the node, patch it and set it `active`: the proxy is pending meanwhile, no runner can claim, and running jobs wait for the proxy at the end. It then starts on the same node with its state. Keep the downtime to the patch, and patch this node last ([Drain a node for patching](#drain-a-node-for-patching)). With the default placement and other managers, draining moves the proxy with an empty state (the worst case above): pin it first, or accept replacing the refused runners afterwards.

### Keep the deploy variables in version control

The variables of `docker stack deploy` are the only record of your choices that the stack files do not hold: the runner pin and its SHA-256 values, the proxy image, and the proxy placement. A deploy that leaves them out silently sets the defaults again: the shipped pin, the proxy tag `latest`, and the placement `node.role == manager` (which can move the proxy to a node without its state). A `docker service update` change is lost the same way.

Keep the variables in a file in your own repository next to your stack files, and never deploy by hand. `deploy/deploy.env` (no secrets):

```sh
MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.13
MACHINE_RUNNER_SWARM_RUNNER_SHA256=<SHA256_VALUES_COMMA_SEPARATED>
MACHINE_RUNNER_SWARM_PROXY_IMAGE=ccilabs/machine-runner-swarm-proxy@sha256:<DIGEST>
MACHINE_RUNNER_SWARM_PROXY_PLACEMENT='node.labels.machine-runner-swarm.proxy == true'
```

`deploy/deploy.sh`, the only way to deploy on Linux (add the `-c` files of your add-on stack files to the last line):

```sh
#!/bin/sh
set -eu
cd "$(dirname "$0")"
set -a
. ./deploy.env
set +a
exec docker stack deploy -c runners.yaml runners
```

Run it with `sudo ./deploy/deploy.sh`: the script reads the file itself, so `sudo` need not keep the environment. Before the first deploy and after every edit, check that the values reach the stack. `linux/setup.sh --deploy` also warns when `MACHINE_RUNNER_SWARM_PROXY_IMAGE` is not pinned by digest.

```sh
(set -a; . deploy/deploy.env; set +a; docker stack config -c deploy/runners.yaml) | grep -E 'machine-runner-swarm.proxy ==|image: ccilabs'
```

On Windows, load the file into the session and deploy from it:

```powershell
Get-Content deploy\deploy.env | ForEach-Object {
  if ($_ -match '^\s*([^#=\s]+)\s*=\s*(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2].Trim("'") }
}
docker stack deploy -c deploy\runners.yaml runners
```

### Back up the managers, and recover

The cluster state is `/var/lib/docker/swarm` on each manager. It holds the Raft log with every Swarm secret, so **the backup holds every runner token**. Keep it like a password vault and delete old copies.

The method needs a second manager: Docker stops on the manager you copy, and the others must keep the quorum. A one-manager cluster has no safe way to copy while it runs: keep your stack files and deploy variables in version control and rely on the redeploy below.

1. If the managers use autolock, save the key: `docker swarm unlock-key`.
2. Choose a manager that is not the leader (`docker node ls`, `MANAGER STATUS`) and does not run `token-proxy`. Use three managers so the quorum stands while one is stopped.
3. If it runs jobs, drain it first and wait until its tasks are gone, because stopping Docker ends every container on the node ([Drain a node for patching](#drain-a-node-for-patching)).
4. Stop Docker, copy, start Docker, and set the node `active`:

   ```sh
   sudo systemctl stop docker
   sudo tar -czf swarm-backup-$(date +%F).tar.gz -C /var/lib/docker swarm
   sudo systemctl start docker
   docker node update --availability active <NODE>
   ```

For this stack, **disaster recovery means redeploying and issuing new tokens**: the stack files hold the whole desired state, and the tokens are the only secrets.

1. Create a new Swarm on a new manager and join the nodes ([Create the swarm](multi-node.md#create-the-swarm)). Label the proxy node again.
2. Create a new token for each class, delete the old ones, and create the secrets ([Rotate a runner token](#rotate-a-runner-token)). Also create `runner-placeholder-token`, which every runner reads in place of a token, or the deploy fails with `secret not found`. On Linux: `printf %s machine-runner-swarm-placeholder | linux/setup.sh --secret runner-placeholder`. On Windows, use the placeholder step of `windows/Setup.ps1` ([The token proxy](concepts.md#the-token-proxy)).
3. Deploy the same stack files with your deploy variables, `-c` files and pins. Volumes are not recovered: the proxy starts with no state and asks CircleCI, and a persistent class starts with an empty volume.

Restore the backup only to keep the node membership, or after a loss of quorum: stop Docker on the target manager, replace `/var/lib/docker/swarm` with the backup, start Docker, and run `docker swarm init --force-new-cluster --advertise-addr <MANAGER_IP>`. This makes a one-manager cluster with the old state. Unlock it if needed, check `docker node ls` and `docker service ls`, add managers and workers again, and back up again.

### Unlock a locked swarm

With autolock (`docker swarm update --autolock=true`), a manager that restarts cannot read the Raft log until you unlock it. A locked manager answers with `Swarm is encrypted and needs to be unlocked before it can be used` and takes no part in the quorum. Without a quorum nothing creates replacement tasks, so rebooting managers without unlocking them drains capacity. Plan every manager reboot with its unlock.

```sh
docker swarm unlock
docker swarm unlock-key
docker swarm unlock-key --rotate
```

The first asks for the key on the locked manager. The second prints it, on an unlocked manager. The third makes a new key: run it after anyone who knew the old key leaves, and store the new key outside the cluster.

### Rotate the cluster certificates

Swarm renews each node certificate before it expires (90 days by default). A node offline longer must leave and join again. After a node was compromised (for example a build job took over a docker-build node), remove it and rotate the CA so its certificate stops working:

```sh
docker node rm --force <NODE>
docker swarm ca --rotate
```

Rotate the join tokens too (`docker swarm join-token --rotate worker` and `manager`). A compromised node could read the secrets of the tasks that ran on it, and a compromised manager every secret, so also rotate those classes' tokens ([If a token leaked](#if-a-token-leaked)).

### Upgrade Docker and the nodes in order

One node at a time, waiting until the cluster is healthy before the next. Managers first, then workers, and the proxy's node **last** (`docker service ps runners_token-proxy`; Windows: `runners_token-proxy-windows`). With three managers, one is down at most, so the quorum holds.

1. Drain the node ([Drain a node for patching](#drain-a-node-for-patching)). On Windows, pause it and wait instead.
2. Upgrade Docker and reboot. Unlock a manager that uses autolock.
3. Return it to service (`docker node update --availability active <NODE>`). `docker node ls` must show it `Ready`, and a manager `Reachable` or `Leader`.
4. After the proxy node, check the proxy log: the start line must say `state restored`. `no state` means the proxy moved or lost its volume, and runners are refused until they recycle ([Restart the proxy](#restart-the-proxy)).

Leave mixed Docker versions only for the length of the upgrade. The runner upgrades separately, with no stop.

### Node death

Swarm marks a node `Down` after it misses its heartbeats and starts replacement tasks on other nodes that match the constraints.

- **The jobs on the node are lost.** CircleCI reports them as failed because of a problem with your infrastructure. Self-hosted runners have no automatic retry: rerun the workflow from the failed job.
- **Services pinned to the node stay `Pending`**: the persistent class (`node.hostname`) and the docker-build classes (a labeled node). Capacity drops by the node's replicas until it returns or other nodes have room.
- **A returning node** rejoins by itself while its certificate is valid. Swarm does not move tasks back.
- **A node gone for good:** `docker node rm --force <NODE>`. For a lost manager use `docker node demote` (if reachable) or `docker node rm --force`, and add a new manager to hold the quorum. The cluster runs while a majority of managers remains. Without one, running jobs finish but no replica is replaced ([Managers and quorum](multi-node.md#managers-and-quorum)).

## Recycle a class

A forced update replaces every replica of a service one at a time, each with a runner drain. Use it to move a persistent class to a new runner version, or to reset it. On Windows, recycle a class only while it is idle ([Stop a busy Windows container](#stop-a-busy-windows-container)).

```sh
docker service update --force runners_linux-persistent
```

Recycling removes only the container filesystem. The named volume survives, so `/home/circleci` (Linux) and `C:\cache` (Windows) keep their files. To reset the volume too, scale the service to 0, run `docker volume rm runners_persistent-home` (Linux) or `docker volume rm runners_windows-persistent-cache` (Windows) on the node that holds it, and scale back up.

On Linux, a persistent class does not clean its working directory: the runner user cannot remove files the job user owns, so the stack sets `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` to `"false"`. Start every job on that class with a step that removes what an earlier job left, and recycle the class on a schedule ([Working directory cleanup](security.md#working-directory-cleanup)).

## Free disk space

A full disk is the most common way a node stops running jobs, and a full manager disk can break Swarm itself.

### Where the space goes

- **Stopped containers.** A job runs in its container's writable layer, which stays until Swarm prunes the task. A slot keeps its running task and up to `task-history-limit` finished ones (Swarm's default is 5), so R replicas can hold R times (1 plus the limit) layers. A job that leaves gigabytes behind makes this the largest item.
- **Images.** Every tag a job image has had, and every version of your own images, stays until something removes it. `docker image prune` removes only untagged images.
- **Logs:** 3 files of 20 MB (60 MB) per runner on both systems and for the Linux proxy, 10 MB for the Windows proxy. **A docker-build node's engine:** images, volumes and build cache that jobs leave. **Raft log and Swarm state**, in `/var/lib/docker/swarm` of each manager.

### Prevent it

1. **Set the task history limit.** `docker swarm update --task-history-limit 2` keeps at most 2 finished tasks per slot. The single-node setup of `linux/setup.sh` sets it. A swarm you create yourself does not ([Create the swarm](multi-node.md#create-the-swarm)).
2. **Give Docker its own filesystem, and keep managers free of jobs.** Put `/var/lib/docker` on a separate volume, sized for the worst case above: replicas, times the largest workspace, times (1 plus the history limit), plus images. A manager with the proxy label runs no jobs.
3. **Prune images on every node, on a schedule.** Swarm has no command that runs on every node, and a global service with the Docker socket would be root everywhere, so use each node's scheduler (configuration management, or a systemd timer on Linux). Install the two units of [`examples/systemd`](../examples/systemd) in `/etc/systemd/system`. The service removes images no container uses that are older than a week, and the timer runs it every Sunday:

   ```sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now docker-image-prune.timer
   ```

   `until` filters by image creation time, not last use, and `--all` skips every image a container (stopped ones too) still uses. A removed image that is needed again is pulled again, so a mirror ([What needs internet](security.md#what-needs-internet)) must be up. On a docker-build node, add `docker builder prune --force --filter until=168h`. On Windows, run the same `docker image prune` from a scheduled task. The Server Core and distributor images are in use while the stack runs, so a prune keeps them.
4. **Alert on every node's disk** (`df -h /var/lib/docker`): above 80 percent on a worker, 70 percent on a manager ([Monitor the cluster](#monitor-the-cluster)).

> [!WARNING]
> Do not run `docker volume prune` or `docker system prune --volumes` on a node of this stack. The named volumes hold `runner-bin`, `proxy-state` and the persistent classes. A volume no container uses at that moment (for example a persistent class scaled to 0) is deleted with its data. Leave `docker container prune` to the task history too, except in an emergency.

### When the disk is full

A node with a full disk fails tasks, with `no space left on device` in the runner log or in `docker stack ps --no-trunc`, and Docker commands on it fail. A full manager disk comes first, because Swarm cannot write its log.

1. Find the node: `df -h /var/lib/docker` on each, and the `ERROR` column of `docker stack ps runners --no-trunc`.
2. Stop it from claiming jobs. On Linux, drain it. On Windows, pause it ([A Windows node](#a-windows-node)):

   ```sh
   docker node update --availability drain <NODE>
   ```

3. See what takes the space:

   ```sh
   docker system df
   docker ps -a --size --format '{{.Size}}\t{{.Names}}' | sort -hr | head
   ```

4. Free it, cheapest first. `docker container prune` removes the stopped containers of finished tasks (Swarm does not need them) and no running one. Do not prune volumes:

   ```sh
   docker image prune --all --force
   docker builder prune --force
   docker container prune --force
   ```

5. If the disk is a manager, check that `docker node ls` and `docker service ls` answer and the proxy runs (`docker service ps runners_token-proxy`).
6. Return the node to service (`docker node update --availability active <NODE>`), set the task history limit if it is not set, and add the scheduled prune.

## Compatibility with CircleCI

The token proxy sits between the runner and CircleCI, so it depends on the runner API more closely than a plain runner install.

The proxy changes one call, `POST /api/v3/runner/claim`: a 2xx other than 204 means that CircleCI handed over a task, and the proxy latches that runner. At a start with no state it also reads `GET /api/v3/runner/scale` (`data.attributes.running_task_count` and `unclaimed_task_count`, whole numbers of 0 or more). Every other call is forwarded unchanged. Neither call is in CircleCI's public [runner API reference](https://circleci.com/docs/reference/runner-api/), and CircleCI does not promise that they stay as they are.

### What is tested

- **The runner version.** The exact pin of the stack files, `3.1.13` in this release. The CI runs the real runner binary against a fake API (`task.sh`, `proxy.sh` and others), and the end-to-end jobs run real jobs on CircleCI cloud through the proxy, on Linux amd64 and arm64 and Windows Server 2022 and 2025. The distributor test also installs the previous version (`3.1.11`) for the rollback, and the version CircleCI names as `current` in the live manifest, and checks its record.
- **Not tested.** A real job on a floating version (`3.1`, `3`, `current`) or any runner version other than the pin. CircleCI server. A runner API on a host other than `runner.circleci.com`.
- **The task agent** is not pinned by this project: the runner downloads the version CircleCI serves, at each container start.

### What fails when it changes

| Change | What you see | What to do |
|---|---|---|
| The claim moves to another path | The runner logs `401`, and the proxy log has no `claim from` lines for it: the call is forwarded with the placeholder, and CircleCI rejects it | Pin the previous runner version ([Roll back](#roll-back)) |
| A claim with no task gets a 2xx other than 204 | Each runner is latched after its first poll: `upstream status 200`, then `this runner has already claimed a task`. No runner claims | Pin the previous version, and replace the runners ([Restart the proxy](#restart-the-proxy)) |
| `scale` answers in another shape | A proxy that starts with no state logs `CircleCI does not say how many tasks run` and refuses the runners present until they recycle. A proxy with state is unaffected | Open an issue with the log line. Replace the runners, or wait for the idle timeout |
| The runner stops passing its API URL to the task agent, or the agent calls another host | The job starts and its steps fail with `401` against CircleCI | Pin the previous runner version |

Before you move to an untested runner version (any floating value included), pin it on one class, run the [canary](#monitor-the-cluster) and a real job, read the proxy log, and keep the previous version installed so the rollback needs no network. The runner API hosts nodes must reach are in [Egress hosts](security.md#egress-hosts), with their source, CircleCI's [runner FAQ](https://circleci.com/docs/guides/execution-runner/runner-faqs/).

## CircleCI server, proxies, and hosts without internet

Two setups are **not tested yet**: CircleCI server, and an installation with no route to the internet. Nothing here promises either works.

- **CircleCI server.** The proxy takes the runner API address in its `-upstream` argument, in the `command` of `token-proxy` in the stack file. The CI runs against CircleCI cloud and a fake API, never a server installation. Open questions: whether the claim and scale calls match your server version, which runner versions your server accepts (the default pin is tested against cloud only), and whether the proxy and runner trust your server's certificate ([the table below](#proxies-and-certificate-authorities-component-by-component)). Run the [canary](#monitor-the-cluster) first, and do not assume anything on this page was checked for your version.
- **An air-gapped installation.** It does not work with this release: every runner container downloads its task agent from `circleci-binary-releases.s3.amazonaws.com` at start, and no setting redirects that. Nodes must reach that host, directly or through a proxy the runner honors.

### What needs the internet

See [What needs internet](security.md#what-needs-internet). The mirror steps are in [Run the downloads from a mirror](#run-the-downloads-from-a-mirror), and the Windows Git downloads come from `MACHINE_RUNNER_SWARM_TOOLS_BASE_URL` ([Upgrade the runner on Windows](#upgrade-the-runner-on-windows)).

To mirror the images, copy each with its digest to a registry the nodes reach (this keeps every platform), and change the `image:` line of every stack file and `MACHINE_RUNNER_SWARM_PROXY_IMAGE`. Deploy with `--resolve-image never` if the manager cannot reach the registry to resolve tags ([Registry needs](multi-node.md#registry-needs)):

```sh
docker buildx imagetools create --tag <REGISTRY>/<NAME>:<TAG> <SOURCE_IMAGE>
```

### Proxies and certificate authorities, component by component

Each component has its own network stack, so a variable that works for one does nothing for another. Only the Linux distributor row was tested, with BusyBox 1.37.0 of `alpine:3` against a stub proxy, not a real corporate proxy. The other rows follow from how each program is written, and the CI does not test them.

| Component | Proxy variables | Your own certificate authority |
|---|---|---|
| The Docker engine of each node (every image pull) | The engine's own settings: `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` in a systemd drop-in of `docker.service`, or `proxies` in `daemon.json`. The stack files set nothing | The node's trust store. For a private registry, `/etc/docker/certs.d/<REGISTRY>/ca.crt` |
| `runner-distributor` on Linux | Its `wget` is BusyBox: it reads only lowercase `http_proxy`, sends an `https://` URL as `GET https://...` (not `CONNECT`), and ignores `no_proxy`. `HTTPS_PROXY` does nothing. Use a mirror that the node reaches without a proxy | The Alpine image's CA bundle only. Use an `http://` mirror with the SHA-256 list, or an image of your own |
| `runner-distributor-windows` | `HTTPS_PROXY` only, for every download. `NO_PROXY` is not read | The container's Windows certificate store, which lacks your authority. Use an `http://` mirror with the SHA-256 list, or an image of your own |
| `token-proxy` | A Go program: `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` apply to its calls to CircleCI, set under the service's `environment`. Swarm DNS lookups ignore them | Linux: `SSL_CERT_FILE` **replaces** the image's public roots, so mount one bundle with the public roots and yours (a Swarm config) and point `SSL_CERT_FILE` at it. Windows: the container's Windows certificate store |
| The runner and task agent | Go programs: the same variables under the class's `environment`, inherited by jobs. Add `token-proxy` (Windows: `token-proxy-windows`) to `NO_PROXY` so calls to the proxy stay on the overlay network | The class image: add the authority to its system store ([Images](images.md#private-certificate-authorities)). `SSL_CERT_FILE` replaces a Go program's roots on Unix. On Windows, Go reads the Windows store, so the authority must be in the image |
| The steps of a job | Whatever the job's tools read. Class variables are inherited | The image's system store |

### What to copy into the site

For a site that reaches CircleCI through a proxy, or mirrors what it can, copy in the release bundle and `SHA256SUMS`, the images by digest (the proxy image with its signature via `cosign copy`), the runner tarballs per node architecture (the pinned version and the one before it, plus `manifest.json` for a floating version), on Windows the two Git downloads, and for a MicroVM class the Kata tarball.

### Verify a release without internet

`cosign verify-blob` and `cosign verify` fetch the Sigstore trust root over the network by default, and this project has not tested an offline verification. Verify on a host with access ([Verify a release](install-linux.md#verify-a-release)), copy the verified files and the images by digest in, and check them on the site with `sha256sum -c SHA256SUMS` and the digests the verified release names. Recent `cosign` versions can also verify against a trusted root that you carry in (`--trusted-root`): test it with a known release first.

## Uninstall

1. Remove the stack. Swarm sends SIGTERM to the tasks, so running jobs get the grace period to finish:

   ```sh
   docker stack rm runners
   ```

2. Remove the secrets (`<SERVICE>-token` of every class you deployed) and the persistent-class volumes:

   ```sh
   docker secret rm linux-default-token runner-placeholder-token
   docker volume rm runners_persistent-home runners_proxy-state
   ```

   The Windows persistent class volume is `runners_windows-persistent-cache`, and the Windows proxy keeps its state in `runners_proxy-state` too.

   The volume `runners_runner-bin` holds the runner (and Git on Windows) and stays on every node after `docker stack rm`. Remove it on every node, on Windows after the last container of the stack is gone:

   ```sh
   docker volume rm runners_runner-bin
   ```

3. Remove the nodes from the Swarm: `docker swarm leave` on each worker, then `docker swarm leave --force` on the last manager. No node has files outside Docker to remove.
