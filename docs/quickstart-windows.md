---
page-title: Quickstart on Windows Server
page-audience: admin
page-description: Run a first job on a Windows Server Docker Swarm node with CircleCI machine runner 3 in six steps, using the stock Server Core image.
---

# Quickstart on Windows Server

This page takes you from nothing to a first job on one Windows Server node with the shipped stack file and the setup helper, from a signed release. It explains little. [Install on Windows Server with Docker Swarm](install-windows.md) has every step by hand with the reasons, and [Concepts](concepts.md) explains the model. Nothing is built and nothing is installed on the host: the service uses the stock Server Core image, and the distributor service of the stack installs the runner and Git.

> [!NOTE]
> This is a CircleCI Labs project. CircleCI support does not cover it. It is a `0.x` release: a minor release can change your stack files, so read the release notes before you upgrade. It is tested against CircleCI cloud only. [What is tested](../README.md#what-is-tested) says how, and [Security](security.md) says what a job on a runner can reach.
>
> **Availability.** One token proxy (`token-proxy-windows`) runs on a manager, and every runner API call goes through it. While the proxy or its manager is down, no new job starts, and Swarm restarts the proxy. This page sets up one host, which runs the proxy and the jobs together: use it for a trial. This is not an autoscaling or high-availability product: the replicas are fixed, and the nodes are yours.

## Before you start

- A Windows Server 2022 or 2025 host that is not a domain controller, amd64, with a clock on NTP and outbound HTTPS. CI tests both versions with real jobs. Windows Server 2019 is not tested.
- Docker Engine and CLI 28.0 or later in Windows-container mode (the stack files mount a subpath of a volume; `.\windows\Setup.ps1` checks the version), and the Windows Containers feature, which needs a reboot. The `Install-DockerCE` script in the `helpful_tools` directory of the [Microsoft Windows Containers repository](https://github.com/microsoft/Windows-Containers) installs both ([Prerequisites](install-windows.md#prerequisites) has the details). The first pull of the `servercore` base image is about 2.2 GB and takes minutes to tens of minutes, depending on the network (about 10 minutes on the CI machines). Refer to [Sizing](#sizing-and-pending-replicas) for the CPU and memory.
- Outbound HTTPS from the host to `runner.circleci.com`, `circleci-binary-releases.s3.amazonaws.com`, `circleci-tasks-prod.s3.us-east-1.amazonaws.com`, your VCS host, `github.com` and `release-assets.githubusercontent.com` (the release, Git, and 7-Zip), `mcr.microsoft.com`, and Docker Hub. [Egress hosts](security.md#egress-hosts) says what each is for, and [What needs internet](security.md#what-needs-internet) lists everything. A host without internet access does not work in this release.
- An organization admin who accepted the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/), in the web app or by using the CLI for self-hosted runners, as [CircleCI documents](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-windows/#self-hosted-runner-terms-agreement).
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later. It can run on your workstation. Step 1 signs it in.
- [cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 3.1.3 or a later 3.x on the host, to verify the release (CI signs and verifies with 3.1.3, and earlier versions are not tested). [Install cosign](install-windows.md#install-cosign) shows how.
- An elevated Windows PowerShell 5.1 session on the host for the steps that start with `docker` or `.\windows`.

Replace `<namespace>` with your runner namespace, and `<org>` with your organization slug such as `gh/my-org`, or its UUID.

## Steps

1. Sign in, and check that your organization has a namespace. Each organization has one namespace, which orbs and runners share, and only CircleCI support can change it. If your organization publishes orbs, it has one. `circleci namespace get <namespace>` looks up a name that you know. If your organization has none, create it.

   ```powershell
   circleci auth login
   circleci namespace create <namespace> --org <org>   # only when the organization has no namespace yet
   ```

2. Create the resource class and its token. The command prints the token once, so keep it for step 6.

   ```powershell
   circleci runner resource-class create <namespace>/windows-default --org <org> --generate-token
   ```

3. On the host, download a release, verify it, and unpack it. A release is the install path: its stack file names the token proxy image of that release by tag and digest, and the CircleCI job that made it signed the checksums with a keyless cosign signature. A `git clone` of a branch or a tag gets the stack files with the default image `latest`, which is not pinned. The token proxy image is `ccilabs/machine-runner-swarm-proxy`: `ccilabs` is the Docker Hub organization of CircleCI Labs, and the signature check, not the name, is the trust root ([Verify the token proxy image](security.md#verify-the-token-proxy-image)).

   Set `$version` once, to the number of the [latest release](https://github.com/CircleCI-Labs/scalable-machine-runner/releases/latest) without the `v`, and read its notes. The first line is a placeholder: with it unchanged, the download fails and nothing runs.

   ```powershell
   $version = 'X.Y.Z'
   $base = "https://github.com/CircleCI-Labs/scalable-machine-runner/releases/download/v$version"
   $zip = "machine-runner-swarm-$version.zip"
   ```

   Then paste this block. It stops at the first failing check, and only a bundle that passes all three checks (the signature, the ref in the certificate, and the checksum) is unpacked.

   ```powershell
   & {
     $ErrorActionPreference = 'Stop'
     foreach ($f in $zip, 'SHA256SUMS', 'SHA256SUMS.sigstore.json') { Invoke-WebRequest -UseBasicParsing -Uri "$base/$f" -OutFile $f }

     # 1. the signature: the CircleCI project and pipeline definition of this repository signed SHA256SUMS
     cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json `
       --certificate-identity 'https://circleci.com/api/v2/projects/7bbdbb66-6ba8-4f6c-982e-d4fb401ec257/pipeline-definitions/8b2a66db-3f28-5c80-88e4-03f4694b5b60' `
       --certificate-oidc-issuer 'https://oidc.circleci.com'
     if ($LASTEXITCODE -ne 0) { throw 'the signature does not verify: stop' }

     # 2. the ref: a job of any branch can sign with that identity, so the certificate must also say that the job ran for refs/heads/main
     #    (the long string is the OID 1.3.6.1.4.1.57264.1.14 followed by the value refs/heads/main)
     $material = (Get-Content -Raw -LiteralPath SHA256SUMS.sigstore.json | ConvertFrom-Json).verificationMaterial
     if ($material.certificate) { $cert = $material.certificate.rawBytes } else { $cert = $material.x509CertificateChain.certificates[0].rawBytes }
     $hex = -join ([Convert]::FromBase64String($cert) | ForEach-Object { $_.ToString('x2') })
     if ($hex -notmatch '^([0-9a-f]{2})*2b0601040183bf30010e0411(0c|13)0f726566732f68656164732f6d61696e') { throw 'NOT signed for refs/heads/main: stop' }

     # 3. the file: its checksum is in the signed list
     $want = ((Get-Content SHA256SUMS | Where-Object { $_ -match "\s$([regex]::Escape($zip))$" }) -split '\s+')[0]
     if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLower() -ne $want) { throw "the checksum of $zip is not the signed one: stop" }

     # only a verified bundle is unpacked
     Expand-Archive -LiteralPath $zip -DestinationPath .
     'RELEASE VERIFIED'
   }
   ```

   Continue only when the last line is `RELEASE VERIFIED`. Anything else, an error message or no output at all, means that the release is not verified: delete the downloaded files and start again, or ask in an issue. The ref check exists because the signing identity is the same for every branch, so the block looks in the certificate for the extension `1.3.6.1.4.1.57264.1.14` (the OID in the long string) with the value `refs/heads/main`, and fails when a job of another branch signed the file. [Verify a release](install-windows.md#verify-a-release) explains it, and [How the signature works](https://github.com/CircleCI-Labs/scalable-machine-runner/blob/main/docs/releasing.md#how-the-signature-works) has the details.

   Change into the unpacked bundle. The paths below are relative to it.

   ```powershell
   cd "machine-runner-swarm-$version"
   ```

4. Pull the base image before you create the Swarm, because the network of the host drops for a few seconds after `docker swarm init`. A Server 2025 host runs this `ltsc2022` image too.

   ```powershell
   docker pull mcr.microsoft.com/windows/servercore:ltsc2022
   ```

5. Copy the stack directory. For a first run, change nothing in it. You review it later, and from here on you deploy your copy and never the shipped files. The directory holds the stack files and the script that `runners.yaml` ships as a Swarm config, which the file names next to itself. A new release changes the shipped files, so an upgrade is a merge of your copy with the new files: [Upgrade](install-windows.md#upgrade) says how.

   ```powershell
   Copy-Item -Recurse windows\stack deploy
   ```

6. Run the helper. It creates the Swarm, labels the node with the image tags it can run (the node is a manager, where the token proxy runs by default, so it needs no other label), asks for the token with hidden input, creates the secrets `windows-default-token` (the token proxy holds it) and `runner-placeholder-token` (what the runners read), and deploys your copy. Use the IPv4 address of the host. This is the whole install: the service `runner-distributor-windows` downloads and verifies the runner that the stack pins (the newest version that CI tests) and the pinned portable Git on its own, and Swarm pulls the token proxy image of this release by its digest.

   ```powershell
   .\windows\Setup.ps1 -InitSwarm -AdvertiseAddr <host IPv4 address> -Class windows-default -StackFile .\deploy\runners.yaml -Deploy
   ```

7. Check that the runners are up and connected, and then run a job. `docker stack deploy` does not wait, so the replicas need a few minutes to start: the first download of the distributor takes a while, the first runner tasks fail until it is done and are started again every 10 seconds, and the first task also pulls the image if you skipped step 4. `docker service logs runners_runner-distributor-windows` shows the install.

   ```powershell
   docker stack services runners
   circleci runner instance list --org <org> --resource-class <namespace>/windows-default
   ```

   The runners are healthy when `REPLICAS` shows `2/2` (or fewer for [Pending replicas](#sizing-and-pending-replicas)) and the CLI lists an instance with the status `online`. The same list is in the web app under **Runners**. Then save the following as `.circleci/config.yml` in a project of your organization, replace `my-namespace`, commit, and push. Run the workflow twice.

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

   The two runs print different values, because Swarm starts a new container for each job. The file [`examples/windows-job.yml`](../examples/windows-job.yml) has more steps.

## Two things that differ from Linux

- A job on Windows runs as an administrator. In a single-task class such as `windows-default`, the runner container holds only a placeholder, and the class token is in the service `token-proxy-windows`. A job can read the placeholder, and it may be able to send packets with a forged source address, because a Windows container cannot drop `NET_RAW` the way a Linux one can. This is not tested on Windows, and [Security](security.md) says what it could gain. The `windows-persistent` class is the exception: its container holds the real token, and a job can read it. Treat each class as a trust boundary. Refer to [Token model on each OS](security.md#token-model-on-each-os).
- A stop of a busy container from outside, such as an update, a scale-down, or a node drain, kills its job after about 5 seconds. A job that finishes ends its container cleanly. Change a Windows class while it is idle. Refer to [Stop a busy Windows container](operations.md#stop-a-busy-windows-container).

## Sizing and Pending replicas

The shipped file runs two replicas of `windows-default`, and each reserves 2 CPUs and 4 GB of memory, so the service needs 4 CPUs and 8 GB. The distributor and the token proxy set limits and reserve nothing (1 CPU and 1 GB, and 1 CPU and 512 MB), so leave room for them and for the operating system. The Windows engine rejects a CPU limit above the CPU count of the host. A replica needs its whole reservation free on one node. [Size the limits](resource-classes.md#size-the-limits) has a table of every shipped class. The cost of the project is your own hardware, plus the runner concurrency of your CircleCI plan, and the disk is not measured here: the base image alone is about 2.2 GB, and every finished container keeps its layer until Swarm prunes it.

A replica that does not fit, or that no node is allowed to run, stays `Pending`. That is not an error: Swarm waits, and the other replica works. `docker service ps --no-trunc runners_windows-default` shows the reason, such as `insufficient resources` or `scheduling constraints not satisfied`. For a small host, lower `deploy.replicas` in your copy and deploy it again. Refer to [A task stays pending](troubleshooting.md#a-task-stays-pending) for the other causes.

## What you did not do

The helper starts Swarm. It does not install Docker or the runner, create classes or tokens, edit the stack file, label nodes for the optional classes, or build images. [Optional: use the setup helper](install-windows.md#optional-use-the-setup-helper) lists each option.

## Next

- [Install on Windows Server with Docker Swarm](install-windows.md): the same steps by hand, with the release verification.
- [Images](images.md): add your own tools on top of Server Core.
- [Security](security.md): the token model and BitLocker.
- [Operations](operations.md): upgrade, rotate tokens, and run the cluster.
