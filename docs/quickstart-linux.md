---
page-title: Quickstart on Linux
page-audience: admin
page-description: Run a first job with CircleCI machine runner 3 on one Docker Swarm node in five steps. A trial: the node cannot join a cluster later.
---

# Quickstart on Linux

Go from nothing to a first job on one Linux node in five steps. The page sets up one class, `linux-default`, and installs nothing on the node by hand: a service of the stack installs the runner.

> [!NOTE]
> CircleCI Labs project, `0.x`, not supported by CircleCI support. This trial runs on one node, so it has no high availability. [What is tested](../README.md#what-is-tested) shows what CI checks.

## Before you start

- A node with Ubuntu LTS, Docker Engine 24 or later, `curl`, a clock synced with NTP, and outbound HTTPS ([what needs internet](security.md#what-needs-internet)). [Prepare each node](install-linux.md#2-prepare-each-node) shows how to install Docker.
- Size: 6 CPUs and 10 GB for the two sample replicas. A smaller node can run one replica (step 4).
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, on your workstation.
- An organization admin who accepted the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/).
- A repository that is set up as a CircleCI project in your organization, and runner concurrency in your plan (2 for the sample replicas).
- A namespace. An organization has one, and orbs use it too. It is the part before the `/` in a resource class (`acme` in `acme/my-class`). If you have none, run `circleci namespace create <NAMESPACE> --org <ORG>`.

Replace `<NAMESPACE>` with your namespace, and `<ORG>` with your organization slug such as `gh/my-org`, or its UUID. Run step 1 on your workstation, where a browser opens for `circleci auth login`. Run steps 2 to 4 on the node. They use `sudo`, because the `docker` group is equivalent to root.

## Steps

1. Create a resource class and a token. Copy the token from the output: the command prints it once, and step 3 asks for it on the node.

   ```bash
   circleci auth login
   circleci runner resource-class create <NAMESPACE>/linux-default --org <ORG> --generate-token
   ```

2. On the node, download the latest release. To verify the release signature first, see [Install on Linux: Verify a release](install-linux.md#verify-a-release).

   ```bash
   version=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/CircleCI-Labs/machine-runner-swarm/releases/latest)
   version=${version##*/v}
   curl -fsSL "https://github.com/CircleCI-Labs/machine-runner-swarm/releases/download/v${version}/machine-runner-swarm-${version}.tar.gz" | tar -xz
   cd "machine-runner-swarm-${version}"
   ```

   Swarm takes `10.0.0.0/8` for its overlay networks. If your network uses that range, run `docker swarm init --advertise-addr 127.0.0.1 --listen-addr 127.0.0.1:2377 --default-addr-pool <POOL_CIDR> --default-addr-pool-mask-length 24` yourself, and run the next command without `--swarm-init`. Otherwise, the next command starts a one-node Swarm that listens on the loopback address:

   ```bash
   sudo linux/setup.sh --check --swarm-init
   ```

   No other node can join this Swarm: a cluster later needs a new `swarm init` and new secrets. The runners share the node with the token proxy, so a job that escapes its container could read the class tokens. Use it for a trial. For a cluster, follow [Multi-node clusters](multi-node.md) instead.

3. Create the secrets. The first command asks for the token from step 1 (hidden input). The token goes to the token proxy only. The second creates the placeholder that the runners read instead of a token.

   ```bash
   sudo linux/setup.sh --secret linux-default
   printf %s machine-runner-swarm-placeholder | sudo linux/setup.sh --secret runner-placeholder
   ```

4. Deploy the stack, and check it. `docker stack deploy` does not wait, so the replicas need a minute to start.

   ```bash
   sudo linux/setup.sh --deploy
   ```

   ```bash
   sudo docker stack services runners
   circleci runner instance list --org <ORG> --resource-class <NAMESPACE>/linux-default
   ```

   The stack is up when `runners_linux-default` shows `2/2`, `runners_token-proxy` shows `1/1`, and the CLI lists an instance with the status `online`. The stack reserves 4.1 CPUs and a little over 8 GB, plus what the system needs. If a replica stays `Pending`, the node is too small. Run one replica:

   ```bash
   sudo docker service scale runners_linux-default=1
   ```

   The next `docker stack deploy` resets it to 2. To keep one, set `deploy.replicas` in your copy of the stack file ([Size the limits](resource-classes.md#size-the-limits), [A task stays pending](troubleshooting.md#a-task-stays-pending)).

5. Run a job. Save this as `.circleci/config.yml` in a project of your organization, replace `<NAMESPACE>` with your namespace, then commit and push. The same file is [`examples/linux-hello.yml`](../examples/linux-hello.yml).

   ```yaml
   version: 2.1

   jobs:
     hello:
       machine: true
       resource_class: <NAMESPACE>/linux-default
       steps:
         - run:
             name: Show where this job runs
             command: |
               echo "runner: $CIRCLECI_RUNNER_NAME"
               if [ -e /tmp/hello-marker ]; then echo "the container was reused"; exit 1; fi
               touch /tmp/hello-marker
               echo "clean container: no marker from an earlier job"

   workflows:
     hello:
       jobs:
         - hello
   ```

   Run the workflow twice. Both runs pass, because Swarm starts a new container for each job. The job shows `Queued` while no runner is online: check step 4 first.

## Next

- [Install on Linux](install-linux.md): every step by hand, RHEL, release verification, and upgrades. Before production, copy `linux/stack` to a directory of your own and deploy that copy ([Review the stack file](install-linux.md#5-review-the-stack-file)).
- [Concepts](concepts.md): services as resource classes, the token proxy, and the job lifecycle.
- [Resource classes](resource-classes.md): add classes, and change sizes and replicas.
- [Security](security.md): choose the default or the hardened class before you give a class to a team.
- [Operations](operations.md): pin or roll back the runner, rotate tokens, and run the cluster.
- [Uninstall](operations.md#uninstall): remove the trial, and leave the swarm.
- [Troubleshooting](troubleshooting.md): symptoms, causes, and fixes.
