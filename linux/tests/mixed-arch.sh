#!/usr/bin/env bash
# mixed-arch.sh: one Swarm of two CPU architectures. The real linux/stack/runners.yaml on an amd64 manager and an arm64 worker.
# Token-free. The manager is a stock docker:dind container. The worker is docker:dind for linux/arm64 under QEMU user-mode emulation
# (the host needs the qemu-aarch64 binfmt handler, which this script registers when it is missing, and skips when it cannot).
#
# Checks, each on the nodes of both architectures:
#   1. install     the runner-distributor runs on both nodes and installs the runner of the node's OWN architecture: the real
#                  circleci-runner of the release, an x86-64 ELF on the amd64 node and an AArch64 ELF on the arm64 node, root-owned,
#                  matching the tarball of its architecture. The real runner prints its version in a stock cimg container on each
#                  node (emulated on the arm64 node)
#   2. sha256      each node's tarball hash is the manifest's entry for its own architecture (the record TARBALL names the file). A
#                  release whose arm64 tarball does not match the manifest installs on the amd64 node and is refused on the arm64 node
#   3. placement   with the fake runner (fake-runner.sh, as in the other tests, so the classes start fast): a class constrained to
#                  node.platform.arch == aarch64 runs only on the arm64 node, one constrained to x86_64 only on the amd64 node, and an
#                  unconstrained class runs on both. Draining a node leaves the class of its architecture pending ("no suitable node"):
#                  it never moves to the node of the other architecture
#   4. other arches CircleCI's manifest has linux ppc64le and s390x too. Under QEMU user mode the distributor script of the stack runs in a stock
#                  Alpine of each (no Swarm, no jobs): `uname -m` names the architecture, and it installs the runner tarball of that architecture
#                  (the record names it). The token proxy of those architectures is an image, which ci/proxy-image.sh runs under QEMU
#
# The emulated engine: QEMU user mode lacks the netlink families and socket options that iptables and nftables need, and it cannot run
# runc (clone with namespace flags). So the arm64 engine (dockerd, containerd and the Docker CLI, all arm64 under QEMU, which is what
# makes the node report aarch64) gets four NATIVE amd64 helpers, which run directly on the shared kernel: runc, containerd-shim-runc-v2
# and an iptables front end. The containers it runs are arm64 images, and their processes run under QEMU through the host's binfmt
# handler. Two things do not work in this engine and are not used: IPVS (the virtual IP of a service) and IPsec on overlays.
#
# Usage: mixed-arch.sh        Env: TIMEOUT=300 (each wait), SWARM_TEST_RUNNER_VERSION=3.1.12 (the real runner), SWARM_TEST_KEEP=1,
#                             SWARM_TEST_REQUIRE_EMULATION=1 (a skip becomes a failure; the CI job sets it).
# Prints "RESULT ..." lines and PASS, FAIL or SKIP (an engine or a kernel that cannot emulate arm64). Exit 0 on pass and skip.
# shellcheck disable=SC2329,SC2016  # functions run through wait_for; the single quotes are for the container shell
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TIMEOUT=${TIMEOUT:-300}
# The binfmt installer that registers the qemu handlers in the host kernel (pinned, like every image of the CI).
BINFMT_IMAGE=tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0
DIST_IMAGE=$(sed -n 's/^    image: \(alpine:3@sha256:[0-9a-f]*\).*/\1/p' "$stack_dir/runners.yaml")
REAL=$TEST_RUNNER_VERSION
FAKE=1.0.0
BAD=1.0.1   # the release whose arm64 tarball does not match the manifest

# SWARM_TEST_REQUIRE_EMULATION=1 (the CI job): a host that cannot emulate arm64 is a failure, not a skip.
skip() {
  [[ ${SWARM_TEST_REQUIRE_EMULATION:-} != 1 ]] || fail "arm64 emulation is required here and does not work: $*"
  echo "SKIP: $*"
  exit 0
}

# ---------------------------------------------------------------------------------------------
# Can this host run arm64? (binfmt handler registered, a stock arm64 container runs)
# ---------------------------------------------------------------------------------------------
[[ $ARCH == amd64 ]] || skip "this test runs an arm64 worker next to an amd64 manager and needs an x86_64 host, this one is $(uname -m) (the arm64 jobs of the CI cover a native arm64 node)"
if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
  log "registering the qemu-aarch64 binfmt handler (a kernel setting, it stays until the next boot)"
  docker run --privileged --rm "$BINFMT_IMAGE" --install arm64 > /dev/null 2>&1 || true
fi
[[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] || skip "the qemu-aarch64 binfmt handler is not registered and could not be registered ($BINFMT_IMAGE --install arm64 needs a privileged container)"
[[ $(docker run --rm --platform linux/arm64 "$DIST_IMAGE" uname -m 2> /dev/null) == aarch64 ]] ||
  skip "a stock arm64 container does not run on this host although the qemu-aarch64 handler exists"

work=$(mktemp -d)
trap 'docker rm -f -v swarm-test-native-$$ smr-x-ppc64le-$$ smr-x-s390x-$$ >/dev/null 2>&1 || true; docker volume rm smr-x-vol-ppc64le-$$ smr-x-vol-s390x-$$ >/dev/null 2>&1 || true; dind_stop_all; rm -rf "$work"' EXIT
t0=$(date +%s)
phase_start=$t0
lap() { # NAME: a RESULT line with the seconds since the last one
  local now
  now=$(date +%s)
  echo "RESULT test=mixed-arch timing phase=$1 seconds=$((now - phase_start)) total=$((now - t0))"
  phase_start=$now
}

# ---------------------------------------------------------------------------------------------
# The cluster: an amd64 manager and an arm64 worker (QEMU) on one Docker network
# ---------------------------------------------------------------------------------------------
id=$$
MGR=swarm-test-mgr-$id
WRK=swarm-test-wrk-$id
net=swarm-test-net-$id
SWARM_TEST_MGR=$MGR # the names that lib.sh (mirror_start) expects
SWARM_TEST_WRK=$WRK
DIAG_NODES="$MGR $WRK"
docker network create "$net" > /dev/null
dind_networks+=("$net")

# The worker is created first, from the arm64 image; the image is pulled once per platform (a store with one image per tag is left with the
# amd64 one, which the manager uses).
log "arm64 worker: pulling $DIND_IMAGE for linux/arm64"
docker pull -q --platform linux/arm64 "$DIND_IMAGE" > /dev/null
docker rm -f -v "$WRK" > /dev/null 2>&1 || true
docker create --privileged --platform linux/arm64 --name "$WRK" --hostname "$WRK" --network "$net" -e DOCKER_TLS_CERTDIR= "$DIND_IMAGE" > /dev/null
dind_containers+=("$WRK")
docker pull -q --platform linux/amd64 "$DIND_IMAGE" > /dev/null

# The native helpers come from the amd64 image of the same release: runc and its shim (static binaries) and the nftables iptables with
# the few libraries and the dynamic loader that it needs (a /amd64 tree, entered through small scripts). All of it runs natively.
native=$work/native
mkdir -p "$native/usr/local/bin" "$native/usr/local/sbin" "$native/amd64/usr/sbin" "$native/amd64/usr/lib" "$native/amd64/lib"
docker rm -f -v swarm-test-native-$$ > /dev/null 2>&1 || true
docker create --platform linux/amd64 --name swarm-test-native-$$ "$DIND_IMAGE" > /dev/null
for f in usr/local/bin/runc usr/local/bin/containerd-shim-runc-v2; do docker cp "swarm-test-native-$$:/$f" "$native/$f"; done
docker cp swarm-test-native-$$:/usr/sbin/xtables-nft-multi "$native/amd64/usr/sbin/"
docker cp swarm-test-native-$$:/lib/ld-musl-x86_64.so.1 "$native/amd64/lib/"
docker cp swarm-test-native-$$:/usr/lib "$work/amd64-usr-lib" # the libraries and the xtables extensions (the sonames change with the image)
cp -r "$work/amd64-usr-lib/xtables" "$native/amd64/usr/lib/"
for l in libxtables.so libmnl.so libnftnl.so; do cp -P "$work/amd64-usr-lib/$l".* "$native/amd64/usr/lib/"; done
docker rm -f -v swarm-test-native-$$ > /dev/null
for n in iptables ip6tables iptables-save iptables-restore ip6tables-save ip6tables-restore; do
  printf '#!/bin/sh\nexport XTABLES_LIBDIR=/amd64/usr/lib/xtables\nexec /amd64/lib/ld-musl-x86_64.so.1 --library-path /amd64/usr/lib:/amd64/lib /amd64/usr/sbin/xtables-nft-multi %s "$@"\n' "$n" > "$native/usr/local/sbin/$n"
  chmod 0755 "$native/usr/local/sbin/$n"
done
docker cp "$native/." "$WRK:/" > /dev/null
docker start "$WRK" > /dev/null

dind_start "$MGR" "$net" # amd64: the plain helper of lib.sh
wait_for 180 idocker "$WRK" info > /dev/null 2>&1 ||
  skip "the emulated arm64 engine in $WRK did not start within 180s (docker logs $WRK)"
[[ $(idocker "$WRK" info --format '{{.Architecture}}') == aarch64 ]] || skip "the engine of $WRK does not report aarch64"
idocker "$WRK" run --rm "$DIST_IMAGE" true > /dev/null 2>&1 || skip "the emulated arm64 engine in $WRK cannot run a container"

mgr_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$MGR")
idocker "$MGR" swarm init --advertise-addr "$mgr_ip" > /dev/null
idocker "$WRK" swarm join --token "$(idocker "$MGR" swarm join-token -q worker)" "$mgr_ip:2377" > /dev/null
idocker "$MGR" swarm update --task-history-limit 20 > /dev/null
node_arch() { idocker "$MGR" node inspect --format '{{.Description.Platform.Architecture}}' "$1"; }
[[ $(node_arch "$MGR") == x86_64 && $(node_arch "$WRK") == aarch64 ]] || fail "the nodes do not report x86_64 and aarch64: $(node_arch "$MGR") and $(node_arch "$WRK")"
echo "RESULT test=mixed-arch step=cluster manager=$MGR/$(node_arch "$MGR") worker=$WRK/$(node_arch "$WRK") emulation=qemu-aarch64"
dind_load "$MGR" "$CIMG_IMAGE"
for img in "$CIMG_IMAGE" "$DIST_IMAGE"; do idocker "$WRK" pull -q "$img" > /dev/null; done   # arm64 variants: this engine is arm64
[[ $(idocker "$WRK" image inspect --format '{{.Architecture}}' "$CIMG_IMAGE") == arm64 ]] || fail "the class image on the worker is not arm64"
lap cluster

# ---------------------------------------------------------------------------------------------
# The mirror: a manifest that lists the amd64 and the arm64 tarball of every release
# ---------------------------------------------------------------------------------------------
declare -A SHA=() # "version/arch" -> SHA-256 of the genuine tarball
versions=()
mirror_start
fake_tarball() { # VERSION TAG OUT: the fake runner; the tag makes the tarball of each architecture differ
  local stage
  stage=$(mktemp -d)
  { sed "s/@VERSION@/$1/" "$tests_dir/fake-runner.sh"; echo "# $2"; } > "$stage/circleci-runner"
  chmod 0755 "$stage/circleci-runner"
  tar -C "$stage" -czf "$3" circleci-runner
  rm -rf "$stage"
}
# publish KIND VERSION [TAMPERED_ARCH]: both tarballs of VERSION (real: CircleCI's, fake: the stand-in) and a manifest whose "current" is
# VERSION. A tampered tarball is served with the SHA-256 of the genuine one in the manifest.
publish() {
  local kind=$1 v=$2 bad=${3:-} a dir=$work/mirror/$2 tgz key
  local -a archs=(amd64 arm64)
  [[ $kind == real ]] || archs+=(ppc64le s390x) # the stand-in runner is a shell script, which runs on every architecture
  mkdir -p "$dir"
  for a in "${archs[@]}"; do
    tgz=$dir/circleci-runner_linux_$a.tar.gz
    if [[ $kind == real ]]; then cp "$(ARCH=$a real_tarball "$v")" "$tgz"; else fake_tarball "$v" "built for $a" "$tgz"; fi
    SHA[$v/$a]=$(sha256sum "$tgz" | cut -d' ' -f1)
    [[ $a != "$bad" ]] || fake_tarball "$v" "tampered" "$tgz"
  done
  [[ " ${versions[*]:-} " == *" $v "* ]] || versions+=("$v")
  for key in "${!SHA[@]}"; do echo "${key%/*} ${key#*/} ${SHA[$key]}"; done > "$work/shas"
  python3 - "$MIRROR_URL" "$2" "$work/shas" "$work/mirror/manifest.json" << 'PY'
import json, sys
url, cur, shas, out = sys.argv[1:]
releases = {}
for line in open(shas):
    v, arch, sha = line.split()
    releases.setdefault(v, {"linux": {}})["linux"][arch] = {"sha256": sha, "url": "%s/%s/circleci-runner_linux_%s.tar.gz" % (url, v, arch)}
releases["current"] = releases[cur]
releases["edge"] = releases[cur]
json.dump({"releases": releases}, open(out, "w"), indent=2)
PY
  docker cp "$work/mirror/." "$MGR:/mirror/" > /dev/null
}

# ---------------------------------------------------------------------------------------------
# The stack: the real runners.yaml, an override that pins the distributor and constrains two classes by architecture
# ---------------------------------------------------------------------------------------------
# deploy VERSION DEFAULT JAVA HARDENED: replicas of the three classes. linux-java stays x86_64 only and linux-hardened aarch64 only, the way a
# user writes it (a class constraint is added to the shared ones of runners.yaml). linux-java runs the image, and has the resources, of the
# others, so that the test does not pull the JDK and the two nodes have room for every replica.
deploy() {
  cat > "$work/ov.yaml" << EOF
services:
  linux-default:
    environment: {CIRCLECI_RUNNER_MODE: continuous, FAKE_JOB_INTERVAL: "300", MACHINE_RUNNER_SWARM_RUNNER_WAIT: "300"}
    deploy: {replicas: $2}
  linux-java:
    image: $CIMG_IMAGE
    environment: {CIRCLECI_RUNNER_MODE: continuous, FAKE_JOB_INTERVAL: "300", MACHINE_RUNNER_SWARM_RUNNER_WAIT: "300"}
    deploy:
      replicas: $3
      resources:
        limits: {cpus: "2", memory: 4G, pids: 4096}
        reservations: {cpus: "2", memory: 4G}
      placement:
        constraints: ["node.platform.arch == x86_64"]
  linux-hardened:
    environment: {CIRCLECI_RUNNER_MODE: continuous, FAKE_JOB_INTERVAL: "300", MACHINE_RUNNER_SWARM_RUNNER_WAIT: "300"}
    deploy:
      replicas: $4
      placement:
        constraints: ["node.platform.arch == aarch64"]
  token-proxy:
    deploy: {replicas: 0}
  runner-distributor:
    environment:
      MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL: "$MIRROR_URL"
      MACHINE_RUNNER_SWARM_RUNNER_VERSION: "$1"
      MACHINE_RUNNER_SWARM_RUNNER_SHA256: "manifest"   # the manifest of the test mirror, over plain http, on purpose (the default is the pin of the stack file)
      MACHINE_RUNNER_SWARM_ALLOW_HTTP: "true"
EOF
  deploy_stack "$MGR" "$work/ov.yaml" runners.yaml classes-extra.yaml   # linux-java and linux-hardened are the classes of classes-extra.yaml
}

dk() { docker exec "$1" docker "${@:2}"; } # lib.sh idocker reads stdin, which would eat the lines of a while-read loop
vol=/var/lib/docker/volumes/${STACK}_runner-bin/_data
current() { docker exec "$1" readlink "$vol/current" 2> /dev/null || true; }
all_current() { [[ $(current "$MGR") == "versions/$1" && $(current "$WRK") == "versions/$1" ]]; }
dist_logs() { local c; c=$(running_container "$1" runner-distributor); [[ -z $c ]] || dk "$1" logs "$c" 2>&1; }
elf_machine() { # NODE FILE: what the ELF header says (the images have no file(1))
  local hex
  hex=$(docker exec "$1" head -c 20 "$2" | od -An -v -tx1 | tr -d ' \n')
  [[ ${hex:0:8} == 7f454c46 ]] || { echo "not an ELF file"; return; }
  case ${hex:36:4} in 3e00) echo "ELF 64-bit x86-64" ;; b700) echo "ELF 64-bit AArch64" ;; *) echo "ELF machine ${hex:36:4}" ;; esac
}
# tasks_of SERVICE: "node state" lines of the current tasks of a class
tasks_of() { dk "$MGR" service ps --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' "${STACK}_$1"; }
nodes_running() { tasks_of "$1" | awk '$2 == "Running" { print $1 }' | sort | uniq -c | awk '{ printf "%s%s=%s", (n++ ? "," : ""), $2, $1 }'; }
wait_until() { wait_for "$TIMEOUT" "$@" || fail "timeout (${TIMEOUT}s): $*"; }
nodes_are() { [[ $(nodes_running "$1") == "$2" ]]; } # SERVICE node=count[,node=count]: where the running tasks of a class are
running_count() { [[ $(tasks_of "$1" | grep -c ' Running') -eq $2 ]]; }
pending_no_node() { dk "$MGR" service ps --filter desired-state=running --format '{{.CurrentState}}|{{.Error}}' "${STACK}_$1" | head -n 1 | grep -q '^Pending.*no suitable node'; }
# check_install NODE ARCH VERSION: the node got the tarball of its own architecture, as the manifest lists it, in a root-owned tree
check_install() {
  local n=$1 a=$2 v=$3 d=$vol/versions/$3
  [[ $(docker exec "$n" cat "$d/TARBALL") == "${SHA[$v/$a]}  circleci-runner_linux_$a.tar.gz" ]] ||
    fail "$n: the record of $v does not name the $a tarball with the manifest's SHA-256 (${SHA[$v/$a]}): $(docker exec "$n" cat "$d/TARBALL")"
  [[ ${SHA[$v/amd64]} != "${SHA[$v/arm64]}" ]] || fail "the amd64 and the arm64 tarball of $v are the same file"
  [[ $(docker exec "$n" cat "$d/VERSION") == "$v" ]] || fail "$n: VERSION of $v"
  [[ -z $(docker exec "$n" find "$vol" ! -type l \( ! -user root -o -perm /022 \)) ]] || fail "$n: a file of the volume is not root-owned or is group/world writable"
  # the log in a variable first: grep -q ends at its first match, the producer of a pipe then dies of SIGPIPE, and pipefail reports that
  local log; log=$(dist_logs "$n")
  grep -q "downloading circleci-runner $v linux/$a\$" <<< "$log" || fail "$n: its distributor did not download the $a build of $v"
}

# ---------------------------------------------------------------------------------------------
# 1 + 2: the real runner, both architectures: install, ELF, SHA-256, a version print in a stock image
# ---------------------------------------------------------------------------------------------
publish real "$REAL"
create_secrets "$MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}" "${EXTRA_SERVICES[@]}"
# the arm64 worker is QEMU user-mode emulation, where IPsec on an overlay does not work (docs/multi-node.md): deploy the documented plain-overlay copy
export SWARM_TEST_PLAIN_OVERLAY=1
deploy "$REAL" 0 0 0
dist_up() { [[ $(tasks_of runner-distributor | grep -c ' Running') -eq 2 ]]; }
wait_until dist_up
nodes=$(tasks_of runner-distributor | awk '{ print $1 }' | sort | paste -sd, -)
[[ $nodes == "$(printf '%s\n' "$MGR" "$WRK" | sort | paste -sd, -)" ]] || fail "the distributor does not run on both nodes: $nodes"
wait_until all_current "$REAL"
echo "RESULT test=mixed-arch step=distributor_on_both_nodes nodes=$nodes current=versions/$REAL"
lap distributor-install

exe=$vol/versions/$REAL/bin/circleci-runner
for pair in "$MGR amd64 x86-64" "$WRK arm64 AArch64"; do
  read -r n a want <<< "$pair"
  check_install "$n" "$a" "$REAL"
  kind=$(elf_machine "$n" "$exe")
  [[ $kind == "ELF 64-bit $want" ]] || fail "$n: the runner it installed is '$kind', the node needs $want"
  mine=$(docker exec "$n" sha256sum "$exe" | cut -d' ' -f1)
  [[ $mine == "$(ARCH=$a real_runner "$REAL" | xargs sha256sum | cut -d' ' -f1)" ]] || fail "$n: the installed binary is not the one in the $a tarball of CircleCI"
  out=$(dk "$n" run --rm -v "${STACK}_runner-bin:/opt/machine-runner-swarm:ro" "$CIMG_IMAGE" sh -c 'uname -m; /opt/machine-runner-swarm/current/bin/circleci-runner --version' 2>&1 | tr '\n' ' ')
  [[ $out == *"$(dk "$n" info --format '{{.Architecture}}')"* && $out == *"version $REAL"* ]] || fail "$n: the runner does not print its version in a stock image: $out"
  echo "RESULT test=mixed-arch step=install node=$n arch=$a file=\"$kind\" tarball_sha256=${SHA[$REAL/$a]:0:16} binary_sha256=${mine:0:16} stock_image=\"${out% }\""
done
lap real-runner-checks

# ---------------------------------------------------------------------------------------------
# 3: placement by architecture (fake runner, so a class starts in seconds)
# ---------------------------------------------------------------------------------------------
publish fake "$FAKE"
deploy "$FAKE" 0 0 0 # the classes start only after the nodes run the fake runner: a container resolves "current" once
wait_until all_current "$FAKE"
for pair in "$MGR amd64" "$WRK arm64"; do
  read -r n a <<< "$pair"
  check_install "$n" "$a" "$FAKE"
done
deploy "$FAKE" 2 1 1
wait_until running_count linux-default 2
wait_until running_count linux-java 1
wait_until running_count linux-hardened 1
default_nodes=$(tasks_of linux-default | awk '{ print $1 }' | sort | paste -sd, -)
java_nodes=$(nodes_running linux-java)
hardened_nodes=$(nodes_running linux-hardened)
echo "RESULT test=mixed-arch step=placement linux-default=$default_nodes linux-java[x86_64]=$java_nodes linux-hardened[aarch64]=$hardened_nodes"
[[ $java_nodes == "$MGR=1" ]] || fail "the x86_64 class did not run only on the amd64 node: $java_nodes"
[[ $hardened_nodes == "$WRK=1" ]] || fail "the aarch64 class did not run only on the arm64 node: $hardened_nodes"
[[ $default_nodes == "$(printf '%s\n' "$MGR" "$WRK" | sort | paste -sd, -)" ]] || fail "the unconstrained class does not run on both nodes: $default_nodes"
for s in linux-java linux-hardened; do # the class constraint comes on top of the shared constraints of the real stack file
  c=$(dk "$MGR" service inspect --format '{{json .Spec.TaskTemplate.Placement.Constraints}}' "${STACK}_$s")
  [[ $c == *'node.platform.os == linux'* && $c == *'docker-build != true'* && $c == *'node.platform.arch =='* ]] || fail "$s: unexpected constraints $c"
done
# what runs there really is of that architecture
for pair in "linux-java $MGR x86_64" "linux-hardened $WRK aarch64"; do
  read -r s n want <<< "$pair"
  c=$(running_container "$n" "$s")
  got=$(dk "$n" exec "$c" uname -m)
  [[ $got == "$want" ]] || fail "$s on $n runs a $got container, not $want"
  runner_started() { dk "$n" logs "$c" 2>&1 | grep -q "FAKERUNNER start"; } # the entrypoint takes a while under emulation
  wait_until runner_started
  echo "RESULT test=mixed-arch step=class_container service=$s node=$n uname_m=$got runner_started=yes"
done
lap placement

# Draining a node leaves the class of its architecture pending: it must not move to the other architecture. First the arm64 node.
dk "$MGR" node update --availability drain "$WRK" > /dev/null
wait_until pending_no_node linux-hardened
[[ -z $(nodes_running linux-hardened) ]] || fail "the aarch64 class runs on a node although the arm64 node is drained: $(nodes_running linux-hardened)"
wait_until nodes_are linux-default "$MGR=2"
echo "RESULT test=mixed-arch step=drain_arm64 linux-hardened=Pending(no suitable node) linux-java=$(nodes_running linux-java) linux-default=$(nodes_running linux-default)"
[[ $(nodes_running linux-java) == "$MGR=1" && $(nodes_running linux-default) == "$MGR=2" ]] || fail "after draining the arm64 node, the other classes are not all on the amd64 node"
# then the amd64 node, with the arm64 node back
dk "$MGR" node update --availability active "$WRK" > /dev/null
dk "$MGR" node update --availability drain "$MGR" > /dev/null
wait_until pending_no_node linux-java
wait_until nodes_are linux-hardened "$WRK=1"
wait_until nodes_are linux-default "$WRK=2"
[[ -z $(nodes_running linux-java) ]] || fail "the x86_64 class runs on $(nodes_running linux-java) although the amd64 node is drained"
echo "RESULT test=mixed-arch step=drain_amd64 linux-java=Pending(no suitable node) linux-hardened=$(nodes_running linux-hardened) linux-default=$(nodes_running linux-default)"
dk "$MGR" node update --availability active "$MGR" > /dev/null
wait_until running_count linux-java 1
lap drain-placement

# ---------------------------------------------------------------------------------------------
# 2 again: a release whose arm64 tarball does not match the manifest
# ---------------------------------------------------------------------------------------------
publish fake "$BAD" arm64
deploy "$BAD" 2 1 1
arm_refused() { dist_logs "$WRK" | grep -q "SHA-256 mismatch for circleci-runner_linux_arm64.tar.gz $BAD: got .*: refusing to install"; }
wait_until arm_refused
wait_until bash -c "[[ \$(docker exec $MGR readlink $vol/current) == versions/$BAD ]]"
check_install "$MGR" amd64 "$BAD"
[[ $(current "$WRK") == "versions/$FAKE" ]] || fail "the arm64 node left $FAKE for a tarball that does not match its manifest entry: $(current "$WRK")"
docker exec "$WRK" test ! -e "$vol/versions/$BAD" || fail "the arm64 node installed the tarball that does not match its manifest entry"
echo "RESULT test=mixed-arch step=sha256_per_architecture amd64_node=installed($BAD) arm64_node=refused(mismatch) arm64_node_current=$(current "$WRK")"
lap sha256-mismatch

# ---------------------------------------------------------------------------------------------
# 4: ppc64le and s390x: the distributor script alone, in a stock Alpine of that architecture under QEMU user mode
# ---------------------------------------------------------------------------------------------
for a in ppc64le s390x; do
  if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-$a ]]; then docker run --privileged --rm "$BINFMT_IMAGE" --install "$a" > /dev/null 2>&1 || true; fi
  if [[ $(docker run --rm --platform "linux/$a" "$DIST_IMAGE" uname -m 2> /dev/null) != "$a" ]]; then
    [[ ${SWARM_TEST_REQUIRE_EMULATION:-} != 1 ]] || fail "$a emulation is required here and does not work: a stock $a container does not run (binfmt handler qemu-$a)"
    echo "RESULT test=mixed-arch step=other_arch arch=$a SKIPPED: a stock $a container does not run on this host"
    continue
  fi
  name=smr-x-$a-$$
  xvol=smr-x-vol-$a-$$
  docker rm -f "$name" > /dev/null 2>&1 || true
  docker volume create "$xvol" > /dev/null
  docker run -d --name "$name" --platform "linux/$a" --network "$net" -v "$stack_dir/runner-distributor.sh:/runner-distributor.sh:ro" -v "$xvol:/opt/machine-runner-swarm" \
    -e "MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=$MIRROR_URL" -e "MACHINE_RUNNER_SWARM_RUNNER_VERSION=$FAKE" -e MACHINE_RUNNER_SWARM_ALLOW_HTTP=true \
    "$DIST_IMAGE" sh /runner-distributor.sh > /dev/null
  x_done() { docker logs "$name" 2>&1 | grep -q '\[ ok \] current'; }
  wait_until x_done || { docker logs "$name" 2>&1 | tail -n 8; fail "the distributor did not install the runner for $a under emulation"; }
  xlog=$(docker logs "$name" 2>&1)
  docker rm -f "$name" > /dev/null
  xv() { docker run --rm -v "$xvol:/v:ro" "$DIST_IMAGE" "$@"; }
  [[ $xlog == *"downloading circleci-runner $FAKE linux/$a"* ]] || fail "the distributor did not download the $a runner: $xlog"
  [[ $(xv cat "/v/versions/$FAKE/TARBALL") == "${SHA[$FAKE/$a]}  circleci-runner_linux_$a.tar.gz" ]] || fail "the record of the $a runner does not name its own tarball"
  [[ $(xv readlink /v/current) == "versions/$FAKE" ]] || fail "current does not point to the runner that was installed for $a"
  echo "RESULT test=mixed-arch step=other_arch arch=$a uname_m=$a runner_tarball=circleci-runner_linux_$a record=own_tarball"
  docker volume rm "$xvol" > /dev/null
done
lap other-arches

pass "the distributor installs the runner of each node's own architecture and checks that architecture's SHA-256; classes constrained by node.platform.arch stay on their architecture; the distributor also installs the runner of ppc64le and s390x ($(($(date +%s) - t0))s, the other architectures emulated by QEMU)"
