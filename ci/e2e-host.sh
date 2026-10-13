#!/usr/bin/env bash
# Job A of the Linux e2e (see docs/ci.md): hosts the runner as a Docker Swarm service.
#
#   ci/e2e-host.sh prepare   linux/setup.sh --swarm-init --install: a single-node swarm and the
#                            host layout under /opt/machine-runner-swarm
#   ci/e2e-host.sh run       deploy the shipped stack and host probes b1 and b2 on service
#                            linux-default (jobs keep sudo), then probe b3 on service
#                            linux-hardened (no sudo), and print the verdict
#   ci/e2e-host.sh cleanup   remove the stack and its secrets, leave the swarm (always runs)
#   ci/e2e-host.sh sweep     after a failure: start one throwaway runner so that a probe still
#                            queued on the e2e class is claimed and fails fast
#
# What it proves
#   b1   first container: no residue, plants residue, records whether the job user can read
#        the token (without and with sudo)
#   b2   second container (Swarm replaced the finished task): a different container, no
#        residue from b1
#   b3   linux-hardened: no sudo, the token and the runner's environment are unreadable
#
# The stack is the shipped one (E2E_STACK_FILE) with an override layered on top: the active
# service runs one replica of a pinned stock image, every other service has none. The runner
# binary and the entrypoint come from the host through the read-only /opt/machine-runner-swarm mount that the
# shipped stack declares. Both services carry the same e2e class token; only one is deployed
# at a time, so a probe is always claimed by the service it was written for.
#
# Environment
#   E2E_RUNNER_TOKEN_LINUX  resource-class token from the scalable-machine-runner-e2e context.
#                           Goes to setup.sh --secret on stdin; never written to disk, never
#                           printed.
#   E2E_STACK_FILE          stack under test (default linux/stack/runners.yaml)
#   E2E_SERVICE             service for b1 and b2 (default linux-default)
#   E2E_HARDENED_SERVICE    service for b3 (default linux-hardened)
#   E2E_IMAGE               stock image for the active service (default: pinned cimg/base)
#   E2E_SETUP               the helper (default linux/setup.sh; the simulation substitutes a fake)
#   E2E_STACK               stack name (default runners, as in the docs)
#   E2E_ROOT                evidence and logs, stored as artifacts (default /tmp/e2e)
#   E2E_IDLE_TIMEOUT        runner idle_timeout (default 5m: every claim happens within seconds)
#   E2E_MAX_RUN_TIME        runner max_run_time (default 10m)
#   E2E_DEADLINE_SECONDS    hard limit for the whole run (default 2400)
#   E2E_SWEEPER_IMAGE       image for the sweeper (default: pinned circleci/runner-agent)
set -euo pipefail

mode=${1:?usage: e2e-host.sh prepare | run | cleanup | sweep}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "${here}/.." && pwd)

wf=${CIRCLE_WORKFLOW_ID:?CIRCLE_WORKFLOW_ID is not set}
build=${CIRCLE_BUILD_NUM:-local}
root=${E2E_ROOT:-/tmp/e2e}
stack_file=${E2E_STACK_FILE:-${repo}/linux/stack/runners.yaml}
service=${E2E_SERVICE:-linux-default}
hardened=${E2E_HARDENED_SERVICE:-linux-hardened}
image=${E2E_IMAGE:-cimg/base:2026.10@sha256:64becfab2860932391d834a770033665874e287a655dbef26e38df060414a79a}
setup=${E2E_SETUP:-${repo}/linux/setup.sh}
stack=${E2E_STACK:-swarm}
idle=${E2E_IDLE_TIMEOUT:-5m}
max_run=${E2E_MAX_RUN_TIME:-10m}
deadline_s=${E2E_DEADLINE_SECONDS:-2400}
sweeper_image=${E2E_SWEEPER_IMAGE:-circleci/runner-agent:machine-3.1.12-9831-dca4a16@sha256:2f134114a67c9fd790f6185e107135dbbcb331be9da80ef8d7d9cca2e12f18b8}
evidence_dir="${root}/evidence"
log_dir="${root}/logs"
events_log="${log_dir}/events.log"
service_log="${log_dir}/service.log"
override="${log_dir}/stack.e2e.yaml"
start_seconds=${SECONDS}
logs_pid=
events_pid=

log() { printf '[e2e-host %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "FAIL: $*"; exit 1; }

evidence() { echo "${evidence_dir}/$1.${wf}"; }
field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
elapsed() { echo $((SECONDS - start_seconds)); }
rel() { echo "${1#"${repo}"/}"; }

# ---------------------------------------------------------------------------
# prepare: swarm and host layout, with the shipped helper
# ---------------------------------------------------------------------------
prepare() {
  docker version --format 'docker client {{.Client.Version}}, server {{.Server.Version}}'
  log "sudo $(rel "${setup}") --swarm-init --install"
  sudo "${setup}" --swarm-init --install
  docker node ls
  ls -l /opt/machine-runner-swarm /opt/machine-runner-swarm/bin
  /opt/machine-runner-swarm/bin/circleci-runner --version
}

# ---------------------------------------------------------------------------
# Stack files
# ---------------------------------------------------------------------------
rendered_services() {
  docker stack config -c "${stack_file}" | awk '/^services:/{s=1;next} /^[^ ]/{s=0} s && /^  [^ ]/{sub(/^  /,"");sub(/:$/,"");print}'
}
rendered_secrets() {
  docker stack config -c "${stack_file}" | awk '/^secrets:/{s=1;next} /^[^ ]/{s=0} s && /^    name:/{print $2}'
}

# write_override ACTIVE_SERVICE: one replica of the pinned image for it, none for the others.
write_override() {
  local active=$1 s
  {
    echo "# Generated by ci/e2e-host.sh: e2e settings layered on $(rel "${stack_file}")."
    echo "services:"
    for s in $(rendered_services); do
      if [ "${s}" = "${active}" ]; then
        cat <<EOF
  ${s}:
    image: ${image}
    environment:
      CIRCLECI_RUNNER_IDLE_TIMEOUT: "${idle}"
      CIRCLECI_RUNNER_MAX_RUN_TIME: "${max_run}"
    volumes:
      - type: bind
        source: ${evidence_dir}
        target: /e2e-evidence
    deploy:
      replicas: 1
EOF
      else
        printf '  %s:\n    deploy:\n      replicas: 0\n' "${s}"
      fi
    done
  } > "${override}"
}

# The e2e token backs the two services under test (through the helper, as the docs describe);
# every other secret of the stack gets a placeholder so that the deploy resolves.
create_secrets() {
  local name svc
  for svc in "${service}" "${hardened}"; do
    printf '%s' "${E2E_RUNNER_TOKEN_LINUX}" | sudo "${setup}" --secret "${svc}" > /dev/null 2>&1 ||
      die "setup.sh --secret ${svc} failed"
  done
  for name in $(rendered_secrets); do
    case ${name} in "${service}-token" | "${hardened}-token") continue ;; esac
    printf 'unused' | docker secret create "${name}" - > /dev/null
  done
  log "secrets: $(docker secret ls --format '{{.Name}}' | tr '\n' ' ')"
}

deploy() {  # deploy ACTIVE_SERVICE
  write_override "$1"
  log "deploying ${stack}_$1 from $(rel "${stack_file}") + override: image=${image%%@*} idle_timeout=${idle} max_run_time=${max_run}"
  docker stack deploy --detach=true -c "${stack_file}" -c "${override}" "${stack}"
}

remove_stack() {
  docker stack rm "${stack}" > /dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    [ -z "$(docker ps -aq --filter "label=com.docker.stack.namespace=${stack}")" ] && return 0
    sleep 1
  done
  log "stack ${stack} still has containers after 60s; removing them"
  docker ps -aq --filter "label=com.docker.stack.namespace=${stack}" | xargs -r docker rm -f -v > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Watching
# ---------------------------------------------------------------------------
token_rejected() {
  grep -qE '401 \(Unauthorized\)|status code: 401' "${service_log}" 2>/dev/null
}

event_count() { grep -c "^$1 " "${events_log}" 2>/dev/null || true; }

# nth_start SERVICE N: ID of the Nth container (1-based) that Swarm started for SERVICE.
nth_start() {
  awk -v svc="${stack}_$1" -v n="$2" '$1 == "start" && $5 == svc { if (++i == n) { print $2; exit } }' "${events_log}"
}

# wait_probe PROBE DIES_BEFORE: wait until the probe job's last step reported its status,
# then until its container exited 0. DIES_BEFORE is the number of container exits that
# belong to earlier probes.
wait_probe() {
  local probe=$1 dies_before=$2 ev st dies printed=0 lines last_note=0
  ev=$(evidence "${probe}")
  log "waiting for probe ${probe}"
  while :; do
    sleep 3
    lines=$(wc -l < "${service_log}" 2>/dev/null || echo 0)
    if [ "${lines}" -gt "${printed}" ]; then
      # The full runner log is an artifact; print what explains a failure.
      sed -n "$((printed + 1)),${lines}p" "${service_log}" |
        grep -E 'circleci-runner-entrypoint:|rror|denied|401|could not|failed' | cut -c1-260 | sed 's/^/  runner: /' | tail -n 8 || true
      printed=${lines}
    fi
    token_rejected && die "the runner token was rejected (401). Rotate E2E_RUNNER_TOKEN_LINUX in the context."
    if [ -s "${ev}" ] && [ -s "${ev}.status" ]; then
      st=$(cat "${ev}.status")
      log "probe ${probe}: result=$(field "${ev}" result) residue=$(field "${ev}" residue) status=${st}"
      [ "$(field "${ev}" result)" = pass ] || die "probe ${probe} reported a failure (see its job log and ${ev##*/})"
      [ "${st}" = passed ] || die "probe job ${probe} did not pass (status: ${st}); see its job log"
      break
    fi
    dies=$(event_count die)
    if [ "${dies}" -gt "${dies_before}" ] && [ ! -s "${ev}" ]; then
      die "the container for probe ${probe} exited without evidence: the runner idled out (${idle}) without claiming it, or claimed a job that is not ours"
    fi
    [ "$(elapsed)" -lt "${deadline_s}" ] || die "deadline of ${deadline_s}s reached while waiting for probe ${probe}"
    if [ $((SECONDS - last_note)) -ge 60 ]; then
      log "still waiting for probe ${probe} (containers exited: ${dies}, elapsed $(elapsed)s)"
      last_note=${SECONDS}
    fi
  done
  # Single-task: the runner exits when the job is done, and Swarm starts the next container.
  for _ in $(seq 1 90); do
    [ "$(event_count die)" -gt "${dies_before}" ] && break
    sleep 1
  done
  [ "$(event_count die)" -gt "${dies_before}" ] || die "the container for probe ${probe} did not exit after its job (single-task runner)"
}

follow_logs() {  # follow_logs SERVICE
  docker service logs --follow --raw --no-task-ids --timestamps "${stack}_$1" >> "${service_log}" 2>&1 &
  logs_pid=$!
}
stop_logs() {
  if [ -n "${logs_pid}" ]; then kill "${logs_pid}" 2>/dev/null || true; fi
  logs_pid=
}

# ---------------------------------------------------------------------------
host() {
  [ -n "${E2E_RUNNER_TOKEN_LINUX:-}" ] || die "E2E_RUNNER_TOKEN_LINUX is empty. The setup gate only schedules this job when the scalable-machine-runner-e2e context provides it, so the context or its restrictions changed."
  [ -r "${stack_file}" ] || die "$(rel "${stack_file}") is missing"
  [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = active ] || die "this node is not a swarm manager (run: ci/e2e-host.sh prepare)"
  # Into variables first: `... | grep -q` under pipefail fails when grep exits before the writer does.
  local services secrets svc
  services=$(rendered_services); secrets=$(rendered_secrets)
  for svc in "${service}" "${hardened}"; do
    grep -qx "${svc}" <<< "${services}" || die "$(rel "${stack_file}") has no service ${svc}"
    grep -qx "${svc}-token" <<< "${secrets}" || die "$(rel "${stack_file}") has no external secret ${svc}-token"
  done

  mkdir -p "${evidence_dir}" "${log_dir}"
  chmod 0777 "${evidence_dir}"            # the job runs as an unprivileged user inside the container
  {
    echo "workflow=${wf}"
    echo "host_build=${build}"
    echo "image=${image}"
    echo "stack_file=$(rel "${stack_file}")"
    echo "started=$(date -u +%FT%TZ)"
  } > "${evidence_dir}/host"
  chmod 0644 "${evidence_dir}/host"

  create_secrets

  # Container lifecycle and runner output, independent of anything the probes write.
  : > "${events_log}"; : > "${service_log}"
  docker events --filter type=container --filter "label=com.docker.stack.namespace=${stack}" \
    --filter event=start --filter event=die \
    --format '{{.Action}} {{.Actor.ID}} {{or (index .Actor.Attributes "exitCode") "-"}} {{index .Actor.Attributes "com.docker.swarm.task.id"}} {{index .Actor.Attributes "com.docker.swarm.service.name"}}' \
    >> "${events_log}" 2>&1 &
  events_pid=$!
  trap 'kill "${events_pid}" 2>/dev/null || true; stop_logs' EXIT

  # Phase 1: linux-default (the job user keeps sudo), two jobs, two containers.
  deploy "${service}"
  follow_logs "${service}"
  wait_probe b1 0
  wait_probe b2 1
  # Remove the stack at once: its replacement container must not claim the next probe.
  remove_stack
  stop_logs

  # Phase 2: linux-hardened (no sudo), one job in a third container.
  deploy "${hardened}"
  follow_logs "${hardened}"
  wait_probe b3 2
  remove_stack
  stop_logs
  sleep 2                                  # let docker events flush the last die event

  verify
}

verify() {
  local ok=1 starts dies ids codes p ev
  starts=$(event_count start); dies=$(event_count die)
  ids=$(awk '$1 == "start" {print $2}' "${events_log}" | sort -u | wc -l)
  codes=$(awk '$1 == "die" {print $3}' "${events_log}" | sort -u | tr '\n' ' ')
  log "containers: started=${starts} exited=${dies} distinct=${ids} exit_codes=[${codes% }]"
  [ "${starts}" -ge 3 ] && [ "${dies}" -ge 3 ] || { log "expected at least 3 containers (b1, b2, b3)"; ok=0; }
  [ "${ids}" -ge 3 ] || { log "expected 3 distinct container IDs"; ok=0; }
  [ "${codes% }" = 0 ] || { log "expected every runner container to exit 0"; ok=0; }

  for p in b1 b2 b3; do
    ev=$(evidence "${p}")
    if [ ! -s "${ev}" ]; then log "no evidence from ${p}"; ok=0; continue; fi
    echo "--- evidence ${p}"; cat "${ev}"
    [ "$(field "${ev}" workflow)" = "${wf}" ] || { log "${p}: evidence is from another workflow"; ok=0; }
    [ "$(field "${ev}" result)" = pass ] || { log "${p}: result is not pass"; ok=0; }
    [ "$(field "${ev}" residue)" = "[]" ] || { log "${p}: found residue"; ok=0; }
    [ "$(field "${ev}" token_nosudo)" = denied ] || { log "${p}: the job user could read the token without sudo"; ok=0; }
  done

  # Each probe ran in the container that Swarm started for it, and no two share anything.
  local c1 c2 c3 l1 l2 l3
  c1=$(field "$(evidence b1)" container_id); c2=$(field "$(evidence b2)" container_id); c3=$(field "$(evidence b3)" container_id)
  l1=$(field "$(evidence b1)" layer); l2=$(field "$(evidence b2)" layer); l3=$(field "$(evidence b3)" layer)
  [ "${c1}" = "$(nth_start "${service}" 1)" ] && [ -n "${c1}" ] || { log "b1 did not run in the first ${service} container (${c1:-none} vs $(nth_start "${service}" 1))"; ok=0; }
  [ "${c2}" = "$(nth_start "${service}" 2)" ] && [ -n "${c2}" ] || { log "b2 did not run in the second ${service} container (${c2:-none} vs $(nth_start "${service}" 2))"; ok=0; }
  [ "${c3}" = "$(nth_start "${hardened}" 1)" ] && [ -n "${c3}" ] || { log "b3 did not run in the first ${hardened} container (${c3:-none} vs $(nth_start "${hardened}" 1))"; ok=0; }
  if [ "${c1}" = "${c2}" ] || [ "${c1}" = "${c3}" ] || [ "${c2}" = "${c3}" ]; then log "b1, b2 and b3 must run in different containers"; ok=0; fi
  if [ "${l1}" = "${l2}" ] || [ "${l1}" = "${l3}" ] || [ "${l2}" = "${l3}" ]; then log "two probes share a writable layer"; ok=0; fi
  # The step-down: the entrypoint logs the way jobs are stepped down to the job user.
  local stepdown
  stepdown=$(grep -oE 'stepdown=[a-z]+' "${service_log}" | sort -u | paste -sd, -)
  log "step-down used by the entrypoint: ${stepdown:-none}"
  [ "${stepdown}" = stepdown=sudo ] || { log "expected every container to step jobs down with sudo (got: ${stepdown:-none})"; ok=0; }
  for p in b1 b2 b3; do
    [ "$(field "$(evidence ${p})" user)" = circleci ] && [ "$(field "$(evidence ${p})" runner_user)" = circleci-runner ] ||
      { log "${p}: expected job user circleci and runner user circleci-runner"; ok=0; }
    [ "$(field "$(evidence ${p})" token_env)" = absent ] && [ "$(field "$(evidence ${p})" token_ps)" = absent ] ||
      { log "${p}: the token is in the job environment or on a command line"; ok=0; }
  done

  # Hardened: no sudo, so no way to the token.
  ev=$(evidence b3)
  [ "$(field "${ev}" sudo_works)" = no ] || { log "b3: sudo works in ${hardened}"; ok=0; }
  [ "$(field "${ev}" token_sudo)" != readable ] || { log "b3: ${hardened} lets the job read the token with sudo"; ok=0; }

  local verdict=PASS
  [ "${ok}" -eq 1 ] || verdict=FAIL
  echo "RESULT e2e=linux probes=3 distinct_containers=${ids} b2_residue=$(field "$(evidence b2)" residue)" \
    "job_user=$(field "$(evidence b1)" user) runner_user=$(field "$(evidence b1)" runner_user) ${stepdown} token_in_job_env=$(field "$(evidence b1)" token_env) token_on_command_line=$(field "$(evidence b1)" token_ps)" \
    "token_default_nosudo=$(field "$(evidence b1)" token_nosudo) token_default_sudo=$(field "$(evidence b1)" token_sudo) runner_env_via_sudo_default=$(field "$(evidence b1)" runner_environ_via_sudo)" \
    "token_hardened_nosudo=$(field "$(evidence b3)" token_nosudo) token_hardened_sudo=$(field "$(evidence b3)" token_sudo) hardened_sudo_works=$(field "$(evidence b3)" sudo_works) verdict=${verdict}" \
    | tee "${root}/result.txt"
  [ "${ok}" -eq 1 ]
}

# ---------------------------------------------------------------------------
cleanup() {
  log "cleanup: removing stack ${stack}, its secrets, and leaving the swarm"
  remove_stack
  docker secret ls -q 2> /dev/null | xargs -r docker secret rm > /dev/null 2>&1 || true
  docker swarm leave --force > /dev/null 2>&1 || true
  log "cleanup: swarm state is now $(docker info --format '{{.Swarm.LocalNodeState}}')"
}

sweep() {
  local b1 b2 b3
  b1=$(evidence b1); b2=$(evidence b2); b3=$(evidence b3)
  if [ -s "${b3}" ]; then log "sweep: b3 already ran; nothing can be queued"; return 0; fi
  if [ -s "${b1}" ] && [ "$(field "${b1}" result)" != pass ]; then
    log "sweep: b1 failed, so b2 and b3 were never queued"; return 0
  fi
  if [ -s "${b2}" ] && [ "$(field "${b2}" result)" != pass ]; then
    log "sweep: b2 failed, so b3 was never queued"; return 0
  fi
  if [ -z "${E2E_RUNNER_TOKEN_LINUX:-}" ]; then
    log "sweep: no token; cancel workflow ${wf} in the UI if a probe is still queued"; return 0
  fi
  log "sweep: starting a throwaway runner (idle_timeout 2m) so a queued probe is claimed and fails fast"
  export CIRCLECI_RUNNER_API_AUTH_TOKEN="${E2E_RUNNER_TOKEN_LINUX}"
  timeout 420 docker run --rm --name "swarm-e2e-sweeper-${build}" \
    -e CIRCLECI_RUNNER_API_AUTH_TOKEN \
    -e "CIRCLECI_RUNNER_NAME=e2e-sweeper-${build}" \
    -e CIRCLECI_RUNNER_MODE=single-task \
    -e CIRCLECI_RUNNER_IDLE_TIMEOUT=2m \
    -e CIRCLECI_RUNNER_MAX_RUN_TIME=5m \
    "${sweeper_image}" > "${log_dir}/sweeper.log" 2>&1 || true
  docker rm -f "swarm-e2e-sweeper-${build}" > /dev/null 2>&1 || true
  tail -n 6 "${log_dir}/sweeper.log" | cut -c1-200 || true
  log "sweep: done. If a probe is still queued, cancel workflow ${wf} in the UI."
  return 0
}

mkdir -p "${log_dir}"
case "${mode}" in
  prepare) prepare ;;
  run) host ;;
  cleanup) cleanup ;;
  sweep) sweep ;;
  *) die "unknown mode ${mode}" ;;
esac
