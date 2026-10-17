---
page-title: MicroVM jobs with Kata Containers
page-audience: admin
page-description: Run each job in its own microVM with Kata Containers on labeled Linux nodes, set up the nodes, and learn what the add-on costs and what it does not cover.
---

# MicroVM jobs with Kata Containers

In a [Kata Containers](https://katacontainers.io/) microVM, every container starts in a small virtual machine with its own Linux kernel, so a job that breaks out of its container reaches the guest, not the node. The optional add-on stack file `linux/stack/microvm.yaml` runs two resource classes this way, and the default classes do not change.

Use it when jobs need a boundary stronger than a container, or privileges that are unsafe on a shared kernel. `linux-microvm-docker` runs its own Docker daemon inside the VM, so an image build needs no host Docker socket. That is safer than the [docker-build class](docker-builds.md#pattern-a-the-host-docker-engine). It builds images only: `docker run`, Compose and service containers do not work in it ([Run Docker inside the VM](#run-docker-inside-the-vm)).

> [!WARNING]
> **Status: experimental.** The classes ship and stay in the stack. Maturity:
>
> - **Tested by the CI** (`linux/tests/microvm.sh`): placement, DNS, the claim through the token proxy, the runner download and its verification, the rolling update, and builds with the Docker daemon in the VM. On amd64, with Kata 4.2.0, Cloud Hypervisor and QEMU, in nested virtualization on AWS, against a fake CircleCI API.
> - **Not verified by this project:** real CircleCI jobs, with checkout, caches, workspaces and artifacts through the task agent. The CI runs an empty task only. Run a real job on a node of your own before you depend on it.
> - **Not tested:** arm64, AMD CPUs, other clouds, Firecracker, many VMs at once, out-of-memory behavior, and Kata upgrades under load.
>
> Refer to [What is tested](#what-is-tested).

## How it works

Swarm cannot ask for Kata per service. The Docker daemon of each node picks the runtime, so the node decides:

- A microVM node has Kata as the `default-runtime` of its Docker daemon and the label `machine-runner-swarm.microvm=true`. Every container on it is a microVM.
- The two classes run only on nodes with that label. Every other class carries `node.labels.machine-runner-swarm.microvm != true`, so labeling a node moves them off it.
- The classes set `MACHINE_RUNNER_SWARM_REQUIRE_MICROVM=true`. The entrypoint exits with code 80 unless `/proc/cmdline` names `kata-containers`, so a node with the label but the wrong default runtime never runs a class that has `SYS_ADMIN`.
- Docker's embedded DNS does not work in a Kata VM, so the service `microvm-dns` forwards it ([DNS](#dns)).
- The classes claim through the [token proxy](security.md#the-token-proxy), which runs on a runc node. A job in a VM never sees a class token.
- Each container downloads and verifies the runner ([The runner in a VM](#the-runner-in-a-vm)), and the global service `microvm-netkeep` keeps the class networks up ([Rolling updates](#rolling-updates)).

| | `linux-default` | `linux-microvm` | `linux-microvm-docker` |
|---|---|---|---|
| Kernel of the job | The node kernel | Its own guest kernel | Its own guest kernel |
| Runs on | Nodes without the `microvm` and `docker-build` labels | Nodes with `microvm=true` | Nodes with `microvm=true` |
| Job user | `circleci`, with sudo | `circleci`, with sudo | `circleci`, with sudo |
| Class token in the job | No, the proxy holds it | No | No |
| The runner | The per-node volume, read-only | Downloaded by the container, then verified | Downloaded by the container, then verified |
| Capabilities | Docker's defaults, minus `NET_RAW` and `MKNOD` | The same | Docker's defaults, plus `SYS_ADMIN` (no `NET_ADMIN`, and `NET_RAW` stays) |
| Replicas | 2 | 2 | 1, and keep it at 1 ([Security](#security)) |
| Docker in the job | No | No | Its own `dockerd` in the VM, on a tmpfs, for builds |

## Requirements

- **KVM.** The node needs `/dev/kvm`: bare metal, or a virtual machine with nested virtualization.
- **Linux amd64.** The add-on pins the amd64 build of Kata 4.2.0.
- **Docker Engine 24 or later**, and a Swarm that follows [Multi-node clusters](multi-node.md).
- **One runc node at least** for `microvm-dns` and `token-proxy`, for example a manager. A Swarm whose only node is a microVM node cannot run them ([DNS](#dns)).
- **The base stack** `runners.yaml` with its placeholder secret ([Install on Linux](install-linux.md)). The token proxy never runs on a microVM node: label its node as [Multi-node clusters](multi-node.md#managers-and-quorum) says.
- **A node of its own.** The default runtime applies to every container, so a microVM node runs microVM classes only.
- **Egress to `circleci-binary-releases.s3.amazonaws.com`**, the host the task agent already comes from ([Egress hosts](security.md#egress-hosts)).

### Nested virtualization in the cloud

| Cloud | Instances | Notes |
|---|---|---|
| AWS | C8i, M8i, R8i (also the flex sizes), C7i, M7i, R7i (also the flex sizes), I7i, and every `.metal` size | Intel only. Enable nested virtualization when you launch the instance. The tested node was an `r8i-flex.2xlarge` |
| Google Cloud, Azure, and others | Nested virtualization exists on some families | Untested |

CircleCI's own cloud executors do not offer nested virtualization, except the Android machine image. Refer to [CI](ci.md#linux-microvm).

## Set up a microVM node

Run these steps as root on every microVM node, after it joined the Swarm ([Install on Linux](install-linux.md)).

1. **Check KVM and load the vhost modules.** Kata uses `vhost_vsock` to reach the agent in the VM, and `vhost_net` for networking.

   ```bash
   ls -l /dev/kvm
   sudo modprobe vhost_vsock vhost_net
   printf 'vhost_vsock\nvhost_net\n' | sudo tee /etc/modules-load.d/kata.conf
   ls -l /dev/vhost-vsock /dev/vhost-net
   ```

2. **Install Kata 4.2.0.** The release tarball is about 1 GB and unpacks to about 2.3 GB in `/opt/kata`. It needs `zstd`. Check the SHA-256 before you unpack it.

   ```bash
   curl -fLO https://github.com/kata-containers/kata-containers/releases/download/4.2.0/kata-static-4.2.0-amd64.tar.zst
   echo 'b828904fa3f1e49ddd7dc799c72cb1503cd1e772d354c3987c8d4189b2a623a8  kata-static-4.2.0-amd64.tar.zst' | sha256sum -c -
   sudo tar --zstd -xf kata-static-4.2.0-amd64.tar.zst -C /
   sudo ln -sf /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
   ```

   To upgrade, unpack a new release the same way and restart Docker. Running VMs keep the old files until they stop. Without a route to GitHub, copy the tarball in and keep the SHA-256 check.

## Configure Docker

1. **Add the runtimes to `/etc/docker/daemon.json`** and make Kata the default. Merge these keys into the file if it exists. The runtime `kata` uses Cloud Hypervisor. The runtime `kata-qemu` is the fallback. The test suite runs this exact block.

   ```json
   {
     "default-runtime": "kata",
     "runtimes": {
       "kata": {
         "runtimeType": "io.containerd.kata.v2",
         "options": {"ConfigPath": "/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-clh-runtime-rs.toml"}
       },
       "kata-qemu": {
         "runtimeType": "io.containerd.kata.v2",
         "options": {"ConfigPath": "/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml"}
       }
     }
   }
   ```

   Restart Docker, then check that a container has its own kernel. The two kernels must differ. Containers that ran before the restart stay as they are.

   ```bash
   sudo systemctl restart docker
   uname -r
   docker run --rm alpine uname -r
   ```

   **QEMU as the fallback.** Set `"default-runtime": "kata-qemu"` if Cloud Hypervisor does not work on your hardware. QEMU backs the memory of every VM with `/dev/shm`, which must hold the memory of all VMs together (half of the RAM by default). A tmpfs that is too small fails with `kvm run failed Bad address` and a vsock timeout. In a Docker-in-Docker container, as in the tests, start it with `--shm-size=16g`.

2. **Label the node** before you deploy the stack. A Kata node without the label still matches `microvm-dns`, which cannot work in a VM.

   ```bash
   docker node update --label-add machine-runner-swarm.microvm=true <NODE>
   ```

## DNS

Docker's embedded DNS server, `127.0.0.11`, cannot be reached from inside a Kata VM. `microvm.yaml` works around it in two parts:

- **The forwarder.** `microvm-dns` runs CoreDNS with `forward . 127.0.0.11` on a node without the `microvm` label and joins the networks of both classes, so `token-proxy` and service names resolve. It is published on port 53, TCP and UDP, through the routing mesh.
- **The node file.** The stack mounts a file of each microVM node read-only at `/etc/resolv.conf` of every job. It names the gateway of `docker_gwbridge` (the node itself), and the routing mesh sends the query on to a forwarder.

1. **Write the node file**, after the node joined the Swarm. The gateway is `172.18.0.1` by default and differs when that range was taken, so read it from Docker:

   ```bash
   sudo install -d /etc/machine-runner-swarm
   gw=$(docker network inspect docker_gwbridge --format '{{(index .IPAM.Config 0).Gateway}}')
   printf 'nameserver %s\n' "$gw" | sudo tee /etc/machine-runner-swarm/microvm-resolv.conf
   ```

   Without this file the task does not start (the bind mount fails), so a node that skipped this step never runs a class with broken DNS.

2. **Create the Corefile config once**, on a manager. Swarm configs are immutable: to change the Corefile, create a config under a new name and change `microvm-corefile` in your copy of the stack file.

   ```bash
   printf '.:53 {\n  errors\n  forward . 127.0.0.11\n  cache 30\n}\n' | docker config create microvm-corefile -
   ```

> [!WARNING]
> The routing mesh opens port 53 on every interface of every node, so the forwarder is an open resolver for anyone who can reach the node. Close port 53 to the outside with your cloud firewall or security group, and open it only between the nodes. Docker bypasses `ufw` and `firewalld` for published ports, so use the `DOCKER-USER` chain to filter on the node. A node that runs its own DNS server on port 53 loses it to the routing mesh.

- **Internal names.** The forwarder uses the resolvers of its own node. A name that only the microVM nodes resolve, such as an internal [mirror](operations.md#run-the-downloads-from-a-mirror), fails in the VM. Use a name the runc node resolves, or an IP address in `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL`.
- **Only microVM nodes.** Replace `forward . 127.0.0.11` with `forward . 1.1.1.1` (or your resolver) and put `microvm-dns` on that node without the constraint. Public names then resolve, and service names do not.

## The runner in a VM

The other classes mount the per-node volume `runner-bin` read-only. A microVM class does not: root with `SYS_ADMIN` inside a VM can remount a shared mount read-write, and the write would reach the runner of every later job. So nothing writable is shared:

- The entrypoint downloads the runner into the container (`sh /runner-distributor.sh --once`, a Swarm config of the class): about 22 MB for each job, from the source the task agent comes from. It checks the SHA-256 and the reported version, and writes the same record as on any node. The usual entrypoint checks follow. A mirror of your own must be reachable from the VM ([DNS](#dns)).
- The settings are those of the distributor, with the same defaults, set as variables of `docker stack deploy` (they sit in the service, because no distributor serves them). The pin and its SHA-256 values are the same as in `runners.yaml`:
  - `MACHINE_RUNNER_SWARM_RUNNER_VERSION`: an exact pin by default, or `3.1`, `3`, `current` ([the version policy](operations.md#the-version-policy)). A floating version is resolved in each VM when the job starts and ignores any SHA-256 list.
  - `MACHINE_RUNNER_SWARM_RUNNER_MAJOR`, `MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL` (a [mirror](operations.md#run-the-downloads-from-a-mirror)), and `MACHINE_RUNNER_SWARM_RUNNER_SHA256` (the SHA-256 values of the pin, or `manifest`, which checks against the manifest and is weaker).
- A failed or mismatching download ends the container with exit code 80, and Swarm retries after the restart delay of 10 seconds.

A job can rewrite the runner binary and its record only in its own copy, which goes away with the VM, and no class token is in the VM. Because nothing is shared, no dedicated nodes are needed for this reason.

## Deploy the classes

1. Create the resource classes `<NAMESPACE>/linux-microvm` and `<NAMESPACE>/linux-microvm-docker`, and the secrets `linux-microvm-token` and `linux-microvm-docker-token`, which go to `token-proxy` only ([Resource classes](resource-classes.md#define-a-class)). Delete a class you do not want from your copy of the stack file, with its secret and network.
2. Deploy the add-on stack file with the main file. Pass the same list of files on every later deploy ([why](concepts.md#add-on-stack-files-and-how-they-merge)).

   ```bash
   docker stack deploy -c linux/stack/runners.yaml -c linux/stack/microvm.yaml runners
   ```

The classes run the same entrypoint as `linux-default`. A VM has the CPUs of the class limit plus one, and the memory of the limit: `cpus: "2"` and `memory: 4G` give a VM with 3 CPUs and about 3.9 GB. Without a limit, a VM gets 1 CPU and 2 GiB. Set `limits` and `reservations` for the VM you want ([what it costs](#what-it-costs)).

The file [`examples/linux-microvm.yml`](../examples/linux-microvm.yml) has a job for each class.

## Run Docker inside the VM

A job on `linux-microvm-docker` starts its own Docker daemon in the VM and builds with it. No socket of the node is involved. The class has `SYS_ADMIN` and no `NET_ADMIN`, and a 6 GiB tmpfs at `/var/lib/docker`, because overlayfs cannot sit on the virtiofs root of the VM. Images and the build cache live in the memory of the VM and vanish with the job.

Without `NET_ADMIN` a job cannot change the address of its container, which the [token proxy](security.md#the-token-proxy) trusts to tell runners apart. The price: start the daemon with `--bridge=none --iptables=false`, and build with `--network=host`.

The VM mounts `/sys`, `/sys/fs/cgroup`, and `/proc/sys` read-only, and the job must remount them before `dockerd` can start:

```bash
sudo mount -o remount,rw /sys
sudo mount -o remount,rw /sys/fs/cgroup
sudo mount -o remount,rw /proc/sys
sudo sh -c 'dockerd --bridge=none --iptables=false > /tmp/dockerd.log 2>&1 &'
timeout 60 sh -c 'until sudo docker info > /dev/null 2>&1; do sleep 1; done'
sudo docker build --network=host -t app .
```

- **Builds work**, and so do `docker load`, `docker save`, `docker create` with `docker cp`, and a push to a registry. Pass `--network=host` to every build, also in `docker buildx build`: a Dockerfile cannot ask for it.
- **`docker run`, Compose and service containers do not work.** Starting a container needs `NET_ADMIN` (`failed to create default sandbox: operation not permitted`, also with `--network=host` and `--network=none`). Use another class for jobs that start containers. To allow it here, add `NET_ADMIN` to `cap_add` in your copy of the stack file, keep one replica on its own overlay, and use it for trusted projects only: a job with `NET_ADMIN` can take over the address of another container.
- **The class keeps `NET_RAW`.** BuildKit starts every `RUN` step with Docker's default capabilities, and `runc` fails with `unable to apply caps` when the container dropped one. So a job can send raw packets with another source address into its overlay. One replica keeps that harmless ([Security](#security)).
- **Rootless BuildKit does not work**, because file capabilities do not survive virtiofs. A rootful `dockerd` or `buildkitd` does.

## Rolling updates

Docker removes an overlay network from a node when its last container leaves. A Kata container that starts in that gap stays in the `Created` state for good, and Swarm retries with a new task that hangs the same way. A restart after a finished job is safe (Swarm waits `delay: 10s` first). A rolling update is not: `update_config` stops the old container and starts the new one at once (`order: stop-first`).

`microvm-netkeep` closes the gap: one small VM sleeps on every microVM node, attached to both class networks, so the overlays never go away. Keep the service in your copy of the stack file. Without it, drain a node before an update, and use `docker service update --force` only when the service has a replica on another node.

## Security

- **What the VM adds.** A job that escapes its container, or abuses `SYS_ADMIN`, lands in a guest kernel and its own root filesystem, not on the node, other jobs, or the tokens of other classes. The VM shares no writable state with other jobs. It does not filter egress, and replicas of a class share an overlay network.
- **Residual risk.** A bug in virtiofs, the VMM, or the guest kernel could still reach the node, which runs `virtiofsd`, a VMM and the Kata shim for every job. Keep Kata and the node kernel current. To isolate `linux-microvm-docker` further, label nodes `machine-runner-swarm.class.linux-microvm-docker=true` ([Multi-node clusters](multi-node.md#labels-used-by-this-repository)), add `node.labels.machine-runner-swarm.class.linux-microvm-docker == true` to its constraints in your copy of the stack file, and `!= true` to those of `linux-microvm`.
- **Why one replica.** The token proxy accepts a claim from an address that Swarm lists for the class. Other classes drop `NET_RAW`, so a job cannot send packets from another address. `linux-microvm-docker` keeps it (BuildKit needs it) and has no `NET_ADMIN`, so a job there can send raw packets but cannot take over an address. With one replica on its own overlay, no other runner is there to impersonate. The stack-config test requires `replicas: 1` and `SYS_ADMIN` as the only added capability. For more builds at once, copy the service under another name and resource class, with its own network, secret and proxy entries ([Add a class](resource-classes.md#define-a-class)). Do not raise `replicas`.
- **The guard.** `SYS_ADMIN` on runc is a host escape. The label and constraints keep `linux-microvm-docker` on microVM nodes, and the entrypoint check keeps it off a node with the label but not the runtime. The stack-config test requires `MACHINE_RUNNER_SWARM_REQUIRE_MICROVM=true` on every service that adds `SYS_ADMIN`, in every stack file.

## What it costs

Measured on one `r8i-flex.2xlarge` (nested KVM), Docker 29.9, Kata 4.2.0, in Docker-in-Docker:

| Measure | runc | Cloud Hypervisor | Dragonball |
|---|---|---|---|
| Container start | 0.27 s | 1.16 s | 2.5 s |
| Swarm deploy to the first output of the container | 1.3 s | 3.4 s | not measured |

- **Memory.** `microvm-netkeep` adds one small VM (256 MB limit) to every microVM node. An idle VM with 2 GiB takes about 160 MB of host memory, and more as the job runs. The tmpfs of `linux-microvm-docker` counts against the VM memory.
- **CPU.** Compute speed equals runc. The reservation covers only the limit, not the extra CPU.
- **Disk.** virtiofs makes `fsync` about twice as slow as on the node's disk. A tmpfs avoids it.
- **Start-up.** A job waits about a second longer for the container, plus a few seconds for the runner download.

Dragonball, the built-in VMM of runtime-rs, works with the same steps but starts more slowly, so the docs use Cloud Hypervisor.

## What is tested

`linux/tests/microvm.sh` runs two Docker-in-Docker nodes with KVM, the real stack files `runners.yaml` and `microvm.yaml`, the real entrypoint, a distributor on the runc node, a test mirror that serves the runner, the token proxy image built from `proxy/`, and the real runner against a fake API. It skips when `/dev/kvm` is missing. It checks:

- Placement: the classes stay pending until a node has the label, and the Kata node has no `runner-bin` volume.
- Isolation: the guest kernel differs from the node kernel, `/proc/cmdline` names `kata-containers`, and `/etc/resolv.conf` is the read-only node file.
- DNS: public names, `token-proxy`, and service names resolve through the forwarder. A control without the node file fails.
- The real runner claims through the real token proxy from inside a VM and runs a task as the job user. The class token is in no file, variable, or process of the VM.
- The runner download is verified, a root shell that rewrites the binary changes nothing for the next VM, a wrong SHA-256 is refused (exit 80), and a floating version resolves in the VM.
- A forced rolling update replaces the VM because of `microvm-netkeep`. A control without it hangs.
- `dockerd` starts with `--bridge=none --iptables=false`, uses `overlay2` on the tmpfs, and builds an image with `--network=host`. The stack-config test pins `SYS_ADMIN`, no `NET_ADMIN`, and the replica count.
- The label on a runc node makes both classes exit 80, and QEMU passes the same checks (`SWARM_TEST_KATA_VMM=qemu`).

### What is not tested

Real jobs (checkout, caches, workspaces and artifacts over virtiofs with the real task agent: a real CircleCI job is a manual check), out-of-memory behavior against the cgroup limit, other clouds, AMD CPUs, arm64, Firecracker (it has no virtiofs), the Go shim of Kata, clusters of more than two nodes, the load of many VMs, Kata upgrades under load, and Windows (next section).

## Windows: Hyper-V isolation

`isolation: hyperv` runs each Windows container in a lightweight Hyper-V utility VM with its own kernel, instead of the host kernel (`isolation: process`, the default in `windows/stack/runners.yaml`). This is untested. A stack file for it would be an add-on like this one, on a host with the Hyper-V role:

```yaml
services:
  windows-hyperv:
    # ... the settings of windows-default in windows/stack/runners.yaml
    isolation: hyperv
```

It does not need the image to match the host version, but it needs nested virtualization, which CircleCI's own Windows machines do not offer (`--isolation hyperv` fails there with "The request is not supported"). On AWS, use the instance families above, or `.metal`. Test it on your own hosts first.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| A task is rejected with `bind source path does not exist` | The node file `/etc/machine-runner-swarm/microvm-resolv.conf` is missing. [Write it](#dns) |
| The class exits with code 80 and `not in a Kata microVM` | The node has the label, and Docker runs runc. Check `docker info --format '{{.DefaultRuntime}}'` and [Configure Docker](#configure-docker), or remove the label |
| The class stays `Pending` with `no suitable node` | No node has `machine-runner-swarm.microvm=true`. [Label the node](#configure-docker) |
| A job cannot resolve names, or only some queries succeed | `microvm-dns` is not running, the config `microvm-corefile` is missing ([DNS](#dns)), a replica runs on a Kata node without the label, or another `-c` file overrides `microvm-dns` and the merge dropped its UDP port. `docker service ls` must show `*:53->53/tcp, *:53->53/udp` for `runners_microvm-dns`, and `docker service ps runners_microvm-dns` replicas on nodes without the label. Change the service in your copy of `microvm.yaml`, not in another `-c` file |
| A task stays `Starting` and its container stays `Created` after an update | The overlay left the node while the task started. Check that `microvm-netkeep` runs on the node, then `docker service update --force` the class ([Rolling updates](#rolling-updates)) |
| A class exits 80 with "cannot download and verify the runner in this microVM" | The VM could not download the runner, or its SHA-256 did not match. `docker service logs runners_linux-microvm` shows the download lines. Check [DNS](#dns), egress to `circleci-binary-releases.s3.amazonaws.com`, `MACHINE_RUNNER_SWARM_RUNNER_VERSION` and `MACHINE_RUNNER_SWARM_RUNNER_SHA256` |
| A container does not start, with `ETIMEDOUT` on vsock | `vhost_vsock` is not loaded ([Set up a microVM node](#set-up-a-microvm-node) step 1), or QEMU lacks `/dev/shm` space ([Configure Docker](#configure-docker)) |
| `dockerd` in the VM fails with `read-only file system` | The job skipped the remounts ([Run Docker inside the VM](#run-docker-inside-the-vm)) |
