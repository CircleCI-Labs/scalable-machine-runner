---
page-title: Quickstart on Windows Server
page-audience: admin
page-description: Run a first job on a Windows Server Docker Swarm node with CircleCI machine runner 3 in six steps, using the stock Server Core image.
---

# Quickstart on Windows Server

This page takes you from nothing to a first job on one Windows Server node with the shipped stack file and the setup helper. It explains little. [Install on Windows Server with Docker Swarm](install-windows.md) has every step by hand with the reasons, and [Concepts](concepts.md) explains the model. Nothing is built and nothing is installed on the host: the service uses the stock Server Core image, and the distributor service of the stack installs the runner and Git.

## Before you start

- A Windows Server 2022 or 2025 host that is not a domain controller, with Docker Engine in Windows-container mode, a clock on NTP, and outbound HTTPS. Refer to [Prerequisites](install-windows.md#prerequisites) for the details, and to [Sizing](#sizing-and-pending-replicas) for the CPU and memory.
- Your organization's runner namespace, and an organization admin who agreed to the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/).
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, signed in. It can run on your workstation.
- An elevated Windows PowerShell 5.1 session on the host for the steps that start with `docker` or `.\windows`.

Replace `<namespace>` with your runner namespace, and `<org>` with your organization slug such as `gh/my-org`, or its UUID.

## Steps

1. Create the resource class and its token. The command prints the token once, so keep it for step 5.

   ```powershell
   circleci runner resource-class create <namespace>/windows-default --org <org> --generate-token
   ```

2. On the host, get the files at a release tag, or extract the `machine-runner-swarm-<version>.zip` bundle of a [release](https://github.com/CircleCI-Labs/scalable-machine-runner/releases). The paths below are relative to the checkout.

   ```powershell
   git clone --branch <release-tag> https://github.com/CircleCI-Labs/scalable-machine-runner.git
   cd scalable-machine-runner
   ```

3. Pull the base image before you create the Swarm, because the network of the host drops for a few seconds after `docker swarm init`. A Server 2025 host runs this `ltsc2022` image too.

   ```powershell
   docker pull mcr.microsoft.com/windows/servercore:ltsc2022
   ```

4. Copy the stack directory. For a first run, change nothing in it. You review it later, and from here on you deploy your copy and never the shipped files. The directory holds the stack files and the script that `runners.yaml` ships as a Swarm config, which the file names next to itself.

   ```powershell
   Copy-Item -Recurse windows\stack deploy
   ```

5. Run the helper. It creates the Swarm, labels the node with the image tags it can run, asks for the token with hidden input, creates the secret `windows-default-token`, and deploys your copy. Use the IPv4 address of the host. This is the whole install: the service `runner-distributor-windows` downloads and verifies CircleCI's current runner and the pinned portable Git on its own.

   ```powershell
   .\windows\Setup.ps1 -InitSwarm -AdvertiseAddr <host IPv4 address> -Class windows-default -StackFile .\deploy\runners.yaml -Deploy
   ```

6. Check that the runners are up and connected, and then run a job. `docker stack deploy` does not wait, so the replicas need a few minutes to start: the first download of the distributor takes a while, the first runner tasks fail until it is done and are started again every 10 seconds, and the first task also pulls the image if you skipped step 3. `docker service logs runners_runner-distributor-windows` shows the install.

   ```powershell
   docker stack services runners
   circleci runner instance list --org <org> --resource-class <namespace>/windows-default
   ```

   The runners are healthy when `REPLICAS` shows `2/2` (or fewer for [Pending replicas](#sizing-and-pending-replicas)) and the CLI lists an instance with the status `online`. The same list is in the web app under **Runners**. Then save the following as `.circleci/config.yml` in a project of your organization, replace `<namespace>`, commit, and push. Run the workflow twice.

   ```yaml
   version: 2.1

   jobs:
     hello:
       machine: true
       resource_class: <namespace>/windows-default
       steps:
         - run: echo "computer $COMPUTERNAME, instance $MACHINE_RUNNER_SWARM_INSTANCE_ID"

   workflows:
     hello:
       jobs:
         - hello
   ```

   The two runs print different values, because Swarm starts a new container for each job. The file [`examples/windows-job.yml`](../examples/windows-job.yml) has more steps.

## Two things that differ from Linux

- A job on Windows runs as an administrator and can read the runner token. Treat each class as a trust boundary. Refer to [Token model on each OS](security.md#token-model-on-each-os).
- A stop of a busy container from outside, such as an update, a scale-down, or a node drain, kills its job after about 5 seconds. A job that finishes ends its container cleanly. Change a Windows class while it is idle. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

## Sizing and Pending replicas

The shipped file runs two replicas of `windows-default`, and each reserves 2 CPUs and 4 GB of memory, so the service needs 4 CPUs and 8 GB. The Windows engine rejects a CPU limit above the CPU count of the host. A replica needs its whole reservation free on one node.

A replica that does not fit, or that no node is allowed to run, stays `Pending`. That is not an error: Swarm waits, and the other replica works. `docker service ps --no-trunc runners_windows-default` shows the reason, such as `insufficient resources` or `scheduling constraints not satisfied`. For a small host, lower `deploy.replicas` in your copy and deploy it again. Refer to [A task stays pending](troubleshooting.md#a-task-stays-pending) for the other causes, and to [Size the limits](resource-classes.md#size-the-limits) for planning.

## What you did not do

The helper starts Swarm. It does not install Docker or the runner, create classes or tokens, edit the stack file, label nodes for the optional classes, or build images. [Optional: use the setup helper](install-windows.md#optional-use-the-setup-helper) lists each option.

## Next

- [Install on Windows Server with Docker Swarm](install-windows.md): the same steps by hand, with the release verification.
- [Images](images.md): add your own tools on top of Server Core.
- [Security](security.md): the token model and BitLocker.
- [Operations](operations.md): upgrade, rotate tokens, and run the cluster.
