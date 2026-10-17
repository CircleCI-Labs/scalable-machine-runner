---
page-title: Quickstart on Linux
page-audience: admin
page-description: Run a first job on a Docker Swarm node with CircleCI machine runner 3 in five steps, for a one-node trial or the start of a cluster.
---

# Quickstart on Linux

Go from nothing to a first job on one Linux node in five steps. The page sets up one class, `linux-default`, and installs nothing on the node by hand: a service of the stack installs the runner.

> [!NOTE]
> This is a CircleCI Labs project, not supported by CircleCI support. It is a `0.x` release: read the release notes before you upgrade. [What is tested](../README.md#what-is-tested) says how it is checked. One token proxy runs on a manager, so while it is down no new job starts: use three managers in production.

## Before you start

- A node with Ubuntu LTS, Docker Engine 24 or later, `curl`, a clock on NTP, and outbound HTTPS ([what needs internet](security.md#what-needs-internet)). [Prepare each node](install-linux.md#2-prepare-each-node) shows how to install Docker.
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, on your workstation or on the node.
- An organization admin who accepted the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/).
- A runner namespace. If your organization has none, create one with `circleci namespace create <NAMESPACE> --org <ORG>`.

Replace `<NAMESPACE>` with your runner namespace, and `<ORG>` with your organization slug such as `gh/my-org`, or its UUID. Run the commands on the node as a user in the `docker` group, or add `sudo`.

## Steps

1. Create a resource class and a token. The command prints the token once: keep it for step 3.

   ```bash
   circleci auth login
   circleci runner resource-class create <NAMESPACE>/linux-default --org <ORG> --generate-token
   ```

2. On the node, download the latest release, and start a one-node Swarm that listens on the loopback address. To verify the release signature first, see [Install on Linux > Verify a release](install-linux.md#verify-a-release).

   ```bash
   version=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/CircleCI-Labs/machine-runner-swarm/releases/latest)
   version=${version##*/v}
   curl -fsSL "https://github.com/CircleCI-Labs/machine-runner-swarm/releases/download/v${version}/machine-runner-swarm-${version}.tar.gz" | tar -xz
   cd "machine-runner-swarm-${version}"
   ```

   ```bash
   sudo linux/setup.sh --check --swarm-init
   ```

   No other node can join this Swarm, and the runners share the node with the token proxy, so use it for a trial. For a cluster, follow [Multi-Node Clusters](multi-node.md) instead.

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

   The stack is up when `runners_linux-default` shows `2/2`, `runners_token-proxy` shows `1/1`, and the CLI lists an instance with the status `online`. If a replica stays `Pending`, the node is too small: it needs 4 CPUs and 8 GB, so set a lower `deploy.replicas` ([Size the limits](resource-classes.md#size-the-limits), [A task stays pending](troubleshooting.md#a-task-stays-pending)).

5. Run a job. Save this as `.circleci/config.yml` in a project of your organization, replace `my-namespace` with your namespace, then commit and push. The same file is [`examples/linux-hello.yml`](../examples/linux-hello.yml).

   ```yaml
   version: 2.1

   jobs:
     hello:
       machine: true
       resource_class: my-namespace/linux-default
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

   Run the workflow twice. Both runs pass, because Swarm starts a new container for each job.

## Next

- [Install on Linux](install-linux.md): every step by hand, RHEL, release verification, and upgrades. Before production, copy `linux/stack` to a directory of your own and deploy that copy ([Review the stack file](install-linux.md#5-review-the-stack-file)).
- [Concepts](concepts.md): services as resource classes, the token proxy, and the job lifecycle.
- [Resource Classes](resource-classes.md): add classes, and change sizes and replicas.
- [Security](security.md): choose the default or the hardened class before you give a class to a team.
- [Operations](operations.md): pin or roll back the runner, rotate tokens, and run the cluster.
- [Troubleshooting](troubleshooting.md): symptoms, causes, and fixes.
