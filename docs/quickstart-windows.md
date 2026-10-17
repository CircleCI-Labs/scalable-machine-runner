---
page-title: Quickstart on Windows Server
page-audience: admin
page-description: Run a first job on a Windows Server Docker Swarm node with CircleCI machine runner 3 in five steps, using the stock Server Core image.
---

# Quickstart on Windows Server

Go from nothing to a first job on one Windows Server node in five steps. Nothing is built or installed on the host: the stack uses the stock Server Core image, and a service of the stack installs the runner and Git.

> [!NOTE]
> CircleCI Labs project, `0.x`, not supported by CircleCI support. This trial runs the proxy and the jobs on one host, so it is not for production. [What is tested](../README.md#what-is-tested) shows what CI checks.

## Before you start

- A Windows Server 2022 or 2025 host (amd64, not a domain controller) with a clock synced with NTP, and outbound HTTPS ([what needs internet](security.md#what-needs-internet)).
- Size: 6 CPUs and 12 GB for the two sample replicas, or run one replica (4 CPUs, 8 GB). The first pull of the Server Core image is about 2.2 GB.
- Docker Engine and CLI 28.0 or later in Windows-container mode, and the Windows Containers feature. Check with `docker version --format '{{.Server.Version}}'` and `docker info --format '{{.OSType}}'` (it must print `windows`). If either fails, follow [Prerequisites](install-windows.md#prerequisites).
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later, on your workstation.
- An organization admin who accepted the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/).
- A repository that is set up as a CircleCI project in your organization, and runner concurrency in your plan (2 for the sample replicas).
- A namespace. An organization has one, and orbs use it too. It is the part before the `/` in a resource class (`acme` in `acme/my-class`). If you have none, run `circleci namespace create <NAMESPACE> --org <ORG>`.
- An elevated Windows PowerShell 5.1 session on the host.

Replace `<NAMESPACE>` with your namespace, and `<ORG>` with your organization slug such as `gh/my-org`, or its UUID. Run step 1 on your workstation, where a browser opens for `circleci auth login`. Run steps 2 to 4 in the PowerShell session on the host.

## Steps

1. Create a resource class and a token. Copy the token from the output: the command prints it once, and step 3 asks for it on the host.

   ```powershell
   circleci auth login
   circleci runner resource-class create <NAMESPACE>/windows-default --org <ORG> --generate-token
   ```

2. On the host, download the latest release. To verify the release signature first, see [Install on Windows Server: Verify a release](install-windows.md#verify-a-release).

   ```powershell
   $uri = (Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/CircleCI-Labs/machine-runner-swarm/releases/latest').BaseResponse.ResponseUri.AbsoluteUri
   $version = $uri -replace '^.*/v', ''
   $zip = "machine-runner-swarm-$version.zip"
   Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/CircleCI-Labs/machine-runner-swarm/releases/download/v$version/$zip" -OutFile $zip
   Expand-Archive -LiteralPath $zip -DestinationPath .
   cd "machine-runner-swarm-$version"
   ```

3. Pull the images, then run the helper. Pull first: the network of the host drops for a few seconds after `docker swarm init`. The first command pulls the base image, and the second pulls the token proxy image that your stack file names.

   ```powershell
   docker pull mcr.microsoft.com/windows/servercore:ltsc2022
   ```

   ```powershell
   docker pull ((Select-String -Path windows\stack\runners.yaml -Pattern 'MACHINE_RUNNER_SWARM_PROXY_IMAGE:-([^}]+)\}').Matches[0].Groups[1].Value)
   ```

   The helper needs the IPv4 address of the host. If the host has several, use the address of the adapter that other nodes will reach. For a one-host trial, any address of the host works.

   ```powershell
   Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual | Select-Object IPAddress, InterfaceAlias
   ```

   Swarm takes `10.0.0.0/8` for its overlay networks. If your network uses that range, run `docker swarm init --advertise-addr <HOST_IPV4_ADDRESS> --default-addr-pool <POOL_CIDR> --default-addr-pool-mask-length 24` yourself, and run the helper below without `-InitSwarm` and `-AdvertiseAddr`. Otherwise, the helper creates the Swarm, labels the node, asks for the token from step 1 (hidden input), creates the secrets, and deploys the stack:

   ```powershell
   .\windows\Setup.ps1 -InitSwarm -AdvertiseAddr <HOST_IPV4_ADDRESS> -Class windows-default -Deploy
   ```

4. Check the stack. `docker stack deploy` does not wait, and the first start downloads the runner, so the replicas need a few minutes. Early runner tasks fail until the download ends, and Swarm restarts them.

   ```powershell
   docker stack services runners
   circleci runner instance list --org <ORG> --resource-class <NAMESPACE>/windows-default
   ```

   The stack is up when `runners_windows-default` shows `2/2`, `runners_token-proxy-windows` shows `1/1`, and the CLI lists an instance with the status `online`. `docker service logs runners_runner-distributor-windows` shows the install. If a replica stays `Pending`, the host is too small: each replica reserves 2 CPUs and 4 GB, and the proxy and the distributor reserve nothing but can use 1 CPU each. The Windows engine rejects a CPU limit above the CPU count of the host. Run one replica:

   ```powershell
   docker service scale runners_windows-default=1
   ```

   The next `docker stack deploy` resets it to 2. To keep one, set `deploy.replicas` in your copy of the stack file ([Size the limits](resource-classes.md#size-the-limits), [A task stays pending](troubleshooting.md#a-task-stays-pending)).

5. Run a job. Save this as `.circleci/config.yml` in a project of your organization, replace `<NAMESPACE>` with your namespace, then commit and push. The file [`examples/windows-job.yml`](../examples/windows-job.yml) has more steps.

   ```yaml
   version: 2.1

   jobs:
     hello:
       machine: true
       resource_class: <NAMESPACE>/windows-default
       steps:
         - run: echo "computer $COMPUTERNAME, instance $MACHINE_RUNNER_SWARM_INSTANCE_ID"

   workflows:
     hello:
       jobs:
         - hello
   ```

   Run the workflow twice. The two runs print different values, because Swarm starts a new container for each job. The job shows `Queued` while no runner is online: check step 4 first. The default shell is Git Bash, so `$COMPUTERNAME` is an environment variable. For PowerShell, set `shell: powershell.exe -ExecutionPolicy Bypass` and write `$env:COMPUTERNAME`.

## What differs from Linux

- A job runs as an administrator. The runner container holds a placeholder, and the class token stays in the token proxy, except in the `windows-persistent` class ([Token model on each OS](security.md#token-model-on-each-os)).
- Stopping a busy container, for an update, a scale-down or a drain, kills its job after about 5 seconds. Change a class while it is idle ([Stop a busy Windows container](operations.md#stop-a-busy-windows-container)).

## Next

- [Install on Windows Server](install-windows.md): every step by hand, release verification, and upgrades. Before production, copy `windows\stack` to a directory of your own and deploy that copy ([Review the stack files](install-windows.md#5-review-the-stack-files)).
- [Concepts](concepts.md): services as resource classes, the token proxy, and the job lifecycle.
- [Images](images.md): add your own tools on top of Server Core.
- [Security](security.md): the token model and BitLocker.
- [Operations](operations.md): upgrade, rotate tokens, and run the cluster.
- [Uninstall](operations.md#uninstall): remove the trial, and leave the swarm.
