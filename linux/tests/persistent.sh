#!/usr/bin/env bash
# persistent.sh: continuous mode (CIRCLECI_RUNNER_MODE=continuous) keeps ONE container across jobs.
# Token-free: the real linux/stack/persistent.yaml overlay (node.hostname edited the way its comment says), the real smr-entrypoint, and a fake runner that runs a fake job every second.
#
# Phases:
#   reuse   JOBS jobs in the SAME container, and residue from earlier jobs is visible (the price of
#           persistence); the task is never restarted
#   volume  `docker service update --force` replaces the container: SIGTERM drains the runner, the new
#           container has a new filesystem, and only the named volume (the job home) survives
#
# Usage: persistent.sh        Env: JOBS=4, TIMEOUT=180
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
JOBS=${JOBS:-4}
TIMEOUT=${TIMEOUT:-180}

session_begin
install_smr "$SMR_MGR" fake
create_secrets "$SMR_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}" linux-persistent
export SMR_HOST=$SMR_MGR   # the DinD container's hostname is its name; replaces CHANGE-ME
make_override "$work/ov.yaml" "linux-persistent 1 FAKE_JOB_INTERVAL=1"
deploy_stack "$SMR_MGR" "$work/ov.yaml" runners.yaml persistent.yaml

jobs_lines() { service_logs "$SMR_MGR" linux-persistent | grep FAKEJOB; }

log "waiting for $JOBS jobs from the persistent runner"
wait_for "$TIMEOUT" bash -c "[ \$(docker exec $SMR_MGR docker service logs --raw ${STACK}_linux-persistent 2>/dev/null | grep -c FAKEJOB) -ge $JOBS ]" ||
  fail "fewer than $JOBS jobs ran within ${TIMEOUT}s"
lines=$(jobs_lines | head -n "$JOBS")
printf '%s\n' "$lines"
total=$(grep -c FAKEJOB <<< "$lines" || true)
dirty=$(grep -vc 'residue=\[\]' <<< "$lines" || true)
ids=$(grep -oE 'layer=[0-9a-f]+' <<< "$lines" | sort -u | wc -l)
first_layer=$(grep -oE 'layer=[0-9a-f]+' <<< "$lines" | head -n 1)
tasks=$(idocker "$SMR_MGR" service ps -q "${STACK}_linux-persistent" | wc -l)
echo "RESULT test=persistent phase=reuse jobs=$total distinct_containers=$ids jobs_with_residue=$dirty tasks=$tasks"
[[ $total -eq $JOBS && $ids -eq 1 && $dirty -eq $((JOBS - 1)) && $tasks -eq 1 ]] ||
  fail "continuous mode did not keep one container across jobs (expected 1 container, residue in every job but the first, 1 task)"

# --- replace the container --------------------------------------------------------------------
idocker "$SMR_MGR" service update --force --detach "${STACK}_linux-persistent" >/dev/null
wait_for "$TIMEOUT" bash -c "docker exec $SMR_MGR docker service logs --raw ${STACK}_linux-persistent 2>/dev/null | grep FAKEJOB | grep -qv '$first_layer'" ||
  fail "no job ran in the replacement container"
new_line=$(jobs_lines | grep -v "$first_layer" | head -n 1)
echo "$new_line"
drained=no
service_logs "$SMR_MGR" linux-persistent | grep -q 'FAKERUNNER draining' && drained=yes
residue=$(sed -n 's/.*residue=\[\(.*\)\]/\1/p' <<< "$new_line")
volume=no
container_gone=yes
[[ $residue == *"/home/circleci/.job-marker"* ]] && volume=yes
for f in /tmp/.job-marker /var/opt/circleci/workdir/.job-marker /etc/job-marker; do
  [[ $residue == *"$f"* ]] && container_gone=no
done
echo "RESULT test=persistent phase=volume new_container=yes drained_on_sigterm=$drained survived_in_volume=$volume container_state_gone=$container_gone residue=[$residue]"
[[ $drained == yes && $volume == yes && $container_gone == yes ]] ||
  fail "after the container was replaced, only the named volume should keep state"

pass "continuous mode keeps one container (and its residue) across jobs; the named volume survives replacement"
