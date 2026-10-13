#!/usr/bin/env bash
# exit80.sh: a configuration error (exit 80) must not become a hot loop under Swarm. Token-free.
#
# Swarm cannot tell exit 80 from a finished job: restart_policy "any" starts a new task every time,
# forever. What protects the host is the restart delay (10s in runners.yaml); this test measures it.
# Two ways to get exit 80, both with the REAL runner binary and the real stack file:
#   empty-token  the secret is a config file without a token: the runner exits 80
#                ("api.auth_token must be set")
#   bad-setting  CIRCLECI_RUNNER_LOGGING_LEVEL=bogus: the runner rejects it and exits 80
# For each: over WAIT seconds the service must create only a few tasks (about WAIT/delay, not
# hundreds), each task must have exited with code 80, and the gaps between container starts must
# honour the delay. A third check (no-config-file) shows the one case that exits 1, not 80: the
# secret is not attached, so --config points at a file that does not exist.
#
# Usage: exit80.sh        Env: WAIT=45 (seconds to observe each case)
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
WAIT=${WAIT:-45}

session_begin
install_swarm "$SWARM_TEST_MGR" real

# observe CASE: sets tasks, bad_codes, min_gap, gaps for the tasks of linux-default so far.
observe() {
  local ids id code created prev=0 ts state
  tasks=0 bad_codes=0 min_gap=999999 gaps=
  ids=$(idocker "$SWARM_TEST_MGR" service ps -q "${STACK}_linux-default")
  for id in $ids; do
    tasks=$((tasks + 1))
    code=$(idocker "$SWARM_TEST_MGR" inspect -f '{{.Status.ContainerStatus.ExitCode}}' "$id" 2> /dev/null || echo none)
    # a task that is still starting or running has no exit code yet
    state=$(idocker "$SWARM_TEST_MGR" inspect -f '{{.Status.State}}' "$id")
    if [[ $state == failed || $state == complete || $state == shutdown ]]; then
      [[ $code == 80 ]] || bad_codes=$((bad_codes + 1))
    fi
  done
  # Swarm creates the replacement task at once but starts its container only after the restart
  # delay, so measure the gaps between container starts: the time of each task's error message.
  while read -r ts; do
    created=$(date -d "$ts" +%s)
    if [[ $prev -ne 0 ]]; then
      gaps="$gaps$((created - prev)),"
      [[ $((created - prev)) -lt $min_gap ]] && min_gap=$((created - prev))
    fi
    prev=$created
  done < <(idocker "$SWARM_TEST_MGR" service logs -t --raw "${STACK}_linux-default" 2>&1 | grep -E 'circleci-runner: error' | cut -d' ' -f1 | sort)
  [[ $min_gap -ne 999999 ]] || min_gap=0
}

run_case() { # name token-value ENV...
  local name=$1 token=$2 env_spec=$3 started
  inner_reset "$SWARM_TEST_MGR"
  create_secrets "$SWARM_TEST_MGR" "$token" "${BASE_SERVICES[@]}"
  make_override "$work/ov.yaml" "linux-default 1 $env_spec"
  started=$(date +%s)
  deploy_stack "$SWARM_TEST_MGR" "$work/ov.yaml"
  log "case $name: observing for ${WAIT}s"
  sleep "$WAIT"
  observe
  local elapsed=$(($(date +%s) - started))
  local logs
  logs=$(service_logs "$SWARM_TEST_MGR" linux-default | grep -E 'circleci-runner: error' | sort | uniq -c | head -n 3 | tr '\n' ';' | cut -c1-300)
  echo "RESULT test=exit80 case=$name tasks=$tasks seconds=$elapsed restart_delay=10s min_gap=${min_gap}s gaps=${gaps%,} tasks_not_exit_80=$bad_codes"
  echo "       message: $logs"
  # Without a delay a 1s-per-container loop would create ~$WAIT tasks. With delay 10s: about WAIT/10 + 1.
  [[ $tasks -ge 3 && $tasks -le $((WAIT / 10 + 3)) ]] || fail "case $name created $tasks tasks in ${elapsed}s: not the expected ~$((WAIT / 10 + 1))"
  [[ $bad_codes -eq 0 ]] || fail "case $name: $bad_codes task(s) did not exit with code 80"
  [[ $min_gap -ge 8 ]] || fail "case $name: tasks were created only ${min_gap}s apart, the 10s restart delay is not honoured"
}

run_case empty-token "" ""
run_case bad-setting "$SENTINEL_TOKEN" "CIRCLECI_RUNNER_LOGGING_LEVEL=bogus"

inner_reset "$SWARM_TEST_MGR"
out=$(idocker "$SWARM_TEST_MGR" run --rm --user 0 --entrypoint /opt/machine-runner-swarm/bin/circleci-runner-entrypoint -v /opt/machine-runner-swarm:/opt/machine-runner-swarm:ro \
  -e CIRCLECI_RUNNER_NAME=x "$CIMG_IMAGE" 2>&1) && rc=0 || rc=$?
echo "RESULT test=exit80 case=no-config-file exit=$rc message=\"$(grep -o 'circleci-runner: error.*' <<< "$out" | cut -c1-120)\""
[[ $rc -eq 1 ]] || fail "a missing config file should make the runner exit 1, got $rc"

pass "exit 80 restarts about every 10s (the Swarm restart delay) with the same cause each time; no hot loop; the runner's exit code passes through the entrypoint"
