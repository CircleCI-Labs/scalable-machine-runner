#!/usr/bin/env bash
# microvm.sh: the microvm.yaml add-on stack file with Kata Containers microVMs. Token-free. SKIPPED (exit 0) without /dev/kvm.
#
# Two Swarm nodes inside privileged docker:dind containers, both with /dev/kvm, /dev/vhost-vsock and /dev/vhost-net:
#   manager  runc is the default runtime; it runs the DNS forwarder (microvm-dns)
#   worker   Kata (Cloud Hypervisor, runtime-rs) is the default runtime, labelled machine-runner-swarm.microvm=true
# The daemon.json of the worker is the JSON block of docs/microvm.md, so the docs are tested too. The REAL stack files runners.yaml
# and microvm.yaml are deployed, the runner reaches the runc node through its distributor, and each microVM downloads its
# own runner, both from a test mirror (the token proxy is the image built from proxy/). Checks:
#   1. placement      the microVM classes stay pending until a node has the label; the Kata node runs no distributor and has no runner volume, the
#                     forwarder runs on runc
#   2. in the VM      the guest kernel is not the host's, /proc/cmdline names kata-containers, no class token is in the VM, public and service DNS
#                     work through the forwarder (a plain Kata service shows the problem it fixes), /etc/resolv.conf is read-only, the VM's size,
#                     and a rolling update replaces a VM (microvm-netkeep)
#   3. the proxy      the real runner claims through the real token proxy from a VM, and the API sees the class token that the proxy added
#   4. dockerd in VM  a job starts dockerd in its VM (remounts, tmpfs data-root), builds an image (no container is started: no NET_ADMIN, no bridge), no host socket. Then the
#                     runner: it was downloaded into the VM, there is no shared volume to write, a guest with SYS_ADMIN that rewrites its own copy
#                     (binary and record) changes nothing for the next VM, which downloads a fresh one; a download that does not match the SHA-256
#                     is refused (exit 80); a floating version resolves in the VM
#   5. the guard      a node labelled microvm that runs runc makes both classes exit 80
#   6. a control      without microvm-netkeep a rolling update hangs (informational)
#
# Usage: microvm.sh
# Env:   SWARM_TEST_KATA_DIR      an extracted Kata tree (the opt/kata directory of the tarball); default: download and extract the
#                                 pinned release into the cache (SWARM_TEST_KATA_TARBALL: use this tarball instead of downloading)
#        SWARM_TEST_KATA_VMM      clh (default) or qemu: the default runtime of the worker (QEMU backs guest memory with /dev/shm, so the
#                                 DinD containers get --shm-size=16g)
#        SWARM_TEST_REQUIRE_KVM=1 a missing /dev/kvm (or vhost device) fails instead of skipping (CI)
#        TIMEOUT=180
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TIMEOUT=${TIMEOUT:-180}
VMM=${SWARM_TEST_KATA_VMM:-clh}
# The pinned Kata release (docs/microvm.md): the runtime-rs build, with Cloud Hypervisor and QEMU.
KATA_VERSION=4.2.0
KATA_SHA256=b828904fa3f1e49ddd7dc799c72cb1503cd1e772d354c3987c8d4189b2a623a8
KATA_URL=https://github.com/kata-containers/kata-containers/releases/download/$KATA_VERSION/kata-static-$KATA_VERSION-amd64.tar.zst

skip() {
  if [[ ${SWARM_TEST_REQUIRE_KVM:-} == 1 ]]; then fail "$* (SWARM_TEST_REQUIRE_KVM=1)"; fi
  echo "SKIP: $*"
  exit 0
}
[[ $(uname -m) == x86_64 ]] || skip "the pinned Kata build is amd64 only (this is $(uname -m))"
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || skip "no usable /dev/kvm (needs bare metal or nested virtualization)"
for dev in /dev/vhost-vsock /dev/vhost-net; do
  [[ -c $dev ]] || sudo -n modprobe "vhost_${dev#/dev/vhost-}" >/dev/null 2>&1 || true
  [[ -c $dev ]] || skip "no $dev (modprobe vhost_vsock vhost_net)"
done
case $VMM in clh | qemu) ;; *) fail "SWARM_TEST_KATA_VMM must be clh or qemu" ;; esac

# ---------------------------------------------------------------------------------------------
# Kata on the test host, and the nodes
# ---------------------------------------------------------------------------------------------
kata_tree() { # prints the opt/kata directory
  local dir=$cache_dir/kata-$KATA_VERSION tarball=${SWARM_TEST_KATA_TARBALL:-}
  if [[ -n ${SWARM_TEST_KATA_DIR:-} ]]; then
    echo "$SWARM_TEST_KATA_DIR"
    return
  fi
  if [[ ! -x $dir/opt/kata/runtime-rs/bin/containerd-shim-kata-v2 ]]; then
    command -v zstd >/dev/null || fail "zstd is needed to unpack the Kata tarball"
    if [[ -z $tarball ]]; then
      tarball=$cache_dir/kata-static-$KATA_VERSION-amd64.tar.zst
      if [[ ! -f $tarball ]]; then
        log "downloading $KATA_URL (about 1 GB)"
        mkdir -p "$cache_dir"
        curl -fsSL -o "$tarball.part" "$KATA_URL" && mv "$tarball.part" "$tarball"
      fi
    fi
    echo "$KATA_SHA256  $tarball" | sha256sum -c --quiet - >&2 || fail "the Kata tarball does not match the pinned SHA-256"
    log "unpacking Kata $KATA_VERSION into $dir"
    mkdir -p "$dir"
    tar --zstd -xf "$tarball" -C "$dir"
  fi
  echo "$dir/opt/kata"
}

# The first json block under "## Configure Docker" in docs/microvm.md (it sits in a list item, so it is indented), with the default
# runtime swapped for QEMU if asked.
docs_daemon_json() {
  local json
  json=$(awk '/^## Configure Docker/ { f = 1; next } f && /^ *```json/ { j = 1; next } j && /^ *```/ { exit } j' "$repo_dir/docs/microvm.md")
  if [[ -z $json ]]; then
    echo "FAIL: docs/microvm.md has no json block under '## Configure Docker'" >&2
    exit 1
  fi
  if [[ $VMM == qemu ]]; then sed 's/"default-runtime": "kata"/"default-runtime": "kata-qemu"/' <<< "$json"; else echo "$json"; fi
}

work=$(mktemp -d)
trap 'dind_stop_all; rm -rf "$work"' EXIT
kata=$(kata_tree)
[[ -x $kata/runtime-rs/bin/containerd-shim-kata-v2 ]] || fail "$kata has no runtime-rs/bin/containerd-shim-kata-v2 (is it the opt/kata directory of the static tarball?)"
docs_daemon_json > "$work/daemon.json"
grep -q '"default-runtime"' "$work/daemon.json" || fail "the daemon.json of the docs sets no default-runtime"
cat > "$work/entry.sh" <<'EOF'
#!/bin/sh
# the node setup of docs/microvm.md: the shim on PATH, then Docker
ln -sf /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
exec dockerd-entrypoint.sh "$@"
EOF
chmod 0755 "$work/entry.sh" "$work"
chmod 0644 "$work/daemon.json"

id=$$
net=smr-mv-net-$id
MGR=smr-mv-mgr-$id
KN=smr-mv-kata-$id   # the Kata node
docker network create "$net" > /dev/null
dind_networks+=("$net")
dind_start "$MGR" "$net"
docker rm -f -v "$KN" > /dev/null 2>&1 || true
docker run -d --privileged --name "$KN" --hostname "$KN" --network "$net" -e DOCKER_TLS_CERTDIR= --shm-size=16g \
  --device /dev/kvm --device /dev/vhost-vsock --device /dev/vhost-net \
  -v "$kata:/opt/kata:ro" -v "$work/daemon.json:/etc/docker/daemon.json:ro" -v "$work/entry.sh:/entry.sh:ro" \
  --entrypoint /entry.sh "$DIND_IMAGE" > /dev/null
dind_containers+=("$KN")
wait_for 90 idocker "$KN" info > /dev/null 2>&1 || fail "the engine in $KN did not start"
[[ $(idocker "$KN" info --format '{{.DefaultRuntime}}') == kata* ]] || fail "$KN does not default to a kata runtime"
SWARM_TEST_MGR=$MGR   # for the helpers of lib.sh (the mirror runs on the manager)
DIAG_NODES="$MGR"

mgr_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$MGR")
idocker "$MGR" swarm init --advertise-addr "$mgr_ip" > /dev/null
idocker "$KN" swarm join --token "$(idocker "$MGR" swarm join-token -q worker)" "$mgr_ip:2377" > /dev/null
idocker "$MGR" swarm update --task-history-limit 20 > /dev/null
COREDNS_IMAGE=$(sed -n 's/^    image: \(coredns\/coredns:[^ ]*\).*/\1/p' "$stack_dir/microvm.yaml")
DIST_IMAGE=$(sed -n 's/^    image: \(alpine:3@sha256:[0-9a-f]*\).*/\1/p' "$stack_dir/runners.yaml")
proxy_image_build   # the token proxy of the stack is an image: lib.sh builds it from proxy/ ($PROXY_IMAGE)
for n in "$MGR" "$KN"; do dind_load "$n" "$CIMG_IMAGE"; done
dind_load "$MGR" "$DIST_IMAGE"   # the distributor runs on the runc node only: a microVM downloads its own runner
dind_load "$MGR" "$COREDNS_IMAGE"
dind_load "$MGR" "$PROXY_IMAGE"
host_kernel=$(docker exec "$KN" uname -r)

# Node setup, as docs/microvm.md says: the node file with the gateway of docker_gwbridge, on both nodes (the manager needs it for the guard test).
node_resolv() { # NODE
  docker exec "$1" sh -c 'install -d /etc/machine-runner-swarm &&
    gw=$(docker network inspect docker_gwbridge --format "{{(index .IPAM.Config 0).Gateway}}") &&
    printf "nameserver %s\n" "$gw" > /etc/machine-runner-swarm/microvm-resolv.conf && cat /etc/machine-runner-swarm/microvm-resolv.conf'
}
node_resolv "$MGR" > /dev/null
gw=$(node_resolv "$KN" | awk '{ print $2 }')
[[ $gw =~ ^[0-9.]+$ ]] || fail "could not read the gateway of docker_gwbridge on $KN"

# The runner comes from the test mirror through the distributors, as in production: a fake runner that runs a job through the
# real entrypoint and keeps it up (1.0.0), and the real runner (for the real-runner part). The token proxy is the image built from proxy/.
publish_runner fake 1.0.0 > /dev/null
publish_runner real > /dev/null
FAKE_VERSION=1.0.0
docker cp "$tests_dir/fake-api.py" "$MGR:/fake-api.py"
api_ip=$(docker exec "$MGR" hostname -i | awk '{ print $1 }')
MICROVM_SERVICES=(linux-microvm linux-microvm-docker)
TOKEN_CLASS=CLASS-TOKEN-MICROVM-5e9c1d7a3b2f4086   # made up; only the proxy's secret holds it
PLACEHOLDER=machine-runner-swarm-placeholder
ZEROS=0000000000000000000000000000000000000000000000000000000000000000
BUILD_BASE=busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e   # the base image of the build in the docker class

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
# phase_begin: a clean Swarm with the secrets and the Corefile config of the stack, and no volume on either node
phase_begin() {
  local i
  inner_reset "$MGR"
  for i in $(seq 1 60); do
    [[ -z $(idocker "$KN" ps -aq) ]] && break
    idocker "$KN" ps -aq | xargs -r docker exec -i "$KN" docker rm -f > /dev/null 2>&1 || true
    sleep 1
  done
  idocker "$KN" volume ls -q | xargs -r docker exec -i "$KN" docker volume rm > /dev/null 2>&1 || true
  create_secrets "$MGR" "$TOKEN_CLASS" "${BASE_SERVICES[@]}" "${MICROVM_SERVICES[@]}"
  idocker "$MGR" secret rm runner-placeholder-token > /dev/null
  config_yaml "$PLACEHOLDER" | idocker "$MGR" secret create runner-placeholder-token - > /dev/null
  printf '.:53 {\n  errors\n  forward . 127.0.0.11\n  cache 30\n}\n' | idocker "$MGR" config create microvm-corefile - > /dev/null
}
# phase_deploy VERSION PROXY "SPEC"...: SPEC = "service replicas [ENV=value ...]" for the two classes (an unlisted one gets 0 replicas). VERSION is the
# runner that the distributor of the runc node installs and that each microVM downloads (from the mirror). PROXY is the replicas of token-proxy: 1 points it at the fake API. The forwarder keeps its
# replicas from the stack file: a second -c file that mentions microvm-dns merges its ports by published port, and drops the UDP one.
phase_deploy() {
  local version=$1 proxy=$2 s spec specs=() given=()
  shift 2
  for s in "${MICROVM_SERVICES[@]}"; do
    for spec in "$@"; do [[ ${spec%% *} == "$s" ]] && continue 2; done
    specs+=("$s 0")
  done
  for spec in "$@"; do   # a microVM class downloads its own runner: it needs the mirror and the version (an explicit setting of the spec wins)
    case " $spec " in *" MACHINE_RUNNER_SWARM_RUNNER_VERSION="*) given+=("$spec MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=$MIRROR_URL") ;; *) given+=("$spec MACHINE_RUNNER_SWARM_RUNNER_VERSION=$version MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=$MIRROR_URL") ;; esac
    # the test mirror is plain http: an exact pin that is not the stack default needs manifest (no list) or ALLOW_HTTP; floating needs only ALLOW_HTTP
    vset=$version
    case " $spec " in *" MACHINE_RUNNER_SWARM_RUNNER_VERSION="*) vset=${spec#*MACHINE_RUNNER_SWARM_RUNNER_VERSION=}; vset=${vset%% *} ;; esac
    case " $spec " in *" MACHINE_RUNNER_SWARM_RUNNER_SHA256="*) ;;
      *)
        # floating (current, 3, 3.1): the manifest hash, no manifest= setting; an exact version gets manifest
        grep -Eqx 'current|[0-9]+|[0-9]+\.[0-9]+' <<< "$vset" || given[-1]="${given[-1]} MACHINE_RUNNER_SWARM_RUNNER_SHA256=manifest"
        ;;
    esac
    given[-1]="${given[-1]} MACHINE_RUNNER_SWARM_ALLOW_HTTP=true"
  done
  DIST_VERSION=$version
  make_override "$work/ov.yaml" "${given[@]}" "${specs[@]}" "token-proxy $proxy"
  {
    echo "services:"
    echo "  token-proxy:"
    echo "    command: [\"-upstream\", \"http://$api_ip:8099\", \"-state-dir\", \"/state\"]"
  } > "$work/mv-ov.yaml"
  EXTRA_OVERRIDES="$work/mv-ov.yaml"
  deploy_stack "$MGR" "$work/ov.yaml" runners.yaml microvm.yaml
}
label() { idocker "$MGR" node update --label-add machine-runner-swarm.microvm=true "$1" > /dev/null; }
unlabel() { idocker "$MGR" node update --label-rm machine-runner-swarm.microvm "$1" > /dev/null 2>&1 || true; }
# shellcheck disable=SC2329  # called through wait_for
running_n() { # service count
  [[ $(idocker "$MGR" service ps --filter desired-state=running --format '{{.CurrentState}}' "${STACK}_$1" | grep -c '^Running' || true) -ge $2 ]]
}
cid_on() { idocker "$1" ps -q --filter "label=com.docker.swarm.service.name=${STACK}_$2" | head -n 1; }
# shellcheck disable=SC2329  # called through wait_for
has_cid() { [[ -n $(cid_on "$1" "$2") ]]; }
# job NODE CID SCRIPT: run SCRIPT (sh) in the container as the job user
job() { docker exec -i "$1" docker exec -i -u circleci "$2" sh -c "$3"; }
# a job of the fake runner is up (it prints FAKEJOB, then sleeps)
# shellcheck disable=SC2329  # called through wait_for
job_up() { service_logs "$MGR" "$1" | grep -aq '^FAKEJOB '; }
KEEP="FAKE_JOB_SLEEP=3000"   # the fake runner's job sleeps, so the container stays for the checks

# ---------------------------------------------------------------------------------------------
# 1. placement: the microVM classes need the label, and each node has the distributor that works there
# ---------------------------------------------------------------------------------------------
phase_begin
# The Kata node starts drained: without the label it would still match microvm-dns (microvm != true), where Docker's DNS does not work.
# docs/microvm.md says to label a node first; the test does it the same way.
idocker "$MGR" node update --availability drain "$KN" > /dev/null
phase_deploy "$FAKE_VERSION" 0 "linux-microvm 1 $KEEP"
wait_for "$TIMEOUT" bash -c "docker exec $MGR docker service ps --no-trunc --filter desired-state=running --format '{{.CurrentState}}|{{.Error}}' ${STACK}_linux-microvm | head -n 1 | grep -q '^Pending.*no suitable node'" ||
  fail "linux-microvm did not go pending with 'no suitable node' while no node has the microvm label"
wait_for "$TIMEOUT" running_n microvm-dns 2 || fail "the DNS forwarder (microvm-dns) did not start on the manager"
wait_for "$TIMEOUT" has_cid "$MGR" runner-distributor || fail "runner-distributor did not start on the runc node"
echo "RESULT test=microvm step=placement label=absent linux-microvm=Pending microvm-dns_on=manager runner-distributor_on=manager"
label "$KN"
idocker "$MGR" node update --availability active "$KN" > /dev/null
wait_for "$TIMEOUT" has_cid "$KN" linux-microvm || fail "linux-microvm did not start on the labelled Kata node"
[[ -z $(cid_on "$KN" microvm-dns) && -n $(cid_on "$MGR" microvm-dns) ]] || fail "microvm-dns must run on the runc node only"
[[ -z $(cid_on "$KN" runner-distributor) ]] || fail "a microVM node must run no runner-distributor: its classes download their own runner"
[[ -z $(idocker "$KN" volume ls -q | grep runner-bin || true) ]] || fail "the Kata node has a runner-bin volume: no microVM class may mount a shared runner volume"
[[ -z $(idocker "$MGR" service ls -q --filter name=microvm-runner-distributor) ]] || fail "the service microvm-runner-distributor still exists"
echo "RESULT test=microvm step=placement label=present linux-microvm=Running node=kata microvm-dns_on=manager distributor_on_kata_node=none runner_volume_on_kata_node=none"

# ---------------------------------------------------------------------------------------------
# 2. in the VM (the fake runner keeps the job container up)
# ---------------------------------------------------------------------------------------------
wait_for "$TIMEOUT" job_up linux-microvm || fail "the fake job did not start in the VM: $(service_logs "$MGR" linux-microvm | tail -n 3)"
c=$(cid_on "$KN" linux-microvm)
log_line=$(service_logs "$MGR" linux-microvm | grep -a '^FAKEJOB ' | head -n 1) || true
guest_kernel=$(job "$KN" "$c" 'uname -r')
cmdline=$(job "$KN" "$c" 'cat /proc/cmdline')
echo "RESULT test=microvm step=kernel host=$host_kernel guest=$guest_kernel"
[[ $guest_kernel != "$host_kernel" ]] || fail "the container sees the host kernel ($host_kernel): not a VM"
[[ $cmdline == *kata-containers* ]] || fail "/proc/cmdline of the guest does not name kata-containers: $cmdline"
service_logs "$MGR" linux-microvm | grep -aq 'circleci-runner-entrypoint: runner=2000 job=circleci sudo=true' || fail "the entrypoint did not start the runner in the VM"
# the runner of this VM was downloaded into it (from the mirror here, from CircleCI's bucket in production), verified, and recorded; nothing is mounted
vm_log=$(service_logs "$MGR" linux-microvm)
[[ $vm_log == *"circleci-runner-entrypoint: downloading the runner into this microVM"* && $vm_log == *"downloading circleci-runner $FAKE_VERSION linux/"* && $vm_log == *"installed circleci-runner $FAKE_VERSION"* ]] ||
  fail "the entrypoint did not download the runner into the VM: $(tail -n 5 <<< "$vm_log")"
mounted=$(job "$KN" "$c" 'grep -c " /opt/machine-runner-swarm " /proc/mounts || true')
vm_record=$(job "$KN" "$c" 'cd /opt/machine-runner-swarm/current && sha256sum -c SHA256 && cat VERSION && readlink /opt/machine-runner-swarm/current')
echo "RESULT test=microvm step=runner_in_vm downloaded_into_the_vm=yes mounts_at_runner_path=$mounted record_checks=\"$(tr '\n' ' ' <<< "$vm_record")\""
[[ $mounted == 0 && $vm_record == *"bin/circleci-runner: OK"* && $vm_record == *"versions/$FAKE_VERSION"* ]] || fail "the runner in the VM is mounted, or does not match its record: $vm_record"
[[ $log_line == *"user=circleci"* && $log_line == *"sudo=yes"* ]] || fail "the job in the VM did not run as circleci with sudo: $log_line"
secrets_in_vm=$(job "$KN" "$c" 'sudo sh -c "cat /run/secrets/* 2>/dev/null; cat /proc/[0-9]*/environ 2>/dev/null" | tr "\0" "\n" | grep -c "CLASS-TOKEN" || true')
echo "RESULT test=microvm step=no_class_token class_token_strings_in_vm_secrets_and_environ=$secrets_in_vm"
[[ $secrets_in_vm == 0 ]] || fail "a class token is in the VM"

resolv=$(job "$KN" "$c" 'cat /etc/resolv.conf')
[[ $resolv == "nameserver $gw" ]] || fail "/etc/resolv.conf in the VM is '$resolv', not the node file (nameserver $gw)"
if job "$KN" "$c" 'sudo sh -c "echo x >> /etc/resolv.conf"' > /dev/null 2>&1; then fail "/etc/resolv.conf is writable in the VM"; fi
public=$(job "$KN" "$c" 'getent hosts circleci.com | head -n 1' || true)
svc=$(job "$KN" "$c" 'getent hosts linux-microvm | head -n 1' || true)
tasks=$(job "$KN" "$c" 'getent hosts tasks.linux-microvm | head -n 1' || true)
echo "RESULT test=microvm step=dns resolv=\"$resolv\" public=\"$public\" service=\"$svc\" tasks=\"$tasks\""
[[ -n $public ]] || fail "a public name does not resolve in the VM through the forwarder"
[[ -n $svc && -n $tasks ]] || fail "a Swarm service name does not resolve in the VM through the forwarder (service='$svc' tasks='$tasks')"
size=$(job "$KN" "$c" 'echo "vcpus=$(nproc) mem_mb=$(($(sed -n "s/^MemTotal: *\([0-9]*\) kB/\1/p" /proc/meminfo) / 1024))"')
echo "RESULT test=microvm step=size class_limits=cpus:2,memory:4G $size"

# The control: a Kata container on an overlay without the node file. This is the problem microvm-dns fixes. Informational, because an
# upstream fix would change it.
idocker "$MGR" network create -d overlay smr-control > /dev/null
idocker "$MGR" service create -d --name control --network smr-control --constraint node.labels.machine-runner-swarm.microvm==true \
  --entrypoint sleep "$CIMG_IMAGE" 3000 > /dev/null
for ((i = 0; i < TIMEOUT; i++)); do
  cc=$(idocker "$KN" ps -q --filter "label=com.docker.swarm.service.name=control" | head -n 1)
  [[ -n $cc ]] && break
  sleep 1
done
if [[ -n $cc ]]; then
  ctl=$(docker exec -i "$KN" docker exec -i "$cc" sh -c 'cat /etc/resolv.conf | head -n 3 | tr "\n" " "; timeout 8 getent hosts circleci.com >/dev/null 2>&1 && echo "-> resolves" || echo "-> does NOT resolve"' || true)
  echo "RESULT test=microvm step=dns_control without_the_node_file=\"$ctl\""
else
  echo "RESULT test=microvm step=dns_control without_the_node_file=\"the control service did not start\""
fi
idocker "$MGR" service rm control > /dev/null 2>&1 || true

# A rolling update stops a container and starts its replacement at once. Docker removes an overlay from a node when its last container leaves and sets
# it up again for the next one, and a Kata container that starts at that moment hangs in "Created" (see the control at the end). microvm-netkeep holds
# the overlays, so the replacement starts.
wait_for "$TIMEOUT" has_cid "$KN" microvm-netkeep || fail "microvm-netkeep did not start on the Kata node"
[[ -z $(cid_on "$MGR" microvm-netkeep) ]] || fail "microvm-netkeep must run on the microVM node only"
old=$(cid_on "$KN" linux-microvm)
idocker "$MGR" service update -d --force "${STACK}_linux-microvm" > /dev/null
wait_for "$TIMEOUT" bash -c "c=\$(docker exec $KN docker ps -q --filter label=com.docker.swarm.service.name=${STACK}_linux-microvm | head -n 1); [ -n \"\$c\" ] && [ \"\$c\" != $old ]" ||
  fail "a rolling update of linux-microvm hung: the replacement VM did not start"
echo "RESULT test=microvm step=rolling_update replacement=started netkeep=running"

# ---------------------------------------------------------------------------------------------
# 3. the real runner through the real token proxy: a claim from inside a VM
# ---------------------------------------------------------------------------------------------
phase_begin
label "$KN"
idocker "$MGR" run -d --name fake-api --network host -v /fake-api.py:/fake-api.py:ro \
  -e "CLASS_TOKENS=linux-microvm=$TOKEN_CLASS" -e "PLACEHOLDER_TOKEN=$PLACEHOLDER" -e LOG_REQUESTS=1 "$CIMG_IMAGE" python3 /fake-api.py 8099 1 > /dev/null
phase_deploy "$TEST_RUNNER_VERSION" 1 "linux-microvm 1"
for ((i = 0; i < TIMEOUT; i++)); do
  if service_logs "$MGR" linux-microvm | grep -aq '^TASK '; then break; fi
  sleep 1
done
line=$(service_logs "$MGR" linux-microvm | grep -a '^TASK ' | head -n 1) || true
echo "RESULT test=microvm step=real_runner_through_proxy $line"
[[ $line == *"user=circleci home=/home/circleci workdir=/var/opt/circleci/workdir residue=0"* ]] || fail "the real runner did not run the task as circleci in a VM: '$line'"
[[ $line == *"sudo=yes"* && $line == *"config=denied token_env=0"* ]] || fail "in the VM the task has no sudo, or can read the token: $line"
service_logs "$MGR" linux-microvm | grep -aq 'result=success' || fail "the real runner did not finish the task in the VM"
claim_log=$(idocker "$MGR" logs fake-api 2>&1 | grep -a 'REQ POST /api/v3/runner/claim' | sort | uniq -c | tr -s ' ' | tr '\n' ';')
echo "RESULT test=microvm step=proxy_claims api_saw=\"$claim_log\""
[[ $claim_log == *"auth=CLASS:linux-microvm"* ]] || fail "the claim from the VM did not reach the API with the class token (the proxy did not add it): $claim_log"
service_logs "$MGR" token-proxy | grep -aq 'claim from .* (tasks.linux-microvm): upstream status 200' || fail "the token proxy did not log a claim of linux-microvm from the VM: $(service_logs "$MGR" token-proxy | tail -n 3)"
node_of=$(idocker "$MGR" service ps --format '{{.Node}}' "${STACK}_linux-microvm" | head -n 1)
[[ $node_of == "$KN" ]] || fail "the task ran on $node_of, not on the Kata node"

# ---------------------------------------------------------------------------------------------
# 4. linux-microvm-docker: dockerd in the VM, then the runner of each VM
# ---------------------------------------------------------------------------------------------
phase_begin
label "$KN"
phase_deploy "$FAKE_VERSION" 0 "linux-microvm-docker 1 $KEEP"
wait_for "$TIMEOUT" has_cid "$KN" linux-microvm-docker || fail "linux-microvm-docker did not start in a VM"
dc=$(cid_on "$KN" linux-microvm-docker)
wait_for "$TIMEOUT" job_up linux-microvm-docker || fail "the fake job did not start in the docker class"
caps=$(job "$KN" "$dc" 'grep CapBnd /proc/self/status | cut -f2')
echo "RESULT test=microvm step=docker_class_caps bounding_set=$caps"
# SYS_ADMIN (bit 21) for dockerd's mounts, and no NET_ADMIN (bit 12): a job that can reconfigure eth0 could take over the address of another container.
# NET_RAW (bit 13) stays: BuildKit's RUN steps request it, and nested runc fails with "unable to apply caps" when the VM container has dropped it (docs/microvm.md).
bnd=$((16#$caps))
(((bnd >> 21) & 1)) || fail "linux-microvm-docker lacks SYS_ADMIN (bounding set $caps)"
(((bnd >> 12) & 1)) && fail "linux-microvm-docker has NET_ADMIN (bounding set $caps)"

# dockerd in the VM: the job's steps (docs/microvm.md)
# the base image of the build: pinned by digest, pulled on this host when it is missing (the CI machine has none), and loaded into the VM under a local tag
docker image inspect "$BUILD_BASE" > /dev/null 2>&1 || docker pull -q "$BUILD_BASE" > /dev/null
docker tag "$BUILD_BASE" smr-test/build-base:1
docker save smr-test/build-base:1 | docker exec -i "$KN" docker exec -i "$dc" sh -c 'cat > /tmp/build-base.tar'
cat > "$work/build.sh" <<'SH'
set -eu
sudo mount -o remount,rw /sys
sudo mount -o remount,rw /sys/fs/cgroup
sudo mount -o remount,rw /proc/sys
sudo sh -c 'dockerd --bridge=none --iptables=false > /tmp/dockerd.log 2>&1 &'
i=0
until sudo docker info > /dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 60 ] && { tail -n 30 /tmp/dockerd.log; echo "dockerd did not start"; exit 1; }
  sleep 1
done
echo "driver=$(sudo docker info --format '{{.Driver}}') data_root_fs=$(stat -f -c %T /var/lib/docker)"
sudo docker load -q -i /tmp/build-base.tar > /dev/null
mkdir -p /tmp/b && cd /tmp/b
printf 'FROM smr-test/build-base:1\nRUN echo "built in $(uname -r)" > /built\nCMD ["cat", "/built"]\n' > Dockerfile
# no NET_ADMIN, no bridge: the build steps share the network of the VM container, and the result is read without starting a container
sudo docker build --network=host -q -t built . > /dev/null
c=$(sudo docker create built)
echo "build=ok built=$(sudo docker cp "$c:/built" - | tar -xO)"
sudo docker rm "$c" > /dev/null
SH
docker exec -i "$KN" docker exec -i "$dc" sh -c 'cat > /tmp/build.sh' < "$work/build.sh"
out=$(job "$KN" "$dc" 'sh /tmp/build.sh 2>&1') || fail "dockerd in the VM: $out"
echo "RESULT test=microvm step=dockerd_in_vm $(tr '\n' ' ' <<< "$out")"
[[ $out == *"driver=overlay2 data_root_fs=tmpfs"* ]] || fail "dockerd in the VM does not use overlay2 on a tmpfs data-root: $out"
[[ $out == *"build=ok built=built in $guest_kernel"* ]] || fail "the image build or run in the VM failed, or ran on another kernel: $out"

# The runner is the container's own copy: there is no shared volume to remount, so root with SYS_ADMIN in the VM can rewrite its own binary and its record and
# nothing else. The change dies with the VM: the next container downloads a fresh runner.
rec_before=$(job "$KN" "$dc" 'cat /opt/machine-runner-swarm/current/SHA256')
old_dc=$dc
job "$KN" "$dc" 'cd /opt/machine-runner-swarm/current && sudo sed -i "2i echo CHANGED-BINARY-RAN" bin/circleci-runner && sha256sum bin/circleci-runner | sudo tee SHA256 > /dev/null'
[[ $(job "$KN" "$dc" 'cat /opt/machine-runner-swarm/current/SHA256') != "$rec_before" ]] || fail "the guest could not rewrite its own copy of the runner: the check is wrong"
[[ -z $(idocker "$KN" volume ls -q | grep runner-bin || true) ]] || fail "a runner-bin volume exists on the Kata node: a guest could write it"
idocker "$MGR" service update -d --force "${STACK}_linux-microvm-docker" > /dev/null
wait_for "$TIMEOUT" bash -c "c=\$(docker exec $KN docker ps -q --filter label=com.docker.swarm.service.name=${STACK}_linux-microvm-docker | head -n 1); [ -n \"\$c\" ] && [ \"\$c\" != $old_dc ] && docker exec $KN docker exec \$c test -L /opt/machine-runner-swarm/current" ||
  fail "the replacement VM of linux-microvm-docker did not get a runner"
dc=$(cid_on "$KN" linux-microvm-docker)
rec_after=$(job "$KN" "$dc" 'cat /opt/machine-runner-swarm/current/SHA256')
changed=$(job "$KN" "$dc" 'grep -c CHANGED-BINARY-RAN /opt/machine-runner-swarm/current/bin/circleci-runner || true')
echo "RESULT test=microvm step=runner_per_job changed_runner_in_the_old_vm=yes next_vm_record_is_a_fresh_download=$([[ $rec_after == "$rec_before" ]] && echo yes || echo NO) changed_binary_in_the_next_vm=$changed shared_volume=none"
[[ $rec_after == "$rec_before" && $changed == 0 ]] || fail "the next VM got the changed runner of the old one (record $rec_after, expected $rec_before; $changed changed lines)"
service_logs "$MGR" linux-microvm-docker | grep -aq CHANGED-BINARY-RAN && fail "the changed runner of the old VM ran in the next one"

# ---------------------------------------------------------------------------------------------
# 4b. the download is verified, and a floating version resolves in the VM
# ---------------------------------------------------------------------------------------------
phase_begin
label "$KN"
phase_deploy "$FAKE_VERSION" 0 "linux-microvm 1 MACHINE_RUNNER_SWARM_RUNNER_SHA256=$ZEROS"
for ((i = 0; i < TIMEOUT; i++)); do
  n=$(idocker "$MGR" service ps --no-trunc --format '{{.Error}}' "${STACK}_linux-microvm" | grep -c 'non-zero exit (80)' || true)
  [[ $n -ge 1 ]] && break
  sleep 1
done
mm_log=$(service_logs "$MGR" linux-microvm)
echo "RESULT test=microvm step=sha256_mismatch exit80_tasks=$n message=\"$(grep -a 'SHA-256 mismatch' <<< "$mm_log" | head -n 1 | cut -c1-110)\""
[[ $n -ge 1 && $mm_log == *"SHA-256 mismatch for circleci-runner_linux_"* && $mm_log == *"refusing to install"* ]] || fail "a runner download that does not match the SHA-256 was not refused in the VM: $(tail -n 4 <<< "$mm_log")"
[[ $mm_log != *"circleci-runner-entrypoint: runner=2000"* ]] || fail "the runner started although its SHA-256 did not match"
phase_deploy 1 0 "linux-microvm 1 $KEEP"   # 1 is floating: the newest 1.x.y of the manifest
wait_for "$TIMEOUT" job_up linux-microvm || fail "the floating version 1 did not start a job in the VM: $(service_logs "$MGR" linux-microvm | tail -n 4)"
fl_log=$(service_logs "$MGR" linux-microvm)
echo "RESULT test=microvm step=floating_version_in_vm want=1 resolved_to=$FAKE_VERSION"
[[ $fl_log == *"installed circleci-runner $FAKE_VERSION"* ]] || fail "the floating version 1 did not resolve to $FAKE_VERSION in the VM: $(tail -n 4 <<< "$fl_log")"

# ---------------------------------------------------------------------------------------------
# 5. the guard: a node that has the label but runs runc
# ---------------------------------------------------------------------------------------------
phase_begin
unlabel "$KN"
idocker "$MGR" node update --availability drain "$KN" > /dev/null   # an unlabelled Kata node would match microvm-dns
label "$MGR"   # the manager runs runc, and has the node file
phase_deploy "$FAKE_VERSION" 0 "linux-microvm 1" "linux-microvm-docker 1"
for ((i = 0; i < TIMEOUT; i++)); do
  n=$(idocker "$MGR" service ps --no-trunc --format '{{.Error}}' "${STACK}_linux-microvm-docker" | grep -c 'non-zero exit (80)' || true)
  m=$(idocker "$MGR" service ps --no-trunc --format '{{.Error}}' "${STACK}_linux-microvm" | grep -c 'non-zero exit (80)' || true)
  [[ $n -ge 1 && $m -ge 1 ]] && break
  sleep 1
done
msg=$(service_logs "$MGR" linux-microvm-docker | grep -a 'circleci-runner-entrypoint: error' | head -n 1 | cut -c1-200)
echo "RESULT test=microvm step=guard node=runc exit80_linux-microvm=$m exit80_linux-microvm-docker=$n message=\"$msg\""
[[ $n -ge 1 && $m -ge 1 ]] || fail "a microVM class on a runc node did not exit 80"
[[ $msg == *"not in a Kata microVM"* ]] || fail "the guard message is missing: $msg"
service_logs "$MGR" linux-microvm-docker | grep -aq 'circleci-runner-entrypoint: runner=2000' && fail "the runner started on a runc node"

# The control for microvm-netkeep, last because it leaves a container that hangs. Informational: an upstream fix would change it. A service on its own
# overlay, which nothing else holds, gets a rolling update.
unlabel "$MGR"
label "$KN"
idocker "$MGR" node update --availability active "$KN" > /dev/null
idocker "$MGR" network create -d overlay smr-race > /dev/null
idocker "$MGR" service create -d --name race --network smr-race --constraint node.labels.machine-runner-swarm.microvm==true \
  --entrypoint sleep "$CIMG_IMAGE" 3000 > /dev/null
for ((i = 0; i < TIMEOUT; i++)); do
  first=$(idocker "$KN" ps -q --filter "label=com.docker.swarm.service.name=race" | head -n 1)
  [[ -n $first ]] && break
  sleep 1
done
idocker "$MGR" service update -d --force race > /dev/null
second=
for ((i = 0; i < 45; i++)); do
  second=$(idocker "$KN" ps -q --filter "label=com.docker.swarm.service.name=race" | grep -v "^${first:-none}" | head -n 1 || true)
  [[ -n $second ]] && break
  sleep 1
done
if [[ -n $second ]]; then outcome="the replacement started: the race is gone, microvm-netkeep may not be needed"; else outcome="the replacement HUNG for 45 s, as without microvm-netkeep"; fi
echo "RESULT test=microvm step=netkeep_control rolling_update_without_netkeep=\"$outcome\""

pass "the microVM classes run only on labelled nodes, and a microVM node runs no distributor and has no runner volume; jobs run in a Kata VM (guest kernel $guest_kernel, host $host_kernel) with working public, service and token-proxy DNS; each VM downloads and verifies its own runner (a wrong SHA-256 exits 80, a floating version resolves), so a SYS_ADMIN guest that rewrites its runner changes nothing for the next job; the real runner claims through the real proxy from a VM; the class token never reaches the VM; dockerd builds inside the VM; a rolling update works; the entrypoint exits 80 on runc"
