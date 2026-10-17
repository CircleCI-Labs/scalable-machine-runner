---
page-title: Quickstart on Windows Server
page-audience: admin
page-description: Run a first job on a Windows Server Docker Swarm node with CircleCI machine runner 3 in five steps, using the stock Server Core image.
---

# Quickstart on Windows Server

Go from nothing to a first job on one Windows Server node in five steps. Nothing is built or installed on the host: the stack uses the stock Server Core image, and a service of the stack installs the runner and Git.

> [!NOTE]
> This is a CircleCI Labs project, not supported by CircleCI support. It is a `0.x` release: read the release notes before you upgrade. [What is tested](../README.md#what-is-tested) says how it is checked. One token proxy runs on a manager, so while it is down no new job starts. This page sets up one host that runs the proxy and the jobs together: use it for a trial.

## Before you start

- A Windows Server 2022 or 2025 host (amd64, not a domain controller) with a clock on NTP and outbound HTTPS ([what needs internet](security.md#what-needs-internet)).
- Docker Engine and CLI 28.0 or later in Windows-container mode, and the Windows Containers feature ([Prerequisites](install-windows.md#prerequisites) shows how to install both). The first pull of the Server Core image is about 2.2 GB.
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, on your workstation or on the host.
- An organization admin who accepted the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/).
- A runner namespace. If your organization has none, create one with `circleci namespace create <NAMESPACE> --org <ORG>`.
- An elevated Windows PowerShell 5.1 session on the host.

Replace `<NAMESPACE>` with your runner namespace, and `<ORG>` with your organization slug such as `gh/my-org`, or its UUID.

## Steps

1. Create a resource class and a token. The command prints the token once: keep it for step 3.

   ```powershell
   circleci auth login
   circleci runner resource-class create <NAMESPACE>/windows-default --org <ORG> --generate-token
   ```

2. On the host, download the latest release. To verify the release signature first, see [Install on Windows Server > Verify a release](install-windows.md#verify-a-release).

   ```powershell
   $uri = (Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/CircleCI-Labs/machine-runner-swarm/releases/latest').BaseResponse.ResponseUri.AbsoluteUri
   $version = $uri -replace '^.*/v', ''
   $zip = "machine-runner-swarm-$version.zip"
   Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/CircleCI-Labs/machine-runner-swarm/releases/download/v$version/$zip" -OutFile $zip
   Expand-Archive -LiteralPath $zip -DestinationPath .
   cd "machine-runner-swarm-$version"
   ```

3. Pull the base image, then run the helper. Pull first: the network of the host drops for a few seconds after `docker swarm init`. The helper creates the Swarm, labels the node, asks for the token from step 1 (hidden input), creates the secrets, and deploys the stack. Use the IPv4 address of the host.

   ```powershell
   docker pull mcr.microsoft.com/windows/servercore:ltsc2022
   ```

   ```powershell
   .\windows\Setup.ps1 -InitSwarm -AdvertiseAddr <HOST_IPV4_ADDRESS> -Class windows-default -Deploy
   ```

4. Check the stack. `docker stack deploy` does not wait, and the first start downloads the runner, so the replicas need a few minutes. Early runner tasks fail until the download ends, and Swarm restarts them.

   ```powershell
   docker stack services runners
   circleci runner instance list --org <ORG> --resource-class <NAMESPACE>/windows-default
   ```

   The stack is up when `runners_windows-default` shows `2/2` and the CLI lists an instance with the status `online`. If a replica stays `Pending`, the host is too small: each replica reserves 2 CPUs and 4 GB, so set a lower `deploy.replicas` ([Size the limits](resource-classes.md#size-the-limits), [A task stays pending](troubleshooting.md#a-task-stays-pending)). `docker service logs runners_runner-distributor-windows` shows the install.

5. Run a job. Save this as `.circleci/config.yml` in a project of your organization, replace `my-namespace` with your namespace, then commit and push. The file [`examples/windows-job.yml`](../examples/windows-job.yml) has more steps.

   ```yaml
   version: 2.1

   jobs:
     hello:
       machine: true
       resource_class: my-namespace/windows-default
       steps:
         - run: echo "computer $COMPUTERNAME, instance $MACHINE_RUNNER_SWARM_INSTANCE_ID"

   workflows:
     hello:
       jobs:
         - hello
   ```

   Run the workflow twice. The two runs print different values, because Swarm starts a new container for each job.

## What differs from Linux

- A job runs as an administrator. The runner container holds a placeholder, and the class token stays in the token proxy, except in the `windows-persistent` class ([Token model on each OS](security.md#token-model-on-each-os)).
- Stopping a busy container, for an update, a scale-down or a drain, kills its job after about 5 seconds. Change a class while it is idle ([Stop a busy Windows container](operations.md#stop-a-busy-windows-container)).

## Next

- [Install on Windows Server](install-windows.md): every step by hand, release verification, and upgrades. Before production, copy `windows\stack` to a directory of your own and deploy that copy ([Review the stack files](install-windows.md#5-review-the-stack-files)).
- [Concepts](concepts.md): services as resource classes, the token proxy, and the job lifecycle.
- [Images](images.md): add your own tools on top of Server Core.
- [Security](security.md): the token model and BitLocker.
- [Operations](operations.md): upgrade, rotate tokens, and run the cluster.
