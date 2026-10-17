#!/usr/bin/env bash
# stack-config.sh: validate the stack files the way `docker stack deploy` reads them (alone and merged
# with each add-on stack file) and check the contract of the design on every service, the token proxy among them. Needs only the
# Docker CLI (no daemon, no Swarm).
#
# Usage: stack-config.sh
set -euo pipefail
dir=$(cd "$(dirname "$0")/../stack" && pwd)

problems=0
check() { # service description regex
  if ! grep -qE "$3" <<< "$block"; then
    echo "  $1: missing $2"
    problems=$((problems + 1))
  fi
}
service_block() { awk -v s="$1" '$0 == "  " s ":" { f = 1; next } f && (/^  [^ ]/ || /^[^ ]/) { f = 0 } f' <<< "$cfg"; }

# every file combination must load (an add-on stack file also alone); the last one holds all the runner services, the proxy and the container agent
for files in "runners.yaml" "classes-extra.yaml" "ssh-rerun.yaml" "microvm.yaml" "container-mode.yaml" "runners.yaml classes-extra.yaml" "runners.yaml docker-build.yaml" \
  "runners.yaml persistent.yaml" "runners.yaml ssh-rerun.yaml" "runners.yaml microvm.yaml" "runners.yaml container-mode.yaml" \
  "runners.yaml classes-extra.yaml docker-build.yaml persistent.yaml ssh-rerun.yaml microvm.yaml container-mode.yaml"; do
  args=()
  for f in $files; do args+=(-c "$dir/$f"); done
  cfg=$(docker stack config "${args[@]}") || { echo "FAIL: docker stack config rejected: $files"; exit 1; }
done

# Every class network is an encrypted overlay: the traffic between a runner and the token proxy (task tokens, context secrets, step output) is plain http and crosses
# the nodes, so Swarm encrypts it with IPsec (ESP, IP protocol 50: docs/multi-node.md). The opt-out is to delete driver_opts in a copy of the file.
cfg_all=$(docker stack config -c "$dir/runners.yaml" -c "$dir/classes-extra.yaml" -c "$dir/docker-build.yaml" -c "$dir/persistent.yaml" -c "$dir/ssh-rerun.yaml" -c "$dir/microvm.yaml")
nets=$(awk '/^networks:/ { f = 1; next } /^[^ ]/ { f = 0 } f && /^  [^ ]+:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' <<< "$cfg_all")
for n in $nets; do
  if ! awk -v n="$n" '/^networks:/ { f = 1; next } /^[^ ]/ { f = 0 } f && $0 == "  " n ":" { g = 1; next } f && /^  [^ ]/ { g = 0 } g' <<< "$cfg_all" | tr -d '\n' | grep -q 'driver: overlay *driver_opts: *encrypted: "true"'; then
    echo "  network $n: not an encrypted overlay (driver: overlay, driver_opts: {encrypted: \"true\"})"
    problems=$((problems + 1))
  fi
done
[[ $(wc -w <<< "$nets") -eq 8 ]] || { echo "  expected 8 class networks in the Linux stack files, found $(wc -w <<< "$nets"): $nets"; problems=$((problems + 1)); }
# Whatever the list of services below says, EVERY service that runs a runner (it has a CIRCLECI_RUNNER_NAME) keeps off the node of the
# proxy, and the proxy and the other services do not (the proxy must be able to run there, and the label means "no jobs here").
cfg=$cfg_all
for s in $(awk '/^services:/ { f = 1; next } /^[^ ]/ { f = 0 } f && /^  [^ ]+:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' <<< "$cfg"); do
  block=$(service_block "$s")
  if grep -q '^      CIRCLECI_RUNNER_NAME:' <<< "$block"; then
    check "$s" 'the proxy-node constraint (proxy != true): every runner service needs it' '^          - node.labels.machine-runner-swarm.proxy != true$'
  elif grep -q 'machine-runner-swarm.proxy' <<< "$block" && [[ $s != token-proxy ]]; then
    echo "  $s: mentions the proxy node label, but runs no runner"
    problems=$((problems + 1))
  fi
done
# The shipped runners.yaml is ONE class (a first job needs one resource class, one token and one network): the others are add-on stack files.
cfg_base=$(docker stack config -c "$dir/runners.yaml")
base_runners=$(awk '/^services:/ { f = 1; next } /^[^ ]/ { f = 0 } f && /^  [^ ]+:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' <<< "$cfg_base" | sort | paste -sd' ' -)
if [[ $base_runners != "linux-default runner-distributor token-proxy" ]]; then
  echo "  runners.yaml has the services '$base_runners', expected linux-default, runner-distributor and token-proxy: more classes belong in an add-on stack file"
  problems=$((problems + 1))
fi
services=(linux-default linux-java linux-hardened linux-docker-build linux-persistent linux-default-ssh linux-microvm linux-microvm-docker)
for s in "${services[@]}"; do
  block=$(service_block "$s")
  if [[ -z $block ]]; then
    echo "  $s: service not found"
    problems=$((problems + 1))
    continue
  fi
  check "$s" 'user: "0"' '^    user: "0"$'
  check "$s" 'entrypoint /circleci-runner-entrypoint (a Swarm config)' '^      - /circleci-runner-entrypoint$'
  check "$s" 'the entrypoint config at /circleci-runner-entrypoint, mode 0555' '^        target: /circleci-runner-entrypoint$'
  check "$s" 'init: true' '^    init: true$'
  check "$s" 'stop_grace_period 5h5m' '^    stop_grace_period: 5h5m0s$'
  check "$s" 'restart_policy condition any' '^        condition: any$'
  check "$s" 'restart_policy delay 10s' '^        delay: 10s$'
  check "$s" 'update_config order stop-first' '^        order: stop-first$'
  check "$s" 'update_config parallelism 1' '^        parallelism: 1$'
  check "$s" 'resource limits' '^        limits:$'
  check "$s" 'resource reservations' '^        reservations:$'
  check "$s" 'a pids limit' '^          pids: [0-9]+$'
  check "$s" 'placement constraint node.platform.os == linux' '^          - node.platform.os == linux$'
  if [[ $s == linux-docker-build ]]; then
    if grep -q 'machine-runner-swarm.docker-build !=' <<< "$block"; then
      echo "  $s: must run ON a Docker-build node, not stay off it"
      problems=$((problems + 1))
    fi
  else
    # Swarm reads a missing label as "not equal", so unlabelled nodes still match.
    check "$s" 'the Docker-build isolation constraint (docker-build != true)' '^          - node.labels.machine-runner-swarm.docker-build != true$'
  fi
  if [[ $s == linux-microvm* ]]; then
    # the microVM classes run ON microVM nodes (label true), and only there
    if grep -q 'machine-runner-swarm.microvm !=' <<< "$block"; then
      echo "  $s: must run ON a microVM node, not stay off it"
      problems=$((problems + 1))
    fi
    check "$s" 'the microVM node constraint (microvm == true)' '^          - node.labels.machine-runner-swarm.microvm == true$'
    check "$s" 'the entrypoint guard MACHINE_RUNNER_SWARM_REQUIRE_MICROVM "true"' '^      MACHINE_RUNNER_SWARM_REQUIRE_MICROVM: "true"$'
    check "$s" 'the read-only /etc/resolv.conf bind of the node file (DNS in a Kata VM)' '^        source: /etc/machine-runner-swarm/microvm-resolv.conf$'
    check "$s" 'the /etc/resolv.conf target' '^        target: /etc/resolv.conf$'
  else
    # Swarm reads a missing label as "not equal", so unlabelled nodes still match.
    check "$s" 'the microVM isolation constraint (microvm != true)' '^          - node.labels.machine-runner-swarm.microvm != true$'
  fi
  # no job on the node that runs the proxy (the node label machine-runner-swarm.proxy=true): a job there shares a host with every class token.
  # Swarm reads a missing label as "not equal", so a node without the label, and a single node, still match.
  check "$s" 'the proxy-node constraint (proxy != true)' '^          - node.labels.machine-runner-swarm.proxy != true$'
  check "$s" 'a logging block with rotation' '^        max-size: 20m$'
  # linux-microvm-docker has none by design: BuildKit and runc inside its VM need Docker's default set, NET_RAW included (checked below)
  [[ $s == linux-microvm-docker ]] || check "$s" 'cap_drop' '^    cap_drop:$'
  check "$s" 'CIRCLECI_RUNNER_NAME with the node and slot' "^      CIRCLECI_RUNNER_NAME: '\\{\\{\\.Node\\.Hostname\\}\\}-$s-\\{\\{\\.Task\\.Slot\\}\\}'$"
  if [[ $s == linux-persistent ]]; then
    # a continuous runner claims after every job, so it keeps its own token and does not use the proxy
    check "$s" "secret $s-token (a direct token)" "^      - source: $s-token$"
    if grep -q 'token-proxy' <<< "$block"; then
      echo "  $s: uses the token proxy (one claim per container: a continuous runner claims many times)"
      problems=$((problems + 1))
    fi
  else
    check "$s" 'the placeholder secret runner-placeholder-token' '^      - source: runner-placeholder-token$'
    check "$s" 'CIRCLECI_RUNNER_API_URL at the token proxy' '^      CIRCLECI_RUNNER_API_URL: http://token-proxy:8080$'
    if grep -q "source: $s-token" <<< "$block"; then
      echo "  $s: mounts the class token (only token-proxy may)"
      problems=$((problems + 1))
    fi
  fi
  check "$s" 'the runner config as the secret target' '^        target: circleci_runner_config.yaml$'
  check "$s" 'secret uid 2000 (the runner)' '^        uid: "2000"$'
  check "$s" 'secret gid 2000' '^        gid: "2000"$'
  check "$s" 'secret mode 0400' '^        mode: 256$'
  if [[ $s != linux-microvm* ]]; then
    check "$s" 'the per-node volume runner-bin at /opt/machine-runner-swarm' '^        source: runner-bin$'
    check "$s" 'the volume mounted read-only' '^        read_only: true$'
  fi
  # an upgrade changes only the distributor: no version and no hash in a runner service, and no host directory. A microVM class has no
  # distributor on its node (no shared volume): it carries the settings that its entrypoint downloads the runner with, and no volume.
  if [[ $s == linux-microvm* ]]; then
    check "$s" 'the runner version it downloads' '^      MACHINE_RUNNER_SWARM_RUNNER_VERSION: '
    check "$s" 'the distributor script as a config (the entrypoint runs it once)' '^        target: /runner-distributor.sh$'
    if grep -qE 'source: runner-bin|source: /opt/machine-runner-swarm' <<< "$block"; then
      echo "  $s: mounts the runner volume (a guest with SYS_ADMIN could remount it read-write)"
      problems=$((problems + 1))
    fi
  elif grep -qE 'MACHINE_RUNNER_SWARM_(RUNNER_VERSION|RUNNER_SHA256|DOWNLOAD_BASE_URL)|source: /opt/machine-runner-swarm' <<< "$block"; then
    echo "  $s: carries a runner version, hash, mirror or host directory: only runner-distributor may"
    problems=$((problems + 1))
  fi
  check "$s" 'its own network' "^      $s: null$"
  if [[ $s != linux-default-ssh ]]; then
    # only the SSH add-on publishes a port or turns the SSH rerun feature on
    if grep -qE '^    ports:$|CIRCLECI_RUNNER_SSH_ADVERTISE_ADDR|max_replicas_per_node' <<< "$block"; then
      echo "  $s: publishes a port or enables SSH reruns (only linux-default-ssh does)"
      problems=$((problems + 1))
    fi
  fi
  if grep -q 'privileged\|security_opt' <<< "$block"; then
    echo "  $s: uses a key Swarm ignores"
    problems=$((problems + 1))
  fi
  grep -qE "^  $s-token:$" <<< "$(awk '/^secrets:/ { f = 1; next } /^[^ ]/ { f = 0 } f' <<< "$cfg")" || { echo "  $s: top-level secret $s-token is not declared"; problems=$((problems + 1)); }
done

# The token proxy: the only service that mounts the class tokens, on every proxied class network, one claim at a time per container.
proxied=(linux-default linux-java linux-hardened linux-docker-build linux-default-ssh linux-microvm linux-microvm-docker)
block=$(service_block token-proxy)
if [[ -z $block ]]; then
  echo "  token-proxy: service not found"
  problems=$((problems + 1))
else
  check token-proxy 'the published image, the latest tag by default (MACHINE_RUNNER_SWARM_PROXY_IMAGE)' '^    image: ccilabs/machine-runner-swarm-proxy:latest$'
  check token-proxy 'user 65534' '^    user: "65534"$'
  check token-proxy 'a read-only root filesystem' '^    read_only: true$'
  check token-proxy 'cap_drop ALL' '^      - ALL$'
  check token-proxy 'endpoint_mode dnsrr (a virtual IP hides the runner addresses)' '^      endpoint_mode: dnsrr$'
  check token-proxy 'one replica (the claim latch lives in the proxy)' '^      replicas: 1$'
  check token-proxy 'update_config order stop-first' '^        order: stop-first$'
  check token-proxy 'placement constraint node.platform.os == linux' '^          - node.platform.os == linux$'
  check token-proxy 'the Docker-build isolation constraint (docker-build != true)' '^          - node.labels.machine-runner-swarm.docker-build != true$'
  check token-proxy 'the microVM isolation constraint (Docker DNS, which finds tasks.<service>, does not work in a Kata VM)' '^          - node.labels.machine-runner-swarm.microvm != true$'
  check token-proxy 'the container-mode isolation constraint (the container agent holds the Docker socket)' '^          - node.labels.machine-runner-swarm.container-mode != true$'
  check token-proxy 'a manager by default, with no label (the node that keeps proxy-state)' '^          - node.role == manager$'
  if grep -q 'machine-runner-swarm\.proxy' <<< "$block"; then
    echo "  token-proxy: the default placement needs a node label (a manager is the default; the label is an optional pin)"
    problems=$((problems + 1))
  fi
  check token-proxy 'a healthcheck' '^    healthcheck:$'
  check token-proxy 'the state volume proxy-state' '^        source: proxy-state$'
  check token-proxy 'the state volume at /state, where the image makes it writable for 65534' '^        target: /state$'
  check token-proxy 'the state directory in the arguments' '^      - /state$'
  if grep -qE 'runner-bin|configs:|entrypoint' <<< "$block"; then
    echo "  token-proxy: it runs from its image alone: no runner-bin volume, config or entrypoint"
    problems=$((problems + 1))
  fi
  for c in "${proxied[@]}"; do
    check token-proxy "the network of $c" "^      $c: null$"
    check token-proxy "the class token $c-token" "^      - source: $c-token$"
  done
  if grep -q 'MACHINE_RUNNER_SWARM_PROXY_CLASS_\|^    environment:$\|runner-placeholder' <<< "$block"; then
    echo "  token-proxy: no class variable and no placeholder secret: the proxy takes a class for every secret <service>-token that it holds (its secrets and networks are all that a class needs)"
    problems=$((problems + 1))
  fi
  check token-proxy 'a start_period of 30 s or more (a start probes CircleCI for up to 25 s before the proxy listens)' '^      start_period: ([3-9][0-9]|[0-9]{3,})s$'
  m=$(awk '/^    secrets:$/ { f = 1; next } /^    [a-z]/ { f = 0 } f && /^      - source: /' <<< "$block" | wc -l)
  if [[ $m -ne ${#proxied[@]} ]]; then
    echo "  token-proxy: $m secret(s), expected ${#proxied[@]} (the token of every proxied class, and no other secret)"
    problems=$((problems + 1))
  fi
  if grep -qE '^    ports:$|privileged|security_opt|source: /opt|docker.sock' <<< "$block"; then
    echo "  token-proxy: publishes a port, mounts a host path, or uses a key Swarm ignores"
    problems=$((problems + 1))
  fi
fi
grep -qE '^  runner-placeholder-token:$' <<< "$(awk '/^secrets:/ { f = 1; next } /^[^ ]/ { f = 0 } f' <<< "$cfg")" || { echo "  top-level secret runner-placeholder-token is not declared"; problems=$((problems + 1)); }

block=$(service_block linux-default)
check linux-default 'MACHINE_RUNNER_SWARM_JOB_SUDO "true"' '^      MACHINE_RUNNER_SWARM_JOB_SUDO: "true"$'
check linux-default 'single-task mode' '^      CIRCLECI_RUNNER_MODE: single-task$'
check linux-default 'an idle timeout' '^      CIRCLECI_RUNNER_IDLE_TIMEOUT: 1h$'
check linux-default 'working-directory cleanup off' '^      CIRCLECI_RUNNER_CLEANUP_WORK_DIR: "false"$'
check linux-default 'a spread preference' '^          - spread: node.id$'
block=$(service_block linux-hardened)
check linux-hardened 'MACHINE_RUNNER_SWARM_JOB_SUDO "false"' '^      MACHINE_RUNNER_SWARM_JOB_SUDO: "false"$'
check linux-hardened 'cap_drop ALL' '^      - ALL$'
block=$(service_block linux-persistent)
# the runner of this class holds the real token (no proxy), so its jobs have no sudo by default: "true" is the documented opt-in
check linux-persistent 'MACHINE_RUNNER_SWARM_JOB_SUDO "false" (the job user cannot read the token file)' '^      MACHINE_RUNNER_SWARM_JOB_SUDO: "false"$'
check linux-persistent 'continuous mode' '^      CIRCLECI_RUNNER_MODE: continuous$'
check linux-persistent 'working-directory cleanup off' '^      CIRCLECI_RUNNER_CLEANUP_WORK_DIR: "false"$'
check linux-persistent 'a named volume' '^        source: persistent-home$'
check linux-persistent 'a node.hostname constraint' '^          - node.hostname == '
block=$(service_block linux-docker-build)
check linux-docker-build 'the docker.sock bind' '^        source: /var/run/docker.sock$'
check linux-docker-build 'the machine-runner-swarm.docker-build label constraint' '^          - node.labels.machine-runner-swarm.docker-build == true$'
check linux-docker-build 'the worker role constraint' '^          - node.role == worker$'

block=$(service_block linux-default-ssh)
check linux-default-ssh 'the SSH advertise address, templated per task, on the fixed port' "^      CIRCLECI_RUNNER_SSH_ADVERTISE_ADDR: '\\{\\{\\.Node\\.Hostname\\}\\}:54782'$"
check linux-default-ssh 'max_replicas_per_node 1 (one host-mode port per node)' '^        max_replicas_per_node: 1$'
check linux-default-ssh 'replicas 1' '^      replicas: 1$'
flat=$(tr '\n' '~' <<< "$block")
if ! grep -qE 'ports:~      - mode: host~        target: 54782~        published: 54782~        protocol: tcp~' <<< "$flat"; then
  echo "  linux-default-ssh: port 54782 must be published once, in host mode (not ingress)"
  problems=$((problems + 1))
fi
grep -q 'mode: ingress' <<< "$block" && { echo "  linux-default-ssh: must not publish in ingress mode"; problems=$((problems + 1)); }
# Drift check: apart from the SSH settings and the replica count, linux-default-ssh is linux-default under another name.
without_ssh() {
  grep -vE '^      CIRCLECI_RUNNER_SSH_ADVERTISE_ADDR:|^        max_replicas_per_node:|^      replicas:' |
    awk '/^    ports:$/ { skip = 1; next } skip && /^      / { next } { skip = 0; print }'
}
if ! diff_out=$(diff <(service_block linux-default | without_ssh) <(service_block linux-default-ssh | sed 's/linux-default-ssh/linux-default/g' | without_ssh)); then
  echo "  linux-default-ssh differs from linux-default beyond the SSH settings (keep the common settings in sync):"
  printf '%s\n' "$diff_out" | sed 's/^/    /'
  problems=$((problems + 1))
fi


# runner-distributor: one per node (global), from a stock image pinned by digest, its script a Swarm config, the only writer of runner-bin
block=$(service_block runner-distributor)
check runner-distributor 'a global service' '^      mode: global$'
check runner-distributor 'an image pinned by digest' '^    image: alpine:3@sha256:[0-9a-f]{64}$'
check runner-distributor 'the script as a config' '^        target: /runner-distributor.sh$'
check runner-distributor 'a read-only root file system' '^    read_only: true$'
check runner-distributor 'a writable runner-bin volume' '^        source: runner-bin$'
check runner-distributor 'every Linux node' '^          - node.platform.os == linux$'
check runner-distributor 'to stay off microVM nodes (a microVM class downloads its own runner, and Docker DNS does not work there)' '^          - node.labels.machine-runner-swarm.microvm != true$'
check runner-distributor 'the version policy: an exact pin by default' '^      MACHINE_RUNNER_SWARM_RUNNER_VERSION: [0-9]+\.[0-9]+\.[0-9]+$'
check runner-distributor 'the major version it follows' '^      MACHINE_RUNNER_SWARM_RUNNER_MAJOR: "3"$'
check runner-distributor 'the check interval' '^      MACHINE_RUNNER_SWARM_CHECK_INTERVAL: 24h$'
if grep -q 'PROXY' <<< "$block"; then
  echo "  runner-distributor: it installs the runner only: the token proxy is an image"
  problems=$((problems + 1))
fi
check runner-distributor 'the CircleCI download URL' '^      MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL: https://circleci-binary-releases.s3.amazonaws.com/circleci-runner$'
check runner-distributor 'cap_drop ALL' '^      - ALL$'
if grep -q '^        read_only: true$' <<< "$block"; then
  echo "  runner-distributor: the runner-bin volume must be writable"
  problems=$((problems + 1))
fi
if grep -q 'docker-build != true' <<< "$block"; then
  echo "  runner-distributor: must also run on a Docker-build node, whose runner needs the binary"
  problems=$((problems + 1))
fi
# Container mode (prototype): the agent is the one service of that file, and the only one with the socket besides the docker-build class.
# The loop above judges the runner services, so the agent is merged in only here.
cfg=$(docker stack config -c "$dir/runners.yaml" -c "$dir/classes-extra.yaml" -c "$dir/docker-build.yaml" -c "$dir/persistent.yaml" -c "$dir/ssh-rerun.yaml" -c "$dir/microvm.yaml" -c "$dir/container-mode.yaml")
block=$(service_block container-agent)
check container-agent 'a global service' '^      mode: global$'
check container-agent 'a stock Go image pinned by digest (nothing is built or published)' '^    image: golang:[0-9.]+-alpine@sha256:[0-9a-f]{64}$'
check container-agent 'user "0" (the socket is owned by root)' '^    user: "0"$'
check container-agent 'the entrypoint as a config' '^        target: /entrypoint.sh$'
check container-agent 'the Go sources as configs: the driver and the wrapper' '^        target: /src/driver.go$'
check container-agent 'the Docker driver as a config' '^        target: /src/driver_docker.go$'
check container-agent 'the wrapper as a config' '^        target: /src/wrapper.go$'
check container-agent 'a read-only root filesystem' '^    read_only: true$'
check container-agent 'a volume for the build' '^        target: /work$'
check container-agent 'cap_drop ALL' '^      - ALL$'
check container-agent 'init: true' '^    init: true$'
check container-agent 'stop_grace_period 5h5m' '^    stop_grace_period: 5h5m0s$'
check container-agent 'update_config order stop-first (two agents on a node would remove each other'"'"'s jobs)' '^        order: stop-first$'
check container-agent 'restart_policy condition any' '^        condition: any$'
check container-agent 'resource limits' '^        limits:$'
check container-agent 'a logging block with rotation' '^        max-size: 20m$'
check container-agent 'the docker.sock bind' '^        source: /var/run/docker.sock$'
check container-agent 'the worker role constraint (the socket on a manager controls the Swarm)' '^          - node.role == worker$'
check container-agent 'the opt-in node label constraint' '^          - node.labels.machine-runner-swarm.container-mode == true$'
check container-agent 'no Docker-build node' '^          - node.labels.machine-runner-swarm.docker-build != true$'
check container-agent 'no microVM node (the socket cannot cross into a Kata VM)' '^          - node.labels.machine-runner-swarm.microvm != true$'
check container-agent 'no node of the token-proxy' '^          - node.labels.machine-runner-swarm.proxy != true$'
check container-agent 'the init image pinned by digest' '^      MACHINE_RUNNER_SWARM_CONTAINER_INIT_IMAGE: .*@sha256:[0-9a-f]{64}$'
check container-agent 'the pause image pinned by digest' '^      MACHINE_RUNNER_SWARM_CONTAINER_PAUSE_IMAGE: .*@sha256:[0-9a-f]{64}$'
check container-agent 'a class with a token file under /run/secrets' '^      MACHINE_RUNNER_SWARM_CONTAINER_CLASSES: .*"token_file":"/run/secrets/docker-default-token"'
check container-agent 'the class secret docker-default-token, root only' '^      - source: docker-default-token$'
check container-agent 'its own network' '^      container-agent: null$'
if grep -q 'ports:\|privileged\|security_opt' <<< "$block"; then
  echo "  container-agent: publishes a port or uses a key Swarm ignores"
  problems=$((problems + 1))
fi
# it keeps its own tokens: no token proxy, no placeholder, no runner volume
if grep -q 'token-proxy\|runner-placeholder\|runner-bin\|CIRCLECI_RUNNER' <<< "$block"; then
  echo "  container-agent: uses the token proxy, the placeholder secret or the runner volume (it claims with its own class tokens)"
  problems=$((problems + 1))
fi
# every Go source file of the agent is a config, so that no file is missing from the build (tests are not delivered)
for f in "$dir"/container-agent/*.go; do
  case $f in *_test.go) continue ;; esac
  grep -q "file: container-agent/$(basename "$f")}\$" "$dir/container-mode.yaml" || { echo "  container-agent: $(basename "$f") is not a config of container-mode.yaml"; problems=$((problems + 1)); }
done
sockets=$(grep -c 'source: /var/run/docker.sock' <<< "$cfg" || true)
if [[ $sockets -ne 2 ]]; then
  echo "  the merged stack mounts the Docker socket in $sockets services, expected 2 (linux-docker-build and container-agent)"
  problems=$((problems + 1))
fi

# the version policy can be set at deploy time, and the variables reach the distributor only
cfg=$(MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1 MACHINE_RUNNER_SWARM_RUNNER_MAJOR=4 MACHINE_RUNNER_SWARM_CHECK_INTERVAL=1h \
  MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=https://mirror.example.com/circleci-runner MACHINE_RUNNER_SWARM_RUNNER_SHA256=abc \
  docker stack config -c "$dir/runners.yaml" -c "$dir/classes-extra.yaml")
block=$(service_block runner-distributor)
check runner-distributor 'a floating version from the environment of the deploy' '^      MACHINE_RUNNER_SWARM_RUNNER_VERSION: "3.1"$'
check runner-distributor 'the mirror from the environment of the deploy' '^      MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL: https://mirror.example.com/circleci-runner$'
check runner-distributor 'the explicit SHA-256 from the environment of the deploy' '^      MACHINE_RUNNER_SWARM_RUNNER_SHA256: abc$'
for svc in linux-default linux-java linux-hardened; do
  if grep -q 'mirror.example.com\|RUNNER_SHA256' <<< "$(service_block "$svc")"; then echo "  $svc: the distributor's settings reached a runner service"; problems=$((problems + 1)); fi
done

# the proxy image can be named at deploy time (a local build, a digest, a mirror), and it reaches the proxy only
cfg=$(MACHINE_RUNNER_SWARM_PROXY_IMAGE='registry.example.com/team/proxy:1.2.3@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' docker stack config -c "$dir/runners.yaml")
block=$(service_block token-proxy)
check token-proxy 'the image from the environment of the deploy' '^    image: registry.example.com/team/proxy:1.2.3@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef$'
if [[ $(grep -c 'registry.example.com/team/proxy' <<< "$cfg") -ne 1 ]]; then echo "  the proxy image reached a service other than token-proxy"; problems=$((problems + 1)); fi

# the proxy placement can be pinned at deploy time (a label on one manager, or a worker), and the pin replaces the manager default
cfg=$(MACHINE_RUNNER_SWARM_PROXY_PLACEMENT='node.labels.machine-runner-swarm.proxy == true' docker stack config -c "$dir/runners.yaml")
block=$(service_block token-proxy)
check token-proxy 'the pin by label from the environment of the deploy' '^          - node.labels.machine-runner-swarm.proxy == true$'
if grep -q 'node.role == manager' <<< "$block"; then
  echo "  token-proxy: the pin by label must replace the manager default, not add to it"
  problems=$((problems + 1))
fi
if grep -q 'machine-runner-swarm.proxy !=' <<< "$block"; then
  echo "  token-proxy: must be able to run on the labelled node: it carries the constraint that keeps runners off it"
  problems=$((problems + 1))
fi

cfg=$(docker stack config -c "$dir/runners.yaml" -c "$dir/microvm.yaml")
# microvm.yaml: a service that adds SYS_ADMIN is safe only inside a VM, so it must demand one (on runc it would be a host escape)
for s in $(awk '/^services:/ { f = 1; next } /^[^ ]/ { f = 0 } f && /^  [^ ]+:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' <<< "$cfg"); do
  block=$(service_block "$s")
  if grep -q '^      - SYS_ADMIN$' <<< "$block"; then
    check "$s" 'MACHINE_RUNNER_SWARM_REQUIRE_MICROVM "true" (it adds SYS_ADMIN)' '^      MACHINE_RUNNER_SWARM_REQUIRE_MICROVM: "true"$'
  fi
done
block=$(service_block linux-microvm)
if grep -q 'cap_add' <<< "$block"; then
  echo "  linux-microvm: adds capabilities (only linux-microvm-docker may)"
  problems=$((problems + 1))
fi
check linux-microvm 'MKNOD dropped like linux-default' '^      - MKNOD$'
block=$(service_block linux-microvm-docker)
check linux-microvm-docker 'SYS_ADMIN (dockerd inside the VM)' '^      - SYS_ADMIN$'
# NET_ADMIN would let a job change the address of its container (dockerd then runs with --bridge=none --iptables=false and builds use --network=host).
# Nothing else is added either.
if grep -qE '^      - NET_ADMIN$|^      - NET_RAW$|^      - ALL$' <<< "$block" || [[ $(awk '/^    cap_add:$/ { f = 1; next } /^    [a-z]/ { f = 0 } f' <<< "$block" | wc -l) -ne 1 ]]; then
  echo "  linux-microvm-docker: cap_add must be SYS_ADMIN alone (NET_ADMIN lets a job take over the address of another container)"
  problems=$((problems + 1))
fi
# One replica: the class keeps NET_RAW (BuildKit's build steps need it), so a sibling in its overlay would be a target for a forged source address.
check linux-microvm-docker 'one replica (it keeps NET_RAW, so no sibling may share its overlay)' '^      replicas: 1$'
check linux-microvm-docker 'a tmpfs data-root at /var/lib/docker' '^        target: /var/lib/docker$'
check linux-microvm-docker 'the tmpfs mount type' '^      - type: tmpfs$'
check linux-microvm-docker 'sudo for the job (the remounts and dockerd need root)' '^      MACHINE_RUNNER_SWARM_JOB_SUDO: "true"$'
if grep -q 'cap_drop' <<< "$block"; then
  echo "  linux-microvm-docker: drops a capability (runc inside the VM fails with 'unable to apply caps' for the default set)"
  problems=$((problems + 1))
fi
# The DNS forwarder: Docker's embedded DNS does not work in a Kata VM, so a runc node answers for the VMs.
block=$(service_block microvm-dns)
check microvm-dns 'to exist' '^    image: '
check microvm-dns 'port 53 udp, published' '^        protocol: udp$'
check microvm-dns 'port 53 tcp, published' '^        protocol: tcp$'
check microvm-dns 'the published port 53' '^        published: 53$'
check microvm-dns 'the class network linux-microvm' '^      linux-microvm: null$'
check microvm-dns 'the class network linux-microvm-docker' '^      linux-microvm-docker: null$'
check microvm-dns 'to stay off microVM nodes (127.0.0.11 does not work in a Kata VM)' '^          - node.labels.machine-runner-swarm.microvm != true$'
check microvm-dns 'to stay off Docker-build nodes' '^          - node.labels.machine-runner-swarm.docker-build != true$'
check microvm-dns 'the corefile config' '^      - source: microvm-corefile$'
if grep -q 'MACHINE_RUNNER_SWARM\|secrets:\|circleci-runner' <<< "$block"; then
  echo "  microvm-dns: is not a runner and holds no token"
  problems=$((problems + 1))
fi
grep -qE '^  microvm-corefile:$' <<< "$(awk '/^configs:/ { f = 1; next } /^[^ ]/ { f = 0 } f' <<< "$cfg")" || { echo "  microvm-dns: top-level config microvm-corefile is not declared"; problems=$((problems + 1)); }
# The network keeper: a Kata container that joins an overlay at the moment its last container leaves hangs, so one container per node holds both.
block=$(service_block microvm-netkeep)
check microvm-netkeep 'global mode (one on every microVM node)' '^      mode: global$'
check microvm-netkeep 'the class network linux-microvm' '^      linux-microvm: null$'
check microvm-netkeep 'the class network linux-microvm-docker' '^      linux-microvm-docker: null$'
check microvm-netkeep 'the microVM node constraint (microvm == true)' '^          - node.labels.machine-runner-swarm.microvm == true$'
check microvm-netkeep 'to stay off Docker-build nodes' '^          - node.labels.machine-runner-swarm.docker-build != true$'
check microvm-netkeep 'cap_drop ALL' '^      - ALL$'
# A microVM node has no distributor and no runner volume: each container downloads its own runner. The default version is the same pin as in
# runners.yaml, and the deploy-time variables reach both.
if grep -q 'microvm-runner-distributor' <<< "$cfg"; then
  echo "  microvm-runner-distributor still exists: a microVM class downloads its own runner, and no node needs a copy of the distributor"
  problems=$((problems + 1))
fi
if grep -q 'source: runner-bin' <<< "$(service_block linux-microvm)$(service_block linux-microvm-docker)"; then
  echo "  a microVM class mounts runner-bin"
  problems=$((problems + 1))
fi
pin_of() { sed -n 's/^  MACHINE_RUNNER_SWARM_RUNNER_VERSION: \${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-\([0-9][0-9.]*\)}.*/\1/p' "$1"; }
pin=$(pin_of "$dir/runners.yaml")
[[ -n $pin ]] || { echo "  runners.yaml has no exact default of MACHINE_RUNNER_SWARM_RUNNER_VERSION"; problems=$((problems + 1)); }
[[ $(pin_of "$dir/microvm.yaml") == "$pin" ]] || { echo "  microvm.yaml pins another runner version than runners.yaml ($pin): keep them equal"; problems=$((problems + 1)); }
if [[ -f $dir/../../windows/stack/runners.yaml ]]; then
  [[ $(pin_of "$dir/../../windows/stack/runners.yaml") == "$pin" ]] || { echo "  windows/stack/runners.yaml pins another runner version than runners.yaml ($pin): keep them equal"; problems=$((problems + 1)); }
fi
# The default install does not rest on the hash of the manifest: the stack files carry the tarball SHA-256 of the pinned version for every
# architecture (Linux: amd64, arm64, ppc64le, s390x; Windows: amd64, arm64). A release bumps the version and the hashes together (ci/release.sh).
sha_of() { sed -n 's/^  MACHINE_RUNNER_SWARM_RUNNER_SHA256: \${MACHINE_RUNNER_SWARM_RUNNER_SHA256:-\([0-9a-f,]*\)}$/\1/p' "$1"; }
sha=$(sha_of "$dir/runners.yaml")
[[ $sha =~ ^([0-9a-f]{64},){3}[0-9a-f]{64}$ ]] || { echo "  runners.yaml: the default of MACHINE_RUNNER_SWARM_RUNNER_SHA256 is not the four tarball SHA-256 values of the pin"; problems=$((problems + 1)); }
[[ $(sha_of "$dir/microvm.yaml") == "$sha" ]] || { echo "  microvm.yaml: the default SHA-256 list differs from runners.yaml: keep them equal"; problems=$((problems + 1)); }
if [[ -f $dir/../../windows/stack/runners.yaml ]]; then
  [[ $(sha_of "$dir/../../windows/stack/runners.yaml") =~ ^[0-9a-f]{64},[0-9a-f]{64}$ ]] || { echo "  windows/stack/runners.yaml: the default of MACHINE_RUNNER_SWARM_RUNNER_SHA256 is not the two tarball SHA-256 values of the pin"; problems=$((problems + 1)); }
fi
block=$(service_block runner-distributor)
check runner-distributor 'the SHA-256 values of the pinned version as the default list' "^      MACHINE_RUNNER_SWARM_RUNNER_SHA256: $sha\$"
cfg=$(MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1 MACHINE_RUNNER_SWARM_RUNNER_MAJOR=4 MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=https://mirror.example.com/circleci-runner \
  MACHINE_RUNNER_SWARM_RUNNER_SHA256=abc docker stack config -c "$dir/runners.yaml" -c "$dir/microvm.yaml")
for s in linux-microvm linux-microvm-docker; do
  block=$(service_block "$s")
  check "$s" 'the floating version from the environment of the deploy' '^      MACHINE_RUNNER_SWARM_RUNNER_VERSION: "3.1"$'
  check "$s" 'the mirror from the environment of the deploy' '^      MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL: https://mirror.example.com/circleci-runner$'
  check "$s" 'the explicit SHA-256 from the environment of the deploy' '^      MACHINE_RUNNER_SWARM_RUNNER_SHA256: abc$'
done

# every Swarm config is named after its content (ci/config-names.sh)
if ! out=$("$dir/../../ci/config-names.sh" 2>&1); then
  echo "  $out" | sed 's/^/  /'
  problems=$((problems + 1))
fi

# setup.sh --deploy warns when the token proxy image is not pinned by digest (it holds every class token). The function is tested alone: it
# reads the stack files and the environment and prints to stderr.
digest=$(printf '0123456789abcdef%.0s' 1 2 3 4)
warns() { # WARN? [VAR=VALUE...] -- FILE: does the function warn?
  local want=$1 out
  shift
  out=$(env -u MACHINE_RUNNER_SWARM_PROXY_IMAGE "${@:1:$#-1}" bash -c 'source "$1"; warn_unpinned_proxy_image "${@:2}"' _ "$dir/../setup.sh" "${@: -1}" 2>&1)
  if [[ $want == yes && $out != *"[WARN] the token proxy image is not pinned by digest"* ]] || [[ $want == no && -n $out ]]; then
    echo "  setup.sh: wanted a warning: $want; got '$out' ($*)"
    problems=$((problems + 1))
  fi
}
warns yes "$dir/runners.yaml"   # a checkout: the default is the tag latest
warns yes MACHINE_RUNNER_SWARM_PROXY_IMAGE= "$dir/runners.yaml"   # empty is unset
warns yes MACHINE_RUNNER_SWARM_PROXY_IMAGE=registry.example.com/team/proxy:1.2.3 "$dir/runners.yaml"
warns yes MACHINE_RUNNER_SWARM_PROXY_IMAGE=registry.example.com/team/proxy@sha256:0123 "$dir/runners.yaml"   # not a whole digest
warns no MACHINE_RUNNER_SWARM_PROXY_IMAGE=registry.example.com/team/proxy:1.2.3@sha256:$digest "$dir/runners.yaml"
bundle=$(mktemp -d)/runners.yaml   # what ci/release.sh makes of runners.yaml: the digest of the release is the default
sed "s|\(MACHINE_RUNNER_SWARM_PROXY_IMAGE:-ccilabs/machine-runner-swarm-proxy:\)latest}|\10.1.0@sha256:$digest}|" "$dir/runners.yaml" > "$bundle"
grep -q "@sha256:$digest}" "$bundle" || { echo "  setup.sh: the test cannot make a bundle file"; problems=$((problems + 1)); }
warns no "$bundle"
rm -rf "$(dirname "$bundle")"
warns no "$dir/ssh-rerun.yaml"   # a stack file that does not read the variable is not judged

echo "RESULT test=stack-config files=runners.yaml,classes-extra.yaml,docker-build.yaml,persistent.yaml,ssh-rerun.yaml,microvm.yaml,container-mode.yaml services=$((${#services[@]} + 1)) proxied_classes=${#proxied[@]} problems=$problems"
if [[ $problems -eq 0 ]]; then
  echo "PASS (docker stack config accepts every file combination; every service meets the contract)"
else
  echo "FAIL: $problems problem(s)"
  exit 1
fi
