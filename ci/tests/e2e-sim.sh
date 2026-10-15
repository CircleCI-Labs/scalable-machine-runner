#!/usr/bin/env bash
# Local simulation of the Linux e2e (ci/e2e-host.sh + ci/e2e-probe.sh) without CircleCI, a
# runner token or a runner: a privileged docker:dind container plays the CI VM, and a fake
# runner entrypoint plays the runner by running the next queued probe as an unprivileged user
# and exiting 0, like a single-task runner after one job. Swarm, the stack deploy, the restart
# policy, events, the secret and the evidence handling are real.
#
#   ci/tests/e2e-sim.sh
#
# Scenarios
#   pass            b1, b2 (default service) and b3 (hardened) pass: verdict=PASS
#   no-job          nothing is queued: the host must fail ("exited without evidence")
#   probe-failure   b1 runs with hardened expectations in the default service: the host must fail
#   pass-split      the same as pass, with the classes in two files (runners.yaml and classes-extra.yaml, merged)
#   terminated      a cancel (SIGTERM) ends the host while its stack runs: it must remove the stack
#
# Needs Docker (privileged containers) and network access (Alpine packages, the stock image).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "${here}/../.." && pwd)
name="swarm-e2e-sim-$$"
stock=${E2E_IMAGE:-cimg/base:2026.10@sha256:64becfab2860932391d834a770033665874e287a655dbef26e38df060414a79a}
dind=${E2E_SIM_DIND_IMAGE:-docker:29.9.0-dind@sha256:0b6d18a4a222e71c88be6034926b4f6cde2fc33c2218643d03ccfddc65995470}
tmp=$(mktemp -d)
failed=0

cleanup() { docker rm -f -v "${name}" > /dev/null 2>&1 || true; rm -rf "${tmp}"; }
trap cleanup EXIT

log() { printf '[e2e-sim] %s\n' "$*"; }
in_vm() { docker exec "${name}" "$@"; }

# --- fixtures: a stack with the contract's shape, and a fake runner entrypoint -----------------
cat > "${tmp}/stack.yaml" <<'YAML'
x-runner: &runner
  image: cimg/base:2026.10
  entrypoint: ["/opt/machine-runner-swarm/bin/circleci-runner-entrypoint"]
  user: "0:0"
  volumes:
    - {type: bind, source: /opt/machine-runner-swarm/current, target: /opt/machine-runner-swarm, read_only: true}
    - {type: bind, source: /repo/ci, target: /ci, read_only: true}
  deploy:
    replicas: 1
    restart_policy: {condition: any, delay: 3s}
services:
  linux-default:
    <<: *runner
    hostname: "{{.Node.Hostname}}-linux-default-{{.Task.Slot}}"
    environment:
      CIRCLECI_RUNNER_NAME: "{{.Node.Hostname}}-linux-default-{{.Task.Slot}}"
      MACHINE_RUNNER_SWARM_JOB_SUDO: "true"
    secrets:
      - {source: linux-default-token, target: circleci_runner_config.yaml, uid: "2000", gid: "2000", mode: 0400}
  linux-hardened:
    <<: *runner
    hostname: "{{.Node.Hostname}}-linux-hardened-{{.Task.Slot}}"
    environment:
      CIRCLECI_RUNNER_NAME: "{{.Node.Hostname}}-linux-hardened-{{.Task.Slot}}"
      MACHINE_RUNNER_SWARM_JOB_SUDO: "false"
    secrets:
      - {source: linux-hardened-token, target: circleci_runner_config.yaml, uid: "2000", gid: "2000", mode: 0400}
  runner-distributor:   # global, like the shipped one: the host script must leave it out of the override and out of the container counts
    image: cimg/base:2026.10
    command: ["sleep", "3600"]
    deploy: {mode: global}
  linux-java:
    <<: *runner
    environment:
      CIRCLECI_RUNNER_NAME: "{{.Node.Hostname}}-linux-java-{{.Task.Slot}}"
    secrets:
      - {source: linux-java-token, target: circleci_runner_config.yaml, uid: "2000", gid: "2000", mode: 0400}
secrets:
  linux-default-token: {external: true}
  linux-hardened-token: {external: true}
  linux-java-token: {external: true}
YAML

# The same stack in two files, as the shipped one is: the default class and the distributor, and the add-on classes (merged by docker stack deploy -c -c).
mkdir "${tmp}/split"
cat > "${tmp}/split/stack.yaml" <<'YAML'
x-runner: &runner
  image: cimg/base:2026.10
  entrypoint: ["/opt/machine-runner-swarm/bin/circleci-runner-entrypoint"]
  user: "0:0"
  volumes:
    - {type: bind, source: /opt/machine-runner-swarm/current, target: /opt/machine-runner-swarm, read_only: true}
    - {type: bind, source: /repo/ci, target: /ci, read_only: true}
  deploy:
    replicas: 1
    restart_policy: {condition: any, delay: 3s}
services:
  linux-default:
    <<: *runner
    hostname: "{{.Node.Hostname}}-linux-default-{{.Task.Slot}}"
    environment:
      CIRCLECI_RUNNER_NAME: "{{.Node.Hostname}}-linux-default-{{.Task.Slot}}"
      MACHINE_RUNNER_SWARM_JOB_SUDO: "true"
    secrets:
      - {source: linux-default-token, target: circleci_runner_config.yaml, uid: "2000", gid: "2000", mode: 0400}
  runner-distributor:
    image: cimg/base:2026.10
    command: ["sleep", "3600"]
    deploy: {mode: global}
secrets:
  linux-default-token: {external: true}
YAML
cat > "${tmp}/split/classes-extra.yaml" <<'YAML'
x-runner: &runner
  image: cimg/base:2026.10
  entrypoint: ["/opt/machine-runner-swarm/bin/circleci-runner-entrypoint"]
  user: "0:0"
  volumes:
    - {type: bind, source: /opt/machine-runner-swarm/current, target: /opt/machine-runner-swarm, read_only: true}
    - {type: bind, source: /repo/ci, target: /ci, read_only: true}
  deploy:
    replicas: 1
    restart_policy: {condition: any, delay: 3s}
services:
  linux-hardened:
    <<: *runner
    hostname: "{{.Node.Hostname}}-linux-hardened-{{.Task.Slot}}"
    environment:
      CIRCLECI_RUNNER_NAME: "{{.Node.Hostname}}-linux-hardened-{{.Task.Slot}}"
      MACHINE_RUNNER_SWARM_JOB_SUDO: "false"
    secrets:
      - {source: linux-hardened-token, target: circleci_runner_config.yaml, uid: "2000", gid: "2000", mode: 0400}
  linux-java:
    <<: *runner
    environment:
      CIRCLECI_RUNNER_NAME: "{{.Node.Hostname}}-linux-java-{{.Task.Slot}}"
    secrets:
      - {source: linux-java-token, target: circleci_runner_config.yaml, uid: "2000", gid: "2000", mode: 0400}
secrets:
  linux-hardened-token: {external: true}
  linux-java-token: {external: true}
YAML

cat > "${tmp}/circleci-runner-entrypoint" <<'SH'
#!/bin/sh
# Fake single-task runner: runs the next queued probe as the job user, then exits 0.
set -eu
ev=/e2e-evidence
[ -n "${CIRCLECI_RUNNER_NAME:-}" ] || exit 80
[ -s /run/secrets/circleci_runner_config.yaml ] || exit 80
if [ "${MACHINE_RUNNER_SWARM_JOB_SUDO:-true}" = false ]; then rm -f /usr/bin/sudo /etc/sudoers.d/*; fi
wf=$(sed -n 's/^workflow=//p' "${ev}/host")
instance=$(cat /proc/sys/kernel/random/uuid)
if [ "${MACHINE_RUNNER_SWARM_JOB_SUDO:-true}" = false ]; then stepdown="setpriv no_new_privs=yes"; else stepdown="sudo no_new_privs=no"; fi
echo "circleci-runner-entrypoint: runner=2000 job=circleci sudo=${MACHINE_RUNNER_SWARM_JOB_SUDO:-true} stepdown=${stepdown} instance=${instance}" >&2
# A process called circleci-runner that belongs to the runner user, as in the real container.
id circleci-runner > /dev/null 2>&1 || useradd -u 2000 -M -s /usr/sbin/nologin circleci-runner
cp /bin/sleep /tmp/circleci-runner
setpriv --reuid=circleci-runner --regid=circleci-runner --clear-groups /tmp/circleci-runner 60 &
sleep 2
for q in b1 b2 b3; do
  [ -e "${ev}/queue/${q}" ] || continue
  # b3 belongs to the hardened service
  if [ "${q}" = b3 ] && [ "${MACHINE_RUNNER_SWARM_JOB_SUDO:-true}" != false ]; then continue; fi
  args=$(cat "${ev}/queue/${q}")
  rm -f "${ev}/queue/${q}"
  rc=0
  # shellcheck disable=SC2086
  setpriv --reuid=circleci --regid=circleci --init-groups \
    env HOME=/home/circleci CIRCLE_WORKFLOW_ID="${wf}" CIRCLE_JOB=sim MACHINE_RUNNER_SWARM_INSTANCE_ID="${instance}" \
    /bin/bash /ci/e2e-probe.sh ${args} || rc=$?
  if [ "${rc}" -eq 0 ]; then echo passed > "${ev}/${q}.${wf}.status"; else echo failed > "${ev}/${q}.${wf}.status"; fi
  exit 0
done
echo "no job queued; idling out"
sleep 20
SH

cat > "${tmp}/setup.sh" <<'SH'
#!/bin/bash
# Fake linux/setup.sh: the swarm and secret steps only (the layout is installed by the simulation).
while [ $# -gt 0 ]; do
  case $1 in
    --swarm-init) docker swarm init > /dev/null 2>&1 || true ;;
    --install) ;;
    --secret) name=$2; IFS= read -r token || true; printf 'api:\n  auth_token: %s\n' "${token}" | docker secret create "${name}-token" - > /dev/null; shift ;;
  esac
  shift
done
SH

cat > "${tmp}/circleci-runner" <<'SH'
#!/bin/sh
echo "circleci-runner (e2e simulation)"
SH
chmod +x "${tmp}/circleci-runner-entrypoint" "${tmp}/circleci-runner" "${tmp}/setup.sh"

# --- the VM ------------------------------------------------------------------------------------
log "starting ${dind%%@*}"
docker run -d --privileged --name "${name}" -e DOCKER_TLS_CERTDIR= \
  -v "${repo}:/repo:ro" -v "${tmp}:/sim:ro" "${dind}" > /dev/null
for _ in $(seq 1 60); do in_vm docker info > /dev/null 2>&1 && break; sleep 1; done
in_vm docker info > /dev/null || { log "the Docker daemon in the simulation did not start"; exit 1; }
in_vm apk add --no-cache bash coreutils gawk sudo > /dev/null
in_vm docker pull -q "${stock}" > /dev/null
in_vm sh -c 'cd /opt && mkdir -p machine-runner-swarm/sim/bin && cp /sim/circleci-runner-entrypoint /sim/circleci-runner machine-runner-swarm/sim/bin/ && chmod 0755 machine-runner-swarm/sim/bin/* && echo sim > machine-runner-swarm/sim/VERSION && ln -s sim machine-runner-swarm/current'

# scenario NAME EXPECTED_EXIT PATTERN [QUEUE_FILE=ARGS ...]
scenario() {
  local scenario=$1 want=$2 pattern=$3 out rc=0 item
  shift 3
  log "scenario ${scenario}"
  in_vm sh -c 'docker swarm leave --force > /dev/null 2>&1; rm -rf /tmp/e2e; mkdir -p /tmp/e2e/evidence/queue'
  in_vm env CIRCLE_WORKFLOW_ID=wf-sim E2E_SETUP=/sim/setup.sh E2E_STACK_FILE="${SIM_STACK:-/sim/stack.yaml}" bash /repo/ci/e2e-host.sh prepare > /dev/null 2>&1 || { log "prepare failed"; failed=1; }
  for item in "$@"; do
    in_vm sh -c "echo '${item#*=}' > /tmp/e2e/evidence/queue/${item%%=*}"
  done
  in_vm chmod -R 0777 /tmp/e2e/evidence
  out=$(in_vm env CIRCLE_WORKFLOW_ID=wf-sim CIRCLE_BUILD_NUM=1 E2E_RUNNER_TOKEN_LINUX=sim-token-value E2E_SETUP=/sim/setup.sh \
    E2E_STACK_FILE="${SIM_STACK:-/sim/stack.yaml}" E2E_DEADLINE_SECONDS=120 bash /repo/ci/e2e-host.sh run 2>&1) || rc=$?
  in_vm env CIRCLE_WORKFLOW_ID=wf-sim bash /repo/ci/e2e-host.sh cleanup > /dev/null 2>&1 || true
  if [ "${rc}" -ne "${want}" ] || ! grep -q -- "${pattern}" <<< "${out}"; then
    log "FAIL ${scenario}: exit ${rc} (wanted ${want}), pattern '${pattern}'"
    echo "${out}" | tail -n 40
    failed=1
  else
    log "ok   ${scenario}: exit ${rc}, found '${pattern}'"
    grep -E '^RESULT|FAIL:' <<< "${out}" | sed 's/^/       /' || true
  fi
  if grep -q 'sim-token-value' <<< "${out}"; then log "FAIL ${scenario}: the token appears in the output"; failed=1; fi
}

scenario pass 0 'verdict=PASS' \
  'b1=b1 --expect-sudo true' 'b2=b2 --previous b1 --expect-sudo true' 'b3=b3 --previous b2 --expect-sudo false'
SIM_STACK=/sim/split/stack.yaml scenario pass-split 0 'verdict=PASS' \
  'b1=b1 --expect-sudo true' 'b2=b2 --previous b1 --expect-sudo true' 'b3=b3 --previous b2 --expect-sudo false'
scenario no-job 1 'exited without evidence'
scenario probe-failure 1 'reported a failure' 'b1=b1 --expect-sudo false'

# A cancel ends the step with SIGTERM while the stack runs: the host must remove the stack, so that no idle service is left to claim the next pipeline's B1.
terminated() {
  local pid left
  log "scenario terminated"
  in_vm sh -c 'docker swarm leave --force > /dev/null 2>&1; rm -rf /tmp/e2e; mkdir -p /tmp/e2e/evidence/queue'
  in_vm env CIRCLE_WORKFLOW_ID=wf-sim E2E_SETUP=/sim/setup.sh E2E_STACK_FILE=/sim/stack.yaml bash /repo/ci/e2e-host.sh prepare > /dev/null 2>&1 || { log "prepare failed"; failed=1; }
  in_vm chmod -R 0777 /tmp/e2e/evidence
  # No job is queued, so the host waits for a probe: that is the state of a cancel. The process is started in the background of the VM.
  pid=$(in_vm sh -c 'env CIRCLE_WORKFLOW_ID=wf-sim CIRCLE_BUILD_NUM=1 E2E_RUNNER_TOKEN_LINUX=sim-token-value E2E_SETUP=/sim/setup.sh E2E_STACK_FILE=/sim/stack.yaml E2E_DEADLINE_SECONDS=300 bash /repo/ci/e2e-host.sh run > /tmp/e2e/host.out 2>&1 & echo $!')
  for _ in $(seq 1 60); do
    [ -n "$(in_vm docker service ls -q 2> /dev/null)" ] && break
    sleep 1
  done
  [ -n "$(in_vm docker service ls -q 2> /dev/null)" ] || { log "FAIL terminated: the host never deployed the stack"; failed=1; return; }
  in_vm kill -TERM "${pid}"
  for _ in $(seq 1 60); do in_vm kill -0 "${pid}" 2> /dev/null || break; sleep 1; done
  left=$(in_vm docker service ls -q 2> /dev/null || true)
  if in_vm kill -0 "${pid}" 2> /dev/null; then
    log "FAIL terminated: the host is still running 60 s after SIGTERM"; failed=1
  elif [ -n "${left}" ] || ! in_vm grep -q 'terminated: removing the stack' /tmp/e2e/host.out; then
    log "FAIL terminated: services left after SIGTERM: '${left}'"; in_vm tail -n 15 /tmp/e2e/host.out; failed=1
  else
    log "ok   terminated: SIGTERM removed the stack"
  fi
}
terminated

[ "${failed}" -eq 0 ] && log "all scenarios passed" || { log "FAILED"; exit 1; }
