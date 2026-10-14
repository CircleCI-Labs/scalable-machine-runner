#!/usr/bin/env bash
# stack-config.sh: validate the stack files the way `docker stack deploy` reads them (alone and merged
# with each add-on stack file) and check the contract of the design on every service. Needs only the Docker CLI
# (no daemon, no Swarm).
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

# every file combination must load (an add-on stack file also alone); the last one holds all six services
for files in "runners.yaml" "ssh-rerun.yaml" "runners.yaml docker-build.yaml" "runners.yaml persistent.yaml" "runners.yaml ssh-rerun.yaml" \
  "runners.yaml docker-build.yaml persistent.yaml ssh-rerun.yaml"; do
  args=()
  for f in $files; do args+=(-c "$dir/$f"); done
  cfg=$(docker stack config "${args[@]}") || { echo "FAIL: docker stack config rejected: $files"; exit 1; }
done

services=(linux-default linux-java linux-hardened linux-docker-build linux-persistent linux-default-ssh)
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
  check "$s" 'a logging block with rotation' '^        max-size: 20m$'
  check "$s" 'cap_drop' '^    cap_drop:$'
  check "$s" 'CIRCLECI_RUNNER_NAME with the node and slot' "^      CIRCLECI_RUNNER_NAME: '\\{\\{\\.Node\\.Hostname\\}\\}-$s-\\{\\{\\.Task\\.Slot\\}\\}'$"
  check "$s" "secret $s-token" "^      - source: $s-token$"
  check "$s" 'the runner config as the secret target' '^        target: circleci_runner_config.yaml$'
  check "$s" 'secret uid 2000 (the runner)' '^        uid: "2000"$'
  check "$s" 'secret gid 2000' '^        gid: "2000"$'
  check "$s" 'secret mode 0400' '^        mode: 256$'
  check "$s" 'the per-node volume runner-bin at /opt/machine-runner-swarm' '^        source: runner-bin$'
  check "$s" 'the volume mounted read-only' '^        read_only: true$'
  # an upgrade changes only the distributor: no version and no hash in a runner service, and no host directory
  if grep -qE 'MACHINE_RUNNER_SWARM_(RUNNER_VERSION|RUNNER_SHA256|DOWNLOAD_BASE_URL)|source: /opt/machine-runner-swarm' <<< "$block"; then
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
check runner-distributor 'the version policy, current by default' '^      MACHINE_RUNNER_SWARM_RUNNER_VERSION: current$'
check runner-distributor 'the major version it follows' '^      MACHINE_RUNNER_SWARM_RUNNER_MAJOR: "3"$'
check runner-distributor 'the check interval' '^      MACHINE_RUNNER_SWARM_CHECK_INTERVAL: 24h$'
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
# the version policy can be set at deploy time, and the variables reach the distributor only
cfg=$(MACHINE_RUNNER_SWARM_RUNNER_VERSION=3.1.12 MACHINE_RUNNER_SWARM_RUNNER_MAJOR=4 MACHINE_RUNNER_SWARM_CHECK_INTERVAL=1h \
  MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=https://mirror.example.com/circleci-runner MACHINE_RUNNER_SWARM_RUNNER_SHA256=abc docker stack config -c "$dir/runners.yaml")
block=$(service_block runner-distributor)
check runner-distributor 'a pinned version from the environment of the deploy' '^      MACHINE_RUNNER_SWARM_RUNNER_VERSION: 3.1.12$'
check runner-distributor 'the mirror from the environment of the deploy' '^      MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL: https://mirror.example.com/circleci-runner$'
check runner-distributor 'the explicit SHA-256 from the environment of the deploy' '^      MACHINE_RUNNER_SWARM_RUNNER_SHA256: abc$'
for svc in linux-default linux-java linux-hardened; do
  if grep -q 'mirror.example.com\|RUNNER_SHA256' <<< "$(service_block "$svc")"; then echo "  $svc: the distributor's settings reached a runner service"; problems=$((problems + 1)); fi
done

# every Swarm config is named after its content (ci/config-names.sh)
if ! out=$("$dir/../../ci/config-names.sh" 2>&1); then
  echo "  $out" | sed 's/^/  /'
  problems=$((problems + 1))
fi

echo "RESULT test=stack-config files=runners.yaml,docker-build.yaml,persistent.yaml,ssh-rerun.yaml services=${#services[@]} problems=$problems"
if [[ $problems -eq 0 ]]; then
  echo "PASS (docker stack config accepts every file combination; every service meets the contract)"
else
  echo "FAIL: $problems problem(s)"
  exit 1
fi
