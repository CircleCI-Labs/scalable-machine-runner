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

# every file combination must load; the last one holds all five services
for files in "runners.yaml" "runners.yaml docker-build.yaml" "runners.yaml persistent.yaml" "runners.yaml docker-build.yaml persistent.yaml"; do
  args=()
  for f in $files; do args+=(-c "$dir/$f"); done
  cfg=$(docker stack config "${args[@]}") || { echo "FAIL: docker stack config rejected: $files"; exit 1; }
done

services=(linux-default linux-java linux-hardened linux-docker-build linux-persistent)
for s in "${services[@]}"; do
  block=$(service_block "$s")
  if [[ -z $block ]]; then
    echo "  $s: service not found"
    problems=$((problems + 1))
    continue
  fi
  check "$s" 'user: "0"' '^    user: "0"$'
  check "$s" 'entrypoint /opt/machine-runner-swarm/bin/circleci-runner-entrypoint' '^      - /opt/machine-runner-swarm/bin/circleci-runner-entrypoint$'
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
  check "$s" 'the read-only /opt/machine-runner-swarm bind' '^        read_only: true$'
  check "$s" 'the bind source /opt/machine-runner-swarm/current (a link to the installed version)' '^        source: /opt/machine-runner-swarm/current$'
  check "$s" 'its own network' "^      $s: null$"
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

echo "RESULT test=stack-config files=runners.yaml,docker-build.yaml,persistent.yaml services=${#services[@]} problems=$problems"
if [[ $problems -eq 0 ]]; then
  echo "PASS (docker stack config accepts every file combination; every service meets the contract)"
else
  echo "FAIL: $problems problem(s)"
  exit 1
fi
