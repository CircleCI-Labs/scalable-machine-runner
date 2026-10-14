---
page-title: MicroVM jobs with Kata Containers
page-audience: admin
page-description: Run each job in its own microVM with Kata Containers on labeled Linux nodes, set up the nodes, and learn what the add-on costs and what it does not cover.
---

# MicroVM jobs with Kata Containers

A container shares the kernel of its node. A [Kata Containers](https://katacontainers.io/) microVM does not: every container starts in a small virtual machine with its own Linux kernel, and a job that breaks out of its container reaches the guest, not the node. The add-on stack file `linux/stack/microvm.yaml` runs resource classes this way. It is optional, and the default classes do not change.

Use it when jobs need a boundary stronger than a container, or when a job needs privileges that are unsafe on a shared kernel. The second class, `linux-microvm-docker`, lets a job run its own Docker daemon inside its VM, so an image build needs no host Docker socket. It is a safer answer than the [docker-build class](docker-builds.md#pattern-a-the-host-docker-engine) for the same need.

> [!NOTE]
> This add-on is tested on amd64 with Kata 4.2.0, Cloud Hypervisor and QEMU, in nested virtualization on AWS, with a fake CircleCI API. Real jobs, other clouds, and arm64 are not tested. Refer to [What is tested](#what-is-tested).

## How it works

Swarm has no per-service container runtime: a service cannot ask for Kata. The Docker daemon of each node chooses the runtime, so the node decides. This add-on uses that:

- A microVM node has Kata as the `default-runtime` of its Docker daemon and the label `machine-runner-swarm.microvm=true`. Every container on it is a microVM, including containers of other stacks.
- `linux-microvm` and `linux-microvm-docker` run only on nodes with that label. Every other class in the stack files carries `node.labels.machine-runner-swarm.microvm != true`, so labeling a node moves them off it. They would run in a VM without working DNS there.
- The classes set `MACHINE_RUNNER_SWARM_REQUIRE_MICROVM=true`. The entrypoint then exits with code 80 unless `/proc/cmdline` names `kata-containers`, so a node that falls back to runc by mistake, with the label but the wrong default runtime, never runs a class that has `SYS_ADMIN`.
- Docker's embedded DNS (`127.0.0.11`) does not work inside a Kata VM. The service `microvm-dns` is a CoreDNS forwarder on a runc node, and each microVM node mounts a file that points `/etc/resolv.conf` at it. Refer to [DNS](#dns).
- The classes claim through the [token proxy](security.md#the-token-proxy), like the other single-task classes. A runner holds a placeholder config, and the class tokens are Swarm secrets of `token-proxy` alone, so a job in a VM never sees one, also in `linux-microvm-docker`. The runner finds `token-proxy` by name, and the forwarder resolves it, because it and the proxy are on the class networks. The proxy runs on a runc node, where Docker's DNS works.
- The runner comes from the per-node volume `runner-bin`, as for every class. `runner-distributor` of `runners.yaml` needs working DNS to download it, so it stays off microVM nodes, and `microvm.yaml` runs a copy of it there, `microvm-runner-distributor`, with the same node file as the classes.
- A Kata container that starts at the moment its overlay network leaves the node hangs, which is what a rolling update does. The global service `microvm-netkeep` runs one sleeping container on each microVM node, on both class networks, so the networks stay up. Refer to [Rolling updates](#rolling-updates).

| | `linux-default` | `linux-microvm` | `linux-microvm-docker` |
|---|---|---|---|
| Kernel of the job | The node kernel | Its own guest kernel | Its own guest kernel |
| Runs on | Nodes without the `microvm` and `docker-build` labels | Nodes with `microvm=true` | Nodes with `microvm=true` |
| Job user | `circleci`, with sudo | `circleci`, with sudo | `circleci`, with sudo |
| Class token in the job | No, the proxy holds it | No | No |
| Capabilities | Docker's defaults, minus `NET_RAW` and `MKNOD` | The same | Docker's defaults, plus `SYS_ADMIN` and `NET_ADMIN` |
| Docker in the job | No | No | Its own `dockerd` in the VM, on a tmpfs |

## Requirements

- **KVM.** The node needs `/dev/kvm`: bare metal, or a virtual machine with nested virtualization. A node without it cannot run Kata.
- **Linux amd64.** This add-on pins the amd64 build of Kata 4.2.0. Arm64 is untested.
- **Docker Engine 24 or later**, and a Swarm that follows [Multi-Node Clusters](multi-node.md).
- **One runc node at least** for `microvm-dns` and `token-proxy`, for example a manager. A single-node Swarm whose only node is a microVM node cannot run them. Refer to [DNS](#dns).
- **The base stack**: `runners.yaml` with its placeholder secret and the label `machine-runner-swarm.proxy=true` on the node of the proxy ([Install on Linux](install-linux.md)). Deploy `microvm.yaml` together with it.
- **A dedicated node.** The default runtime applies to every container on the node.

### Nested virtualization in the cloud

| Cloud | Instances | Notes |
|---|---|---|
| AWS | C8i, M8i, R8i (also the flex sizes), C7i, M7i, R7i (also the flex sizes), I7i, and every `.metal` size | Intel only. Enable nested virtualization when you launch the instance. The tested node was an `r8i-flex.2xlarge` |
| Google Cloud, Azure, and others | Nested virtualization exists on some families | Untested |

CircleCI's own cloud executors do not offer nested virtualization, except the Android machine image. Refer to [CI](ci.md#linux-microvm).

## Set up a microVM node

Run these steps on every microVM node, as root. The node joined the Swarm ([Install on Linux](install-linux.md)). There is nothing to install for the runner: the distributor fills the per-node volume `runner-bin`.

1. **Check KVM and load the vhost modules.** Kata uses `vhost_vsock` to reach the agent in the VM, and `vhost_net` for networking.

   ```console
   $ ls -l /dev/kvm
   $ sudo modprobe vhost_vsock vhost_net
   $ printf 'vhost_vsock\nvhost_net\n' | sudo tee /etc/modules-load.d/kata.conf
   $ ls -l /dev/vhost-vsock /dev/vhost-net
   ```

2. **Install Kata 4.2.0.** The release tarball is about 1 GB and unpacks to `/opt/kata`, about 2.3 GB. It holds the runtime-rs shim, Cloud Hypervisor, QEMU, `virtiofsd`, a guest kernel, and a guest image. Check the SHA-256 before you unpack it.

   ```console
   $ curl -fLO https://github.com/kata-containers/kata-containers/releases/download/4.2.0/kata-static-4.2.0-amd64.tar.zst
   $ echo 'b828904fa3f1e49ddd7dc799c72cb1503cd1e772d354c3987c8d4189b2a623a8  kata-static-4.2.0-amd64.tar.zst' | sha256sum -c -
   $ sudo tar --zstd -xf kata-static-4.2.0-amd64.tar.zst -C /
   $ sudo ln -sf /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
   ```

   The tarball needs `zstd`. Upgrade by unpacking a new release the same way and restarting Docker. Existing VMs keep running on the old files until they stop.

## Configure Docker

1. **Add the runtimes to `/etc/docker/daemon.json`** and make Kata the default. Merge these keys into the file if it exists. The runtime `kata` uses Cloud Hypervisor, the default virtual machine monitor. The runtime `kata-qemu` is the fallback. The test suite runs this exact block.

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

   Restart Docker (`sudo systemctl restart docker`), then check that a container has its own kernel:

   ```console
   $ uname -r
   $ docker run --rm alpine uname -r
   ```

   The two kernels must differ. Containers that were running before the restart stay as they are.

   **QEMU as the fallback.** Set `"default-runtime": "kata-qemu"` if Cloud Hypervisor does not work on your hardware. QEMU backs the memory of every VM with `/dev/shm`, so `/dev/shm` of the node must hold the memory of all VMs together. A tmpfs that is too small fails with `kvm run failed Bad address` and a vsock timeout. On a host, `/dev/shm` is half of the RAM by default. In a Docker-in-Docker container, which is how the tests run QEMU, start it with `--shm-size=16g`.

2. **Label the node:**

   ```console
   $ docker node update --label-add machine-runner-swarm.microvm=true <node>
   ```

   Label the node before you deploy the stack, and always when Kata is its default runtime. A Kata node without the label still matches the forwarder `microvm-dns`, which cannot work in a VM, so a share of the DNS queries would fail. Labeling the node moves the forwarder off it.

## DNS

Docker's embedded DNS server, `127.0.0.11`, cannot be reached from inside a Kata VM, on an overlay or any other user-defined network. Kata has no fix for it yet. `microvm.yaml` works around it in two parts:

- **The forwarder.** The service `microvm-dns` runs CoreDNS with `forward . 127.0.0.11` on a node without the `microvm` label, where the embedded DNS works. It joins the networks of both classes, where `token-proxy` is too, so `token-proxy` and the service names such as `linux-microvm` and `tasks.linux-microvm` resolve. It is published on port 53, TCP and UDP, through the routing mesh, so every node answers on port 53.
- **The node file.** Each microVM node has a file that the stack mounts read-only at `/etc/resolv.conf` of every job and of `microvm-runner-distributor`. It names the gateway of `docker_gwbridge`, which is the node itself, and the routing mesh sends the query on to a forwarder.

1. **Write the node file**, after the node joined the Swarm (the network `docker_gwbridge` exists from then on). The gateway is `172.18.0.1` by default and differs when that range was taken, so read it from Docker:

   ```console
   $ sudo install -d /etc/machine-runner-swarm
   $ gw=$(docker network inspect docker_gwbridge --format '{{(index .IPAM.Config 0).Gateway}}')
   $ printf 'nameserver %s\n' "$gw" | sudo tee /etc/machine-runner-swarm/microvm-resolv.conf
   ```

   Without this file the task does not start (the bind mount fails), so a node that skipped this step never runs a class with broken DNS.

2. **Create the Corefile config once**, on a manager:

   ```console
   $ printf '.:53 {\n  errors\n  forward . 127.0.0.11\n  cache 30\n}\n' | docker config create microvm-corefile -
   ```

   Swarm configs are immutable. To change the Corefile, create a config under a new name and change `microvm-corefile` in your copy of the stack file.

> [!WARNING]
> The routing mesh opens port 53 on every interface of every node, so the forwarder is an open resolver for anyone who can reach the node. Keep port 53 closed to the outside with your cloud firewall or security group, and open it only between the nodes. Docker also bypasses `ufw` and `firewalld` rules for published ports, so use the `DOCKER-USER` chain when you filter on the node itself. A node that runs its own DNS server on port 53 for other hosts loses it to the routing mesh.

The forwarder needs a runc node. On a Swarm whose only node is a microVM node, replace `forward . 127.0.0.11` with `forward . 1.1.1.1` (or your resolver) and put `microvm-dns` on that node without the constraint. Public names then resolve, and service names do not.

## The runner volume

Every class mounts the per-node volume `runner-bin` read-only at `/opt/machine-runner-swarm`. Kata shares it into the VM through virtiofs. On a microVM node `microvm-runner-distributor` fills it, and the entrypoint of each container checks the runner against the SHA-256 record of the distributor before it starts it.

Root with `SYS_ADMIN` inside a VM, which is what `linux-microvm-docker` gives a job, can remount that share read-write. The write then reaches the volume on the node. The node cannot prevent it with a read-only mount, because the distributor writes the same volume. What a job in `linux-microvm-docker` can do, and what stops it:

- It can change the runner binary and the SHA-256 record. The next container of any class on that node runs the changed binary. The class tokens are not in the node's volume or in a runner, so the binary cannot read one, but it can run jobs of its class and read what they hold.
- It can change the binary only, or the record only. The entrypoint of the next container refuses to start (exit 80, "does not match its SHA-256 record"), and the distributor repairs the volume at its next check.
- It can change both, and the next container starts the changed binary. The check is not a boundary against a job that has `SYS_ADMIN`.

So give `linux-microvm-docker` nodes of its own ([Security](#security)). The changed binary then runs only in jobs of that class. The test `microvm.sh` shows all three cases.

## Deploy the classes

1. Create the resource classes `<namespace>/linux-microvm` and `<namespace>/linux-microvm-docker`, and for each the secret `linux-microvm-token` and `linux-microvm-docker-token`, which holds the class token and goes to `token-proxy` only ([Resource Classes](resource-classes.md#define-a-class)). Delete a class from your copy of the stack file together with its secret and network if you do not want it.
2. Deploy the add-on stack file with the main file. Pass the same list of files on every later deploy ([why](concepts.md#add-on-stack-files-and-how-they-merge)).

   ```console
   $ docker stack deploy -c linux/stack/runners.yaml -c linux/stack/microvm.yaml runners
   ```

The classes look like `linux-default` and run the same entrypoint. A VM has the CPUs of the class limit plus one, and the memory of the limit: a class with `cpus: "2"` and `memory: 4G` gets a VM that shows 3 CPUs and about 3.9 GB. A container without a limit gets 1 CPU and 2 GiB. Set `limits` and `reservations` for the VM you want ([what it costs](#what-it-costs)).

The file [`examples/linux-microvm.yml`](../examples/linux-microvm.yml) has a job for each class.

## Run Docker inside the VM

A job on `linux-microvm-docker` starts its own Docker daemon in the VM and builds with it. No socket of the node is involved, so the job cannot reach other jobs or the node. The class has `SYS_ADMIN` and `NET_ADMIN`, and a 6 GiB tmpfs at `/var/lib/docker`, because overlayfs cannot sit on the virtiofs root of the VM. Images and the build cache therefore live in the memory of the VM and vanish with the job.

The VM mounts `/sys`, `/sys/fs/cgroup`, and `/proc/sys` read-only, and the job must remount them before `dockerd` can start containers:

```console
$ sudo mount -o remount,rw /sys
$ sudo mount -o remount,rw /sys/fs/cgroup
$ sudo mount -o remount,rw /proc/sys
$ sudo sh -c 'dockerd > /tmp/dockerd.log 2>&1 &'
$ timeout 60 sh -c 'until sudo docker info > /dev/null 2>&1; do sleep 1; done'
$ sudo docker build -t app .
```

Rootless BuildKit does not work in the VM, because file capabilities do not survive virtiofs, and a rootful `dockerd` or `buildkitd` does. The class drops no capability: the containers that `dockerd` starts get Docker's default set, and `runc` fails with `unable to apply caps` when the VM container lacks one of them, such as `NET_RAW` or `MKNOD`. The guest kernel has no seccomp profile around the job, so the VM, not the container, is the boundary.

## Rolling updates

Docker removes an overlay network from a node when its last container leaves, and sets it up again for the next one. A Kata container that starts in that gap stays in the `Created` state for good, and Swarm tries again with a new task that hangs the same way. A restart after a finished job is safe, because Swarm waits `delay: 10s` first. A rolling update is not: `update_config` stops the old container and starts the new one at once (`order: stop-first`).

The service `microvm-netkeep` closes the gap. It is global, so one small VM sleeps on every microVM node, attached to both class networks, and the overlays never go away while the node runs. The test replaces a running container with a forced update, and a control without the keeper shows the hang. Keep the service in your copy of the stack file. Without it, drain a node before an update and use `docker service update --force` only when the service has a replica on another node.

## Security

- **What the VM adds.** A job that escapes its container, or abuses `SYS_ADMIN`, lands in a guest kernel and its own root filesystem. It does not reach the node, other jobs, or other classes' tokens, except through what the node shares: the runner volume ([above](#the-runner-volume)), and the network.
- **What it does not add.** The VM does not filter egress, and replicas of a class still share an overlay network. The job holds no class token: its runner has the placeholder, and the proxy adds the token of the class to the claim of each container once.
- **Dedicated nodes for `linux-microvm-docker`.** A job with `SYS_ADMIN` can remount every shared mount of its VM read-write, among them the runner volume, and a bug in virtiofs, the VMM, or the guest kernel could still reach the node. Give the class nodes of its own. Label them `machine-runner-swarm.class.linux-microvm-docker=true`, as [Multi-Node Clusters](multi-node.md#labels-used-by-this-repository) describes, add `node.labels.machine-runner-swarm.class.linux-microvm-docker == true` to the constraints of `linux-microvm-docker` in your copy of the stack file, and `!= true` to those of `linux-microvm`.
- **Tampering with the runner.** A privileged sibling that can write the runner volume can change the binary and its SHA-256 record together ([above](#the-runner-volume)). The check at the start of a container makes a change of one of them visible, and it does not stop a change of both. The dedicated nodes are the control.
- **The guard.** `linux-microvm-docker` adds `SYS_ADMIN`. On runc that is a host escape. The label and the constraints keep the class on microVM nodes, and the entrypoint check keeps it off a node that has the label but not the runtime. The stack-config test requires `MACHINE_RUNNER_SWARM_REQUIRE_MICROVM=true` on every service that adds `SYS_ADMIN`, in every stack file.
- **A bigger attack surface under it.** The node now runs `virtiofsd`, a VMM, and the Kata shim for every job. Keep Kata and the node kernel current.

## What it costs

Measured on one `r8i-flex.2xlarge` (nested KVM), Docker 29.9, Kata 4.2.0, in a Docker-in-Docker container:

| Measure | runc | Cloud Hypervisor | Dragonball |
|---|---|---|---|
| Container start | 0.27 s | 1.16 s | 2.5 s |
| Swarm deploy to the first output of the container | 1.3 s | 3.4 s | not measured |

- **Memory.** `microvm-netkeep` and `microvm-runner-distributor` add one small VM each (256 MB limit) to every microVM node. An idle VM with 2 GiB takes about 160 MB of host memory, and the guest kernel and its page cache use more as the job runs. A VM has the memory of the class limit, and the tmpfs of `linux-microvm-docker` counts against it.
- **CPU.** Compute speed equals runc. A VM has the CPUs of the limit plus one, and the reservation of the class still covers only the limit.
- **Disk.** virtiofs makes `fsync` about twice as slow as on the node's disk. Builds and test runs that write many small files with `fsync` feel it. A tmpfs avoids it.
- **Start-up.** A job in a new container waits about a second longer, which is small against the time the runner needs to claim a job.

Dragonball is the built-in VMM of runtime-rs and works with the same steps. It starts more slowly than Cloud Hypervisor, so the docs use Cloud Hypervisor.

## What is tested

`linux/tests/microvm.sh` runs two Docker-in-Docker nodes with KVM, the real stack files `runners.yaml` and `microvm.yaml`, the real entrypoint, a distributor that installs the runner and the token proxy from a test mirror, and the real runner against a fake API. It skips when `/dev/kvm` is missing. It checks:

- The classes stay pending until a node has the label. The forwarder and the proxy run on the runc node, and the distributor of `microvm.yaml` runs on the Kata node only, as the one of `runners.yaml` runs on the runc node only.
- The guest kernel differs from the node kernel, `/proc/cmdline` names `kata-containers`, and `/etc/resolv.conf` is the node file and read-only.
- Public names, `token-proxy`, the service name, and `tasks.<service>` resolve through the forwarder. A control service without the node file shows the failure that the forwarder fixes.
- The real runner claims through the real token proxy from inside a VM and runs a task as the job user. The class token is in no file, variable, or process of the VM.
- The runner volume: a root shell in the VM remounts it read-write and writes the volume of the node (the control). A changed binary is refused at the next start, and a changed binary with a changed record is not.
- A forced rolling update of a class replaces its VM, because `microvm-netkeep` holds the overlay. A control without it shows the hang.
- `dockerd` starts in the VM, uses `overlay2` on the tmpfs, builds an image, and runs it.
- The guard: the label on a runc node makes both classes exit 80.
- QEMU passes the same checks (`SWARM_TEST_KATA_VMM=qemu`).

### What is not tested

- Real jobs: checkout, caches, workspaces, and artifacts over virtiofs with the real task agent. The real runner runs only an empty task in the suite. A real CircleCI job is a manual check.
- The behavior when a job runs out of memory against the cgroup limit.
- Other clouds, other CPUs (AMD), and arm64.
- Firecracker (it has no virtiofs), and the Go shim of Kata.
- A cluster with more than two nodes, and the load of many VMs at once.
- Kata upgrades under load.
- Windows: refer to the next section.

## Windows: Hyper-V isolation

Windows containers have a counterpart: `isolation: hyperv` runs each container in a lightweight Hyper-V utility VM with its own kernel, instead of sharing the host kernel (`isolation: process`, the default in `windows/stack/runners.yaml`). This is untested. A stack file for it would be an add-on like this, with the host needing the Hyper-V role:

```yaml
services:
  windows-hyperv:
    # ... the settings of windows-default in windows/stack/runners.yaml
    isolation: hyperv
```

Hyper-V isolation does not need the image to match the host version, so a node label for the image tag matters less.

It needs nested virtualization, and CircleCI's own Windows machines do not offer it: on them `--isolation hyperv` fails with "The request is not supported", and installing the Hyper-V role fails with "processor does not have required virtualization capabilities". Process isolation works there. On AWS, Windows runs on the instance families above (C7i, M7i, R7i, C8i, M8i, R8i, I7i with nested virtualization enabled, or `.metal`). Test it on your own hosts before you rely on it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| A task is rejected with `bind source path does not exist` | The node file `/etc/machine-runner-swarm/microvm-resolv.conf` is missing | [Write the node file](#dns) |
| The class exits with code 80 and `not in a Kata microVM` | The node has the label, and Docker runs runc | Check `docker info --format '{{.DefaultRuntime}}'` and [Configure Docker](#configure-docker), or remove the label |
| The class stays `Pending` with `no suitable node` | No node has `machine-runner-swarm.microvm=true` | [Label the node](#configure-docker) |
| A job cannot resolve names, or only some queries succeed | `microvm-dns` is not running, the config `microvm-corefile` is missing, a replica runs on a Kata node without the label, or another `-c` file overrides `microvm-dns` and the merge dropped its UDP port | `docker service ls` must show `*:53->53/tcp, *:53->53/udp` for `runners_microvm-dns`, and `docker service ps runners_microvm-dns` the replicas on nodes without the label. Check the [Corefile config](#dns). Change the service in your copy of `microvm.yaml`, not in another `-c` file |
| A task stays `Starting` and its container stays `Created` after an update | The overlay left the node while the task started | [Rolling updates](#rolling-updates). Check that `microvm-netkeep` runs on the node, then `docker service update --force` the class again |
| A class exits 80 with "waiting for the runner-distributor" or "has not installed the runner" | `microvm-runner-distributor` did not install the runner on this node: no node file, or no route to the download | `docker service ps runners_microvm-runner-distributor`, its logs, and [DNS](#dns) |
| A container does not start, with `ETIMEDOUT` on vsock | `vhost_vsock` is not loaded, or QEMU lacks `/dev/shm` space | [Set up a microVM node](#set-up-a-microvm-node) step 1, and the QEMU note in [Configure Docker](#configure-docker) |
| `dockerd` in the VM fails with `read-only file system` | The job skipped the remounts | [Run Docker inside the VM](#run-docker-inside-the-vm) |
