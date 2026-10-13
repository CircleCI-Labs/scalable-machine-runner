#!/usr/bin/env bash
# drain.sh: SIGTERM lets a running job finish (stop_grace_period + init + exec). Token-free.
#
# docker stop / docker service update / docker service scale send SIGTERM to the container's init
# (init: true), which forwards it to the runner (the entrypoint exec'd it). The runner then DRAINS: it
# stops claiming tasks and lets the running job complete; Swarm waits up to stop_grace_period (5h5m)
# before it sends SIGKILL.
#   job      fake runner and a 12 second fake job: SIGTERM arrives mid-job, the job must still finish,
#            and the container must exit with code 0 (not 137, a kill)
#   idle     the REAL runner, idle: SIGTERM must end it promptly with exit code 0
#
# Usage: drain.sh
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

session_begin
create_secrets "$SWARM_TEST_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}" linux-persistent
export SWARM_TEST_HOST=$SWARM_TEST_MGR   # the DinD container's hostname is its name; replaces CHANGE-ME

running_task() { # service -> id of its running task
  idocker "$SWARM_TEST_MGR" service ps -q --filter desired-state=running "${STACK}_$1" | head -n 1
}
# restart_and_time SERVICE TASK: `docker service update --force` stops TASK (SIGTERM, then SIGKILL after
# stop_grace_period) and starts a replacement; sets seconds and code (the old task's exit code).
restart_and_time() {
  local start state
  start=$(date +%s)
  idocker "$SWARM_TEST_MGR" service update --force -d "${STACK}_$1" >/dev/null
  for _ in $(seq 1 120); do
    state=$(idocker "$SWARM_TEST_MGR" inspect -f '{{.Status.State}}' "$2")
    case $state in complete | shutdown | failed | rejected) break ;; esac
    sleep 1
  done
  [[ $state == complete || $state == shutdown || $state == failed ]] || fail "$1 did not stop within 120s of SIGTERM (state $state)"
  seconds=$(($(date +%s) - start))
  code=$(idocker "$SWARM_TEST_MGR" inspect -f '{{.Status.ContainerStatus.ExitCode}}' "$2")
}

# --- a running job survives SIGTERM -----------------------------------------------------------
install_swarm "$SWARM_TEST_MGR" fake
make_override "$work/ov.yaml" "linux-persistent 1 FAKE_JOB_INTERVAL=1 FAKE_JOB_SLEEP=12"
deploy_stack "$SWARM_TEST_MGR" "$work/ov.yaml" runners.yaml persistent.yaml
wait_for 120 bash -c "docker exec $SWARM_TEST_MGR docker service logs --raw ${STACK}_linux-persistent 2>/dev/null | grep -q '^FAKEJOB'" ||
  fail "the fake job did not start"
log "job running; sending SIGTERM through a forced update"
old_task=$(running_task linux-persistent)
old_container=$(idocker "$SWARM_TEST_MGR" inspect -f '{{.Status.ContainerStatus.ContainerID}}' "$old_task")
restart_and_time linux-persistent "$old_task"
logs=$(idocker "$SWARM_TEST_MGR" logs "$old_container" 2>&1)   # the old container only; its replacement starts its own job
started=$(grep -c '^FAKEJOB' <<< "$logs" || true)
ended=$(grep -c '^JOBEND' <<< "$logs" || true)
order=$(grep -E '^(FAKEJOB|JOBEND|FAKERUNNER draining)' <<< "$logs" | sed -E 's/ .*//' | paste -sd, -)
echo "RESULT test=drain phase=job jobs_started=$started jobs_finished=$ended exit_code=$code seconds_to_stop=$seconds order=$order"
[[ $started -eq 1 && $ended -eq 1 && $code -eq 0 ]] || fail "SIGTERM interrupted the running job (started=$started finished=$ended exit=$code)"
[[ $order == FAKEJOB,JOBEND,FAKERUNNER ]] || fail "unexpected order of events: $order"
[[ $seconds -ge 3 ]] || fail "the container stopped in ${seconds}s, so the job cannot have been left to finish"

# --- the real runner, idle --------------------------------------------------------------------
# A tiny fake API (fake-api.py, in a cimg container beside the Swarm) lets the real runner get past
# its start-up and idle in the claim loop, as it does against runner.circleci.com.
install_swarm "$SWARM_TEST_MGR" real
inner_reset "$SWARM_TEST_MGR"
create_secrets "$SWARM_TEST_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}"
docker cp "$tests_dir/fake-api.py" "$SWARM_TEST_MGR:/fake-api.py"
idocker "$SWARM_TEST_MGR" run -d --name fake-api --network host -v /fake-api.py:/fake-api.py:ro "$CIMG_IMAGE" python3 /fake-api.py 8099 >/dev/null
api_ip=$(docker exec "$SWARM_TEST_MGR" hostname -i | awk '{ print $1 }')
make_override "$work/ov.yaml" "linux-default 1 CIRCLECI_RUNNER_API_URL=http://$api_ip:8099"
deploy_stack "$SWARM_TEST_MGR" "$work/ov.yaml"
wait_for 120 bash -c "docker exec $SWARM_TEST_MGR docker service logs --raw ${STACK}_linux-default 2>&1 | grep -q 'starting agent'" ||
  fail "the real runner did not start"
sleep 8   # past the task agent download, into the claim loop
restart_and_time linux-default "$(running_task linux-default)"
echo "RESULT test=drain phase=idle-real-runner exit_code=$code seconds_to_stop=$seconds"
[[ $code -eq 0 && $seconds -le 30 ]] || fail "the idle real runner did not stop cleanly on SIGTERM (exit $code after ${seconds}s)"

pass "SIGTERM drains: a running job finishes before the container stops (exit 0), and an idle real runner stops promptly"
