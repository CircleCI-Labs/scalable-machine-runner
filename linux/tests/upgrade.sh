#!/usr/bin/env bash
# upgrade.sh: a runner upgrade reaches the next container only, and running jobs finish on the version they started
# with. Token-free. Two nodes in DinD containers: a Swarm manager and a worker.
#
# The real linux/stack/runners.yaml mounts /opt/machine-runner-swarm/current, a link to /opt/machine-runner-swarm/<version>.
# Docker resolves the link when it creates a container, so an atomic flip of the link (a new link, then mv -T, as
# linux/setup.sh does) must change what the NEXT container sees and nothing that is running.
#   flip        two versions side by side on both nodes, a 20 second fake job per container (the fake job reports the
#               version it sees at its start and at its end). Flip to 2.0.0 while the first two jobs run: they finish on
#               1.0.0, every container started after the flip reports 2.0.0. Flip back (a rollback) while those run:
#               they finish on 2.0.0, the containers after that report 1.0.0
#   global-job  `docker service create --mode global-job` installs the real runner (a real download) on every node from
#               a small image with linux/install-job.sh and flips current. Running it again for the installed version
#               only flips back (here from a decoy version), without a download
#
# Usage: upgrade.sh        Env: TIMEOUT=240 (for each wait)
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TIMEOUT=${TIMEOUT:-240}
ALPINE_IMAGE=${SWARM_TEST_ALPINE_IMAGE:-alpine:3.22}

session_begin --worker
DIAG_NODES="$SWARM_TEST_MGR $SWARM_TEST_WRK"
nodes=("$SWARM_TEST_MGR" "$SWARM_TEST_WRK")

# ---------------------------------------------------------------------------------------------
# flip
# ---------------------------------------------------------------------------------------------
for n in "${nodes[@]}"; do
  docker exec "$n" rm -rf /opt/machine-runner-swarm
  install_swarm "$n" fake 1.0.0
  install_swarm "$n" fake 2.0.0
  flip_current "$n" 1.0.0
done
create_secrets "$SWARM_TEST_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}"
make_override "$work/ov.yaml" 'linux-default 2 FAKE_JOB_SLEEP=20'
deploy_stack "$SWARM_TEST_MGR" "$work/ov.yaml"

count() { service_logs "$SWARM_TEST_MGR" linux-default | grep -c -E "$1" || true; }
# wait_count PATTERN MINIMUM DESCRIPTION
wait_count() {
  local i
  for ((i = 0; i < TIMEOUT / 2; i++)); do
    [[ $(count "$1") -ge $2 ]] && return 0
    sleep 2
  done
  fail "$3 (waited ${TIMEOUT}s)"
}
flip_all() { for n in "${nodes[@]}"; do flip_current "$n" "$1"; done; }

log "two containers, one per node, start on 1.0.0"
wait_count '^FAKEJOB .* version=1\.0\.0 ' 2 "the first two jobs did not start on 1.0.0"
[[ $(count '^JOBEND') -eq 0 ]] || fail "a job ended before the flip: the test is too slow to prove anything"
flip_all 2.0.0
log "flipped to 2.0.0 while two jobs run"
wait_count '^JOBEND .* version=1\.0\.0' 2 "the running jobs did not finish on 1.0.0"
wait_count '^FAKEJOB .* version=2\.0\.0 ' 2 "the containers after the flip did not start on 2.0.0"
old=$(count '^FAKEJOB .* version=1\.0\.0 ')
echo "RESULT test=upgrade phase=flip flipped_to=2.0.0 started_on_1.0.0=$old jobs_that_finished_on_1.0.0_after_the_flip=$(count '^JOBEND .* version=1\.0\.0') started_on_2.0.0_after_the_flip=$(count '^FAKEJOB .* version=2\.0\.0 ')"
[[ $old -eq 2 ]] || fail "a container started on 1.0.0 after the flip ($old containers started on 1.0.0, expected the first two only)"

log "flip back (a rollback) while the two containers on 2.0.0 run"
flip_all 1.0.0
wait_count '^JOBEND .* version=2\.0\.0' 2 "the running jobs did not finish on 2.0.0 after the rollback"
wait_count '^FAKEJOB .* version=1\.0\.0 ' 4 "the containers after the rollback did not start on 1.0.0"
new=$(count '^FAKEJOB .* version=2\.0\.0 ')
echo "RESULT test=upgrade phase=rollback flipped_to=1.0.0 jobs_that_finished_on_2.0.0_after_the_flip=$(count '^JOBEND .* version=2\.0\.0') started_on_1.0.0_after_the_rollback=$(($(count '^FAKEJOB .* version=1\.0\.0 ') - 2)) started_on_2.0.0=$new"
[[ $new -eq 2 ]] || fail "a container started on 2.0.0 after the rollback ($new containers started on 2.0.0, expected two)"
tasks=$(idocker "$SWARM_TEST_MGR" service ps -q "${STACK}_linux-default" | wc -l)
[[ $tasks -ge 6 ]] || fail "expected at least 6 containers, found $tasks: a container was reused"

# ---------------------------------------------------------------------------------------------
# global-job
# ---------------------------------------------------------------------------------------------
log "global-job: install the real runner on every node"
idocker "$SWARM_TEST_MGR" stack rm "$STACK" >/dev/null
wait_for 60 bash -c "[ -z \"\$(docker exec $SWARM_TEST_MGR docker service ls -q)\" ]" || fail "the stack did not go away"
ver=$(sed -n 's/^MACHINE_RUNNER_SWARM_VERSION=//p' "$repo_dir/linux/setup.sh")
sha_amd64=$(sed -n 's/^MACHINE_RUNNER_SWARM_SHA256_AMD64=//p' "$repo_dir/linux/setup.sh")
sha_arm64=$(sed -n 's/^MACHINE_RUNNER_SWARM_SHA256_ARM64=//p' "$repo_dir/linux/setup.sh")
for n in "${nodes[@]}"; do
  docker exec "$n" rm -rf /opt/machine-runner-swarm
  dind_load "$n" "$ALPINE_IMAGE"
done
idocker "$SWARM_TEST_MGR" config create machine-runner-swarm-entrypoint - < "$repo_dir/linux/entrypoint/circleci-runner-entrypoint" >/dev/null

# run_install_job: the command of docs/operations.md, then wait for one Complete task on each node.
run_install_job() {
  local i states
  idocker "$SWARM_TEST_MGR" service rm runner-install >/dev/null 2>&1 || true
  idocker "$SWARM_TEST_MGR" service create --name runner-install --mode global-job --restart-condition none --detach \
    --constraint node.platform.os==linux \
    --mount type=bind,source=/opt,target=/host-opt \
    --config source=machine-runner-swarm-entrypoint,target=/circleci-runner-entrypoint,mode=0444 \
    --env MACHINE_RUNNER_SWARM_VERSION="$ver" --env MACHINE_RUNNER_SWARM_SHA256_AMD64="$sha_amd64" --env MACHINE_RUNNER_SWARM_SHA256_ARM64="$sha_arm64" \
    "$ALPINE_IMAGE" sh -c "$(cat "$repo_dir/linux/install-job.sh")" >/dev/null
  for ((i = 0; i < TIMEOUT; i += 2)); do
    states=$(idocker "$SWARM_TEST_MGR" service ps --format '{{.CurrentState}}' runner-install | cut -d' ' -f1 | sort | uniq -c | tr -s ' \n' ' ')
    case $states in *Failed* | *Rejected*) fail "the install job failed: $states; $(idocker "$SWARM_TEST_MGR" service logs runner-install 2>&1 | tail -n 5)" ;; esac
    [[ $states == " 2 Complete " ]] && return 0
    sleep 2
  done
  fail "the install job did not complete on both nodes within ${TIMEOUT}s (tasks: $states)"
}

check_node() { # NODE: the installed runner is behind current
  local n=$1 target
  target=$(docker exec "$n" readlink /opt/machine-runner-swarm/current)
  [[ $target == "$ver" ]] || fail "$n: current points to '$target', not $ver"
  docker exec "$n" /opt/machine-runner-swarm/current/bin/circleci-runner --version | grep -q "version $ver" || fail "$n: the runner behind current is not $ver"
  [[ $(docker exec "$n" cat /opt/machine-runner-swarm/current/VERSION) == "$ver" ]] || fail "$n: VERSION"
  docker exec "$n" cat /opt/machine-runner-swarm/current/bin/circleci-runner-entrypoint | cmp -s - "$repo_dir/linux/entrypoint/circleci-runner-entrypoint" || fail "$n: the entrypoint is not the one of this checkout"
  [[ -z $(docker exec "$n" find /opt/machine-runner-swarm ! -type l \( ! -user root -o -perm /022 \)) ]] || fail "$n: a file is not root-owned or is group/world writable"
}

run_install_job
for n in "${nodes[@]}"; do check_node "$n"; done
first_log=$(idocker "$SWARM_TEST_MGR" service logs --raw runner-install 2>&1)
downloads=$(grep -c '^downloading' <<< "$first_log" || true)
echo "RESULT test=upgrade phase=global-job version=$ver nodes=${#nodes[@]} downloads=$downloads current=$ver root_owned=yes"
[[ $downloads -eq ${#nodes[@]} ]] || fail "expected one download on each node, got $downloads"

log "global-job again, from a decoy version: only a flip, no download"
for n in "${nodes[@]}"; do
  docker exec "$n" sh -c 'mkdir -p /opt/machine-runner-swarm/0.0.1/bin' && flip_current "$n" 0.0.1
done
run_install_job
for n in "${nodes[@]}"; do check_node "$n"; done
second_log=$(idocker "$SWARM_TEST_MGR" service logs --raw runner-install 2>&1)
downloads=$(grep -c '^downloading' <<< "$second_log" || true)
echo "RESULT test=upgrade phase=global-job-again version=$ver downloads=$downloads flipped_back_from=0.0.1"
[[ $downloads -eq 0 ]] || fail "the second run downloaded again"

pass "a flip of current reaches the next container only (running jobs finish on their version, a rollback works), and a global-job installs and flips on every node"
