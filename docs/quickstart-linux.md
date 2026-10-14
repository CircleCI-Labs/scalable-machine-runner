---
page-title: Quickstart on Linux
page-audience: admin
page-description: Run a first job on a Docker Swarm node with CircleCI machine runner 3 in about a dozen commands, for a one-node trial or the start of a cluster.
---

# Quickstart on Linux

This page takes you from nothing to a first job on Linux with the shipped stack file and the setup helper. Nothing is installed on a node by hand: the stack has a service that installs the runner on every node. The page explains little. [Install on Linux with Docker Swarm](install-linux.md) has every step by hand with the reasons, and [Concepts](concepts.md) explains the model.

## Before you start

- A node with Ubuntu LTS or RHEL 8 or later, amd64 or arm64, Docker Engine 24 or later, a clock on NTP, and outbound HTTPS. Refer to [Prerequisites](install-linux.md#prerequisites) for the details, and to [Sizing](#sizing-and-pending-replicas) for the CPU and memory.
- Your organization's runner namespace, and an organization admin who agreed to the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/).
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, signed in, on your workstation or on the node.
- A bash shell. Run the commands on the node with `sudo`, or as a user in the `docker` group. The `docker` group is equivalent to root, so limit it.

Replace `<namespace>` with your runner namespace, and `<org>` with your organization slug such as `gh/my-org`, or its UUID.

## Steps

1. Create a resource class and a token for each service of `linux/stack/runners.yaml`. Each command prints its token once, so keep the three tokens for step 4. Without `--org`, the CLI takes the organization of the git remote of the current directory.

   ```bash
   for class in linux-default linux-java linux-hardened; do
     circleci runner resource-class create <namespace>/$class --org <org> --generate-token
   done
   ```

2. Get the files, at a release tag. The paths below are relative to the checkout.

   ```bash
   git clone --branch <release-tag> https://github.com/CircleCI-Labs/scalable-machine-runner.git
   cd scalable-machine-runner
   ```

3. Check the node and create the Swarm. Choose one of two forks. A Swarm that listens on the loopback address cannot accept other nodes, so a trial cannot grow into a cluster without a new `swarm init` and new secrets. Decide now.

   - **Trial, one node.** The Swarm listens on the loopback address, so nothing is exposed and no other node can join.

     ```bash
     sudo linux/setup.sh --check --swarm-init
     ```

   - **Cluster.** Check every node, create the Swarm on the first one with an address that the others can reach, and join the rest. Open the [inter-node ports](multi-node.md#inter-node-ports) first. A first cluster of one manager and two workers is enough. A node needs nothing else: the stack installs the runner on each node that joins.

     ```bash
     sudo linux/setup.sh --check                             # on every node
     sudo docker swarm init --advertise-addr <manager IP address>   # on the manager
     sudo docker swarm update --task-history-limit 2         # on the manager
     sudo docker swarm join-token worker                     # prints the join command: run it on each worker
     sudo docker node ls                                     # on the manager: every node is Ready
     ```

     Run steps 4 to 6 on the manager. Refer to [Multi-Node Clusters](multi-node.md) for labels, zones, and quorum.

4. Create one Swarm secret for each token. The helper asks for each token with hidden input and never prints it.

   ```bash
   sudo linux/setup.sh --secret linux-default --secret linux-java --secret linux-hardened
   ```

5. Copy the stack directory, and deploy your copy. For a first run, change nothing in it. You review it later, and from here on you deploy your copy and never the shipped files. The directory holds the stack files and the two scripts that they ship as Swarm configs, which the stack files name next to themselves.

   ```bash
   cp -r linux/stack deploy
   sudo linux/setup.sh --deploy --stack-file deploy/runners.yaml
   ```

   This is the whole install. The service `runner-distributor` starts on every node, downloads the runner of CircleCI, checks its SHA-256, and makes it available to the runner services. A runner container that starts first waits up to 2 minutes for it.

6. Check that the runners are up and connected. `docker stack deploy` does not wait, so the replicas need a minute to start.

   ```bash
   sudo docker stack services runners
   sudo docker service logs --tail 20 runners_runner-distributor
   sudo docker service logs --tail 20 runners_linux-default
   circleci runner instance list --org <org> --resource-class <namespace>/linux-default
   ```

   The runners are healthy when `REPLICAS` shows `2/2`, `1/1`, and `1/1` (or fewer for [Pending replicas](#sizing-and-pending-replicas)), the distributor shows one task for each node and logs a line such as `[ ok ] current -> versions/3.1.13`, the log of the runners has no `401` or `error` lines, and the CLI lists an instance with the status `online`. The same list is in the web app under **Runners**.

7. Run a job. Save the following as `.circleci/config.yml` in a project of your organization, replace `my-namespace`, commit, and push. The same file is [`examples/linux-hello.yml`](../examples/linux-hello.yml).

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
               echo "user:   $(id -un)"
               if [ -e /tmp/hello-marker ]; then echo "the container was reused"; exit 1; fi
               touch /tmp/hello-marker
               echo "clean container: no marker from an earlier job"

   workflows:
     hello:
       jobs:
         - hello
   ```

   Run the workflow twice. Both runs pass, because Swarm starts a new container for each job.

## Sizing and Pending replicas

The shipped file reserves 10 CPUs and 20 GB of memory: two replicas of `linux-default` (2 CPUs, 4 GB each), one of `linux-java` (4 CPUs, 8 GB), and one of `linux-hardened` (2 CPUs, 4 GB). A replica needs its whole reservation free on one node. Leave about 1 CPU and 2 GB for the operating system and Docker.

A replica that does not fit stays `Pending`. That is not an error: Swarm waits for room, the other replicas work, and `docker service ps --no-trunc runners_<service>` shows `insufficient resources on 1 node`. To fit a small node, lower `deploy.replicas` in your copy and deploy it again with the same command. The smallest useful test is `replicas: 1` for `linux-default` and `0` for the other two, which needs 2 CPUs and 4 GB. Refer to [A task stays pending](troubleshooting.md#a-task-stays-pending) for the other causes, and to [Size the limits](resource-classes.md#size-the-limits) for planning.

## What you did not do

The helper checks the node, starts Swarm, creates the secrets, and deploys the stack. It does not install Docker, create classes or tokens, edit the stack file, label or join nodes, or build images. It does not install the runner either: the `runner-distributor` service of the stack does that on every node. [Optional: use the setup helper](install-linux.md#optional-use-the-setup-helper) lists each step.

## Next

- [Install on Linux with Docker Swarm](install-linux.md): the same steps by hand, RHEL, and the release verification.
- [Resource Classes](resource-classes.md): change the classes, sizes, and replica counts.
- [Security](security.md): choose between the default and the hardened class before you give a class to a team.
- [Operations](operations.md): pin or roll back the runner version, rotate tokens, and run the cluster.
