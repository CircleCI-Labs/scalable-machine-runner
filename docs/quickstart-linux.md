---
page-title: Quickstart on Linux
page-audience: admin
page-description: Run a first job on a Docker Swarm node with CircleCI machine runner 3 in about a dozen commands, for a one-node trial or the start of a cluster.
---

# Quickstart on Linux

This page takes you from nothing to a first job on Linux with the shipped stack file and the setup helper, from a signed release. It sets up one class, `linux-default`. Nothing is installed on a node by hand: the stack has a service that installs the runner on every node. The page explains little. [Install on Linux with Docker Swarm](install-linux.md) has every step by hand with the reasons, and [Concepts](concepts.md) explains the model.

> [!NOTE]
> This is a CircleCI Labs project. CircleCI support does not cover it. It is a `0.x` release: a minor release can change your stack files, so read the release notes before you upgrade. It is tested against CircleCI cloud only. [What is tested](../README.md#what-is-tested) says how, and [Security](security.md) says what a job on a runner can reach.
>
> **Availability.** One token proxy runs on a manager, and every runner API call goes through it. While the proxy or its manager is down, no new job starts, and Swarm restarts the proxy. Use three managers for a production cluster. This is not an autoscaling or high-availability product: the replicas are fixed, and the nodes are yours.

## Before you start

- A node with Ubuntu LTS, Docker Engine 24 or later, a clock on NTP, and outbound HTTPS. CI tests Ubuntu 26.04 on amd64 with real jobs, and the start of the stack on arm64, with probe jobs on a real arm64 runner on `main`. RHEL 8 or later is documented and not tested. ppc64le and s390x start under emulation only, and no job runs there. [Prepare each node](install-linux.md#2-prepare-each-node) shows how to install Docker. [Prerequisites](install-linux.md#prerequisites) has the details, and [Sizing](#sizing-and-pending-replicas) the CPU and memory.
- Outbound HTTPS from the node to `runner.circleci.com`, `circleci-binary-releases.s3.amazonaws.com`, `circleci-tasks-prod.s3.us-east-1.amazonaws.com`, your VCS host, `github.com` (the release download), and the registries for the images (Docker Hub). [Egress hosts](security.md#egress-hosts) says what each is for, and [What needs internet](security.md#what-needs-internet) lists everything. A node without internet access does not work in this release.
- An organization admin who accepted the [CircleCI Runner Terms](https://circleci.com/legal/runner-terms/), in the web app or by using the CLI for self-hosted runners, as [CircleCI documents](https://circleci.com/docs/guides/execution-runner/install-machine-runner-3-on-linux/#self-hosted-runner-terms-agreement).
- The [CircleCI CLI](https://circleci.com/docs/guides/toolkit/circleci-cli/) 1.4.0 or later on your workstation or on the node. Step 1 signs it in.
- [cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 3.1.3 or a later 3.x (CI signs and verifies with 3.1.3, and earlier versions are not tested), and `jq` and `curl`, on the node, to verify the release.
- A bash shell. Run the commands on the node with `sudo`, or as a user in the `docker` group. The `docker` group is equivalent to root, so limit it.

Replace `<namespace>` with your runner namespace, and `<org>` with your organization slug such as `gh/my-org`, or its UUID.

## Steps

1. Sign in, and check that your organization has a namespace. Each organization has one namespace, which orbs and runners share, and only CircleCI support can change it. If your organization publishes orbs, it has one. `circleci namespace get <namespace>` looks up a name that you know. If your organization has none, create it.

   ```bash
   circleci auth login
   circleci namespace create <namespace> --org <org>   # only when the organization has no namespace yet
   ```

2. Create a resource class and a token for it. The command prints the token once, so keep it for step 5. Without `--org`, the CLI takes the organization of the git remote of the current directory.

   ```bash
   circleci runner resource-class create <namespace>/linux-default --org <org> --generate-token
   ```

3. On the node, download a release, verify it, and unpack it. A release is the install path: its stack file names the token proxy image of that release by tag and digest, and the CircleCI job that made it signed the checksums with a keyless [cosign](https://docs.sigstore.dev/cosign/overview/) signature. A `git clone` of a branch or a tag gets the stack files with the default image `latest`, which is not pinned. The token proxy image is `ccilabs/machine-runner-swarm-proxy`: `ccilabs` is the Docker Hub organization of CircleCI Labs, and the signature check, not the name, is the trust root ([Verify the token proxy image](security.md#verify-the-token-proxy-image)).

   Set `version` once, to the number of the [latest release](https://github.com/CircleCI-Labs/machine-runner-swarm/releases/latest) without the `v`, and read its notes. The line below is a placeholder: with it unchanged, the download fails and nothing runs.

   ```bash
   version=X.Y.Z
   ```

   Then paste this block. It runs in a subshell with `set -euo pipefail`, so the first failing check ends it. The three checks are the signature, the ref in the certificate, and the checksum, and only a bundle that passes all three is unpacked.

   ```bash
   (
     set -euo pipefail
     base="https://github.com/CircleCI-Labs/machine-runner-swarm/releases/download/v${version}"
     curl -fsSLO "${base}/machine-runner-swarm-${version}.tar.gz" -O "${base}/SHA256SUMS" -O "${base}/SHA256SUMS.sigstore.json"

     # 1. the signature: the CircleCI project and pipeline definition of this repository signed SHA256SUMS
     cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json \
       --certificate-identity "https://circleci.com/api/v2/projects/7bbdbb66-6ba8-4f6c-982e-d4fb401ec257/pipeline-definitions/8b2a66db-3f28-5c80-88e4-03f4694b5b60" \
       --certificate-oidc-issuer "https://oidc.circleci.com"

     # 2. the ref: a job of any branch can sign with that identity, so the certificate must also say that the job ran for refs/heads/main
     #    (the long string is the OID 1.3.6.1.4.1.57264.1.14 followed by the value refs/heads/main)
     hex=$(jq -r '.verificationMaterial | (.certificate // .x509CertificateChain.certificates[0]).rawBytes' SHA256SUMS.sigstore.json | base64 -d \
       | od -An -v -tx1 | tr -d ' \n')
     grep -Eq '^([0-9a-f]{2})*2b0601040183bf30010e0411(0c|13)0f726566732f68656164732f6d61696e' <<< "${hex}" \
       && echo "signed for refs/heads/main" || { echo "NOT signed for refs/heads/main: stop"; exit 1; }

     # 3. the file: its checksum is in the signed list
     sha256sum -c SHA256SUMS --ignore-missing

     # only a verified bundle is unpacked
     tar -xzf "machine-runner-swarm-${version}.tar.gz"
     echo "RELEASE VERIFIED"
   )
   ```

   Continue only when the last line is `RELEASE VERIFIED`. Anything else, an error message or no output at all, means that the release is not verified: delete the downloaded files and start again, or ask in an issue. The ref check exists because the signing identity is the same for every branch, so the block looks in the certificate for the extension `1.3.6.1.4.1.57264.1.14` (the OID in the long string) with the value `refs/heads/main`, and fails when a job of another branch signed the file. [Verify a release](install-linux.md#verify-a-release) explains the identity and what a valid signature does not prove, and [How the signature works](https://github.com/CircleCI-Labs/machine-runner-swarm/blob/main/docs/releasing.md#how-the-signature-works) explains the ref check.

   Change into the unpacked bundle. The paths below are relative to it.

   ```bash
   cd "machine-runner-swarm-${version}"
   ```

4. Check the node and create the Swarm. Choose one of two forks. A Swarm that listens on the loopback address cannot accept other nodes, so a trial cannot grow into a cluster without a new `swarm init` and new secrets. Decide now.

   - **Trial, one node.** The Swarm listens on the loopback address, so nothing is exposed and no other node can join. The runners and the token proxy share the node, so a job that escaped its container could read the class tokens: use it for a trial.

     ```bash
     sudo linux/setup.sh --check --swarm-init
     ```

   - **Cluster.** Check every node, create the Swarm on the first one with an address that the others can reach, join the rest, and label the manager that runs the token proxy. Open the [inter-node ports](multi-node.md#inter-node-ports) first. The shipped Linux class overlays are encrypted, so a multi-node cluster also needs IP protocol 50 (ESP) between nodes ([Encrypted class networks](multi-node.md#encrypted-class-networks)). A first cluster of one manager and two workers is enough to try it. A node needs nothing else: the stack installs the runner on each node that joins.

     ```bash
     sudo linux/setup.sh --check                             # on every node
     sudo docker swarm init --advertise-addr <manager IP address>   # on the manager
     sudo docker swarm update --task-history-limit 2         # on the manager
     sudo docker swarm join-token worker                     # prints the join command: run it on each worker
     sudo docker node ls                                     # on the manager: every node is Ready
     sudo docker node update --label-add machine-runner-swarm.proxy=true <manager node name>   # on the manager
     ```

     The label marks the node that runs the proxy, which holds every class token. Runner services never run on a node with this label, so jobs do not share a node with the tokens. With no worker, the runner replicas stay `Pending`. With one manager, the proxy runs there by default. With several managers, pin the proxy to the labelled one when you deploy in step 6: [Where the proxy runs, and when it moves](operations.md#where-the-proxy-runs-and-when-it-moves) shows the variable. Keep one manager that you do not drain, because the proxy needs it.

     Run steps 5 to 7 on the manager. Refer to [Multi-Node Clusters](multi-node.md) for labels, zones, quorum, and encrypted overlays.

5. Create the Swarm secret for the token. The helper asks for it with hidden input and never prints it. The token goes to the token proxy only. Then create the placeholder that the runners read instead of a token: any value works.

   ```bash
   sudo linux/setup.sh --secret linux-default
   printf %s machine-runner-swarm-placeholder | sudo linux/setup.sh --secret runner-placeholder
   ```

6. Copy the stack directory, and deploy your copy. For a first run, change nothing in it. You review it later, and from here on you deploy your copy and never the shipped files. The directory holds the stack files and the two scripts that they ship as Swarm configs, which the stack files name next to themselves. A new release changes the shipped files, so an upgrade is a merge of your copy with the new files: [Upgrade](install-linux.md#upgrade) shows how.

   ```bash
   cp -r linux/stack deploy
   sudo linux/setup.sh --deploy --stack-file deploy/runners.yaml
   ```

   This is the whole install. The service `runner-distributor` starts on every Linux node (a node that you label for the microVM add-on is the exception: it has its own copy), downloads the runner of CircleCI, checks its SHA-256, and makes it available to the runner services. A runner container that starts first waits up to 2 minutes for it. In a release bundle, the token proxy image is pinned by digest. The helper warns when `MACHINE_RUNNER_SWARM_PROXY_IMAGE` is not pinned by digest.

7. Check that the runners are up and connected. `docker stack deploy` does not wait, so the replicas need a minute to start.

   ```bash
   sudo docker stack services runners
   sudo docker service logs --tail 20 runners_runner-distributor
   sudo docker service logs --tail 20 runners_linux-default
   circleci runner instance list --org <org> --resource-class <namespace>/linux-default
   ```

   The runners are healthy when `REPLICAS` shows `2/2` for `runners_linux-default` (or fewer for [Pending replicas](#sizing-and-pending-replicas)) and `1/1` for `runners_token-proxy`, the distributor shows one task for each node and logs a line such as `[ ok ] current -> versions/3.1.13`, the log of the runners has no `401` or `error` lines, and the CLI lists an instance with the status `online`. The same list is in the web app under **Runners**.

8. Run a job. Save the following as `.circleci/config.yml` in a project of your organization, replace `my-namespace`, commit, and push. The same file is [`examples/linux-hello.yml`](../examples/linux-hello.yml).

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

The shipped file reserves 4 CPUs and 8 GB of memory for the runners: two replicas of `linux-default` (2 CPUs, 4 GB each). The token proxy and the distributor reserve little. A replica needs its whole reservation free on one node. Leave about 1 CPU and 2 GB for the operating system and Docker. [Size the limits](resource-classes.md#size-the-limits) has a table of every shipped class, with the CPU and memory of a replica, the default replicas, and what else it needs.

The cost of the project is your own hardware, plus the runner concurrency of your CircleCI plan: the replicas of all classes and the jobs that wait share the concurrency limit of your organization. Disk is not limited per container. Each finished job leaves a stopped container until Swarm prunes its task (the setup in step 4 keeps the last 2 for each slot), and the images take space too. This repository has no measurement of the disk that a job needs, so watch a node during a trial.

A replica that does not fit stays `Pending`. That is not an error: Swarm waits for room, the other replicas work, and `docker service ps --no-trunc runners_<service>` shows `insufficient resources on 1 node`. To fit a small node, lower `deploy.replicas` in your copy and deploy it again with the same command. The smallest useful test is `replicas: 1` for `linux-default`, which needs 2 CPUs and 4 GB. Refer to [A task stays pending](troubleshooting.md#a-task-stays-pending) for the other causes.

## What you did not do

The helper checks the node, starts Swarm, creates the secrets, and deploys the stack. It does not install Docker, create classes or tokens, edit the stack file, label or join nodes, or build images. It does not install the runner either: the `runner-distributor` service of the stack does that on every Linux node. [Optional: use the setup helper](install-linux.md#optional-use-the-setup-helper) lists each step.

## Next

- [Install on Linux with Docker Swarm](install-linux.md): the same steps by hand, RHEL, and the release verification.
- [Resource Classes](resource-classes.md): add classes, and change sizes and replica counts. `linux-java` and `linux-hardened` are in `linux/stack/classes-extra.yaml`; deploy that file with an extra `-c` together with `runners.yaml`. A class is a service, its token secret `<service>-token` and its network, and the secret and the network are also listed on `token-proxy`, which finds its classes in its secrets: there is no variable to set.
- [Security](security.md): choose between the default and the hardened class before you give a class to a team, and read what a job on a cloud node can reach.
- [Operations](operations.md): pin or roll back the runner version, rotate tokens, and run the cluster.
