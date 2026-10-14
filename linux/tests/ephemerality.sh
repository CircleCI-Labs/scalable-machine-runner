#!/usr/bin/env bash
# ephemerality.sh: every job gets a brand-new container with a clean filesystem. Token-free.
#
# Deploys the real linux/stack/runners.yaml (service linux-default) into a single-node Swarm inside a
# DinD container. The real circleci-runner-entrypoint runs, but a fake runner (fake-runner.sh) stands in for
# circleci-runner and runs a fake job (fake-job.sh) through the real command_prefix step-down. The job
# reports residue left by earlier jobs, then leaves residue in $HOME, /tmp, the working directory and
# /etc. Swarm's restart_policy "any" must give every job a NEW container, so residue never shows up.
#
# Phases:
#   swarm            JOBS jobs through Swarm: distinct containers, no residue
#   negative-control the same job through "docker run --restart always" (what plain Compose does):
#                    ONE container, residue appears. If this phase passed while seeing nothing, the
#                    detector would be blind, so it MUST see leakage
#
# Usage: ephemerality.sh        Env: JOBS=4, TIMEOUT=240
# Prints "RESULT ..." lines and PASS/FAIL. Exit 0 on pass.
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
JOBS=${JOBS:-4}
TIMEOUT=${TIMEOUT:-240}

session_begin
publish_runner fake
create_secrets "$SWARM_TEST_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}"

summarise() { # LINES -> sets total, dirty, ids
  total=$(grep -c FAKEJOB <<< "$1" || true)
  dirty=$(grep FAKEJOB <<< "$1" | grep -vc 'residue=\[\]' || true)
  ids=$(grep -oE 'layer=[0-9a-f]+' <<< "$1" | sort -u | wc -l)
}

# --- phase 1: Swarm ---------------------------------------------------------------------------
make_override "$work/ov.yaml" 'linux-default 2'
deploy_stack "$SWARM_TEST_MGR" "$work/ov.yaml"
log "waiting for $JOBS jobs from linux-default (2 replicas)"
wait_for "$TIMEOUT" bash -c "[ \$(docker exec $SWARM_TEST_MGR docker service logs --raw ${STACK}_linux-default 2>/dev/null | grep -c FAKEJOB) -ge $JOBS ]" ||
  fail "fewer than $JOBS jobs ran within ${TIMEOUT}s"
lines=$(service_logs "$SWARM_TEST_MGR" linux-default | grep FAKEJOB | head -n "$JOBS")
printf '%s\n' "$lines"
summarise "$lines"
tasks=$(idocker "$SWARM_TEST_MGR" service ps -q "${STACK}_linux-default" | wc -l)
names=$(grep -oE 'name=[^ ]+' <<< "$lines" | sort -u | paste -sd, -)
users=$(grep -oE ' user=[^ ]+' <<< "$lines" | sed 's/ user=//' | sort -u | paste -sd, -)
echo "RESULT test=ephemerality phase=swarm jobs=$total distinct_containers=$ids jobs_with_residue=$dirty tasks=$tasks job_user=$users runner_names=$names"
[[ $total -eq $JOBS && $ids -eq $JOBS && $dirty -eq 0 ]] || fail "state leaked between jobs, or fewer containers than jobs"
[[ $users == circleci ]] || fail "jobs did not run as the unprivileged job user (got $users)"

# --- phase 2: negative control ----------------------------------------------------------------
idocker "$SWARM_TEST_MGR" service scale "${STACK}_linux-default=0" >/dev/null 2>&1 || true
idocker "$SWARM_TEST_MGR" run -d --name eph-control --restart always --user 0 --entrypoint /circleci-runner-entrypoint \
  -v /entrypoint/circleci-runner-entrypoint:/circleci-runner-entrypoint:ro -v "${STACK}_runner-bin:/opt/machine-runner-swarm:ro" \
  -e CIRCLECI_RUNNER_NAME=eph-control "$CIMG_IMAGE" >/dev/null
wait_for 60 bash -c "[ \$(docker exec $SWARM_TEST_MGR docker logs eph-control 2>&1 | grep -c FAKEJOB) -ge 3 ]" ||
  fail "the negative control did not run 3 jobs"
lines=$(idocker "$SWARM_TEST_MGR" logs eph-control 2>&1 | grep FAKEJOB | head -n 3)
idocker "$SWARM_TEST_MGR" rm -f eph-control >/dev/null
summarise "$lines"
echo "RESULT test=ephemerality phase=negative-control jobs=$total distinct_containers=$ids jobs_with_residue=$dirty"
[[ $total -eq 3 && $ids -eq 1 && $dirty -ge 2 ]] || fail "the negative control saw no leakage, so the test would be blind"

pass "a new container and a clean filesystem for every job under Swarm; the negative control sees the leakage a restarted container would cause"
