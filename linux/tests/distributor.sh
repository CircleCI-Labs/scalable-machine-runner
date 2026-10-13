#!/usr/bin/env bash
# distributor.sh: DRAFT test of the runner-distributor (stack/distributor.yaml): no host install. Token-free. The REAL runner
# (3.1.12, pinned in the stack, and an older release for the upgrade) is downloaded by the distributor itself, and runs against
# fake-api.py. Two nodes in DinD containers (manager and worker), a third joins later. Phases:
#   race       the volume is empty (the distributor is held back): runners wait, then exit 80; released, they start in the same container
#   fresh      no /opt/machine-runner-swarm anywhere: both nodes get the verified binary by themselves, root-owned, current -> versions/<v>
#   join       a third node joins: its distributor installs the runner, a replica there starts
#   upgrade    3 busy jobs, then docker stack deploy with the older version: current flips on every node while the jobs run; the jobs
#              finish on the version they started with (the container's runner process), the next containers run the new one
#   rollback   deploy the first version again: the versions are there, so the distributor only flips (no download)
#   tamper     a binary in the volume is replaced: new containers exit 80 on the SHA-256 pin; the distributor repairs it
#   mismatch   a download that does not match its pin is refused, nothing is installed or flipped
# shellcheck disable=SC2329,SC2016  # functions run through wait_for; the single quotes are for the container shell
# Usage: distributor.sh        Env: TIMEOUT=300 (each wait), OLD_VERSION=3.1.11
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TIMEOUT=${TIMEOUT:-300}
OLD=${OLD_VERSION:-3.1.11}
NEW=$(sed -n 's/^MACHINE_RUNNER_SWARM_VERSION=//p' "$repo_dir/linux/setup.sh")
DIST_IMAGE=$(sed -n 's/^    image: \(alpine:3@sha256:[0-9a-f]*\).*/\1/p' "$stack_dir/distributor.yaml")
base=https://circleci-binary-releases.s3.amazonaws.com/circleci-runner
case $(uname -m) in x86_64) arch=amd64 other=ARM64 mine=AMD64 ;; aarch64) arch=arm64 other=AMD64 mine=ARM64 ;; *) fail "unsupported host architecture" ;; esac
zeros=0000000000000000000000000000000000000000000000000000000000000000

session_begin --worker
MGR=$SWARM_TEST_MGR WRK=$SWARM_TEST_WRK
DIAG_NODES="$MGR $WRK"
nodes=("$MGR" "$WRK")
vol=/var/lib/docker/volumes/${STACK}_runner-bin/_data

# --- pins: the NEW version is the one the stack ships; for the OLD one, verify the tarball against checksums.txt, then hash the binary
new_pin=$(sha256sum "$(real_runner)" | cut -d' ' -f1)
curl -fsSL -o "$work/old.tgz" "$base/$OLD/circleci-runner_linux_$arch.tar.gz"
[[ $(sha256sum "$work/old.tgz" | cut -d' ' -f1) == "$(curl -fsSL "$base/$OLD/checksums.txt" | awk -v f="circleci-runner_linux_$arch.tar.gz" '$2 == f { print $1 }')" ]] || fail "$OLD tarball does not match its checksums.txt"
old_pin=$(tar -xzOf "$work/old.tgz" circleci-runner | sha256sum | cut -d' ' -f1)
old_env=("MACHINE_RUNNER_SWARM_RUNNER_VERSION=$OLD" "MACHINE_RUNNER_SWARM_RUNNER_SHA256_$mine=$old_pin" "MACHINE_RUNNER_SWARM_RUNNER_SHA256_$other=$zeros")
new_exe=/opt/machine-runner-swarm/versions/$NEW/bin/circleci-runner
old_exe=/opt/machine-runner-swarm/versions/$OLD/bin/circleci-runner

# --- helpers
dk() { docker exec "$1" docker "${@:2}"; }   # lib.sh idocker reads stdin (docker exec -i), which would eat the lines of the while-read loops below
sdeploy() { # OVERRIDE [ENV=VALUE...]: the real stack files plus distributor.yaml, with the pins from the environment
  local ov=$1 kv
  local -a envs=()
  shift
  for kv in "$@"; do envs+=(-e "$kv"); done
  docker exec "$MGR" mkdir -p /stack /entrypoint
  docker cp "$stack_dir/runners.yaml" "$MGR:/stack/runners.yaml"
  docker cp "$stack_dir/distributor.yaml" "$MGR:/stack/distributor.yaml"
  docker cp "$repo_dir/linux/entrypoint/circleci-runner-entrypoint" "$MGR:/entrypoint/circleci-runner-entrypoint"
  docker cp "$repo_dir/linux/runner-distributor.sh" "$MGR:/runner-distributor.sh"
  docker cp "$ov" "$MGR:/stack/override.yaml"
  docker exec -i "${envs[@]}" "$MGR" docker stack deploy --resolve-image never -c /stack/runners.yaml -c /stack/distributor.yaml -c /stack/override.yaml "$STACK" >&2
}
logs() { dk "$MGR" service logs --raw "${STACK}_$1" 2>&1 || true; }
count() { logs "$1" | grep -c -E "$2" || true; }
wait_until() { wait_for "$TIMEOUT" "$@" || fail "timeout (${TIMEOUT}s): $*"; }
logs_have() { [[ $(count "$1" "$2") -ge $3 ]]; }
start_api() { # TASKS SLEEP: the fake CircleCI API, in the manager's network namespace
  dk "$MGR" rm -f fake-api >/dev/null 2>&1 || true
  dk "$MGR" run -d --name fake-api --network host -v /fake-api.py:/fake-api.py:ro "$CIMG_IMAGE" python3 /fake-api.py 8099 "$1" "$2" >/dev/null
}
runners() { local n; for n in "${nodes[@]}"; do dk "$n" ps -q --filter "label=com.docker.swarm.service.name=${STACK}_linux-default" | sed "s/^/$n /"; done; }
exe() { # NODE CONTAINER: the binary its runner process runs, read from the node's /proc (a job's root user cannot read it, the node can)
  docker exec -i "$1" sh -s "$2" <<'SH'
for p in /proc/[0-9]*; do
  grep -q "$1" "$p/cgroup" 2>/dev/null && tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q 'circleci-runner machine' && readlink "$p/exe" && break
done
SH
}
all_exe() { local want=$1 n c k=0 total=0; while read -r n c; do total=$((total + 1)); [[ $(exe "$n" "$c") == "$want" ]] && k=$((k + 1)); done < <(runners); [[ $total -ge ${2:-1} && $k -eq $total ]]; }
current() { docker exec "$1" readlink "$vol/current" 2>/dev/null || true; }
all_current() { local n; for n in "${nodes[@]}"; do [[ $(current "$n") == "versions/$1" ]] || return 1; done; }
exit80_tasks() { local t k=0; for t in $(dk "$MGR" service ps -q "${STACK}_linux-default"); do [[ $(dk "$MGR" inspect -f '{{.Status.ContainerStatus.ExitCode}}' "$t" 2>/dev/null) == 80 ]] && k=$((k + 1)); done; echo "$k"; }
check_volume() { # NODE VERSION PIN
  [[ $(docker exec "$1" sha256sum "$vol/versions/$2/bin/circleci-runner" | cut -d' ' -f1) == "$3" ]] || fail "$1: the binary of $2 is not the pinned one"
  [[ -z $(docker exec "$1" find "$vol" ! -type l \( ! -user root -o -perm /022 \)) ]] || fail "$1: a file of the volume is not root-owned or is group/world writable"
}

docker cp "$tests_dir/fake-api.py" "$MGR:/fake-api.py"
api="http://$(docker exec "$MGR" hostname -i | awk '{ print $1 }'):8099"
for n in "${nodes[@]}"; do docker exec "$n" rm -rf /opt/machine-runner-swarm; done   # what an earlier test of a shared session left: the nodes start without a host install
create_secrets "$MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}"
start_api 0 75   # no task until armed, then every job is long

# ---------------------------------------------------------------------------------------------
# race: the volume is empty, because the distributor is held back (no node has the label)
# ---------------------------------------------------------------------------------------------
make_override "$work/ov.yaml" "linux-default 1 CIRCLECI_RUNNER_API_URL=$api MACHINE_RUNNER_SWARM_RUNNER_WAIT=15"
printf '  runner-distributor:\n    deploy:\n      placement:\n        constraints: ["node.labels.hold == yes"]\n' >> "$work/ov.yaml"
sdeploy "$work/ov.yaml"
wait_until logs_have linux-default "current is 'missing', not versions/$NEW" 1
wait_until bash -c "[[ \$(for t in \$(docker exec $MGR docker service ps -q ${STACK}_linux-default); do docker exec $MGR docker inspect -f '{{.Status.ContainerStatus.ExitCode}}' \$t; done | grep -c '^80\$') -ge 1 ]]"
[[ $(count linux-default 'waiting for the runner-distributor') -ge 1 ]] || fail "the entrypoint did not say that it waits"
echo "RESULT test=distributor phase=race waited=yes exit_code=80 tasks_with_exit_80=$(exit80_tasks) volume_empty=$([[ -z $(docker exec "$MGR" ls -A "$vol") ]] && echo yes || echo no)"

log "race: a longer wait, the distributor still held: two containers wait in place"
before=$(dk "$MGR" service ps -q "${STACK}_linux-default" | sort)
make_override "$work/ov.yaml" "linux-default 2 CIRCLECI_RUNNER_API_URL=$api MACHINE_RUNNER_SWARM_RUNNER_WAIT=300"
cp "$work/ov.yaml" "$work/ov-run.yaml"   # the same, without the hold
printf '  runner-distributor:\n    deploy:\n      placement:\n        constraints: ["node.labels.hold == yes"]\n' >> "$work/ov.yaml"
sdeploy "$work/ov.yaml"
waiting() { local n c k=0; while read -r n c; do dk "$n" logs "$c" 2>&1 | grep -q 'waiting for the runner-distributor' && k=$((k + 1)); done < <(runners); [[ $k -ge 2 ]]; }
wait_until waiting
waiters=$(runners | awk '{ print $2 }' | sort)
log "race: release the distributor; the same containers start the runner"
sdeploy "$work/ov-run.yaml"
wait_until all_current "$NEW"
wait_until logs_have linux-default 'starting agent' 2
failed_new=0
for t in $(dk "$MGR" service ps -q "${STACK}_linux-default" | sort | comm -13 <(echo "$before") -); do
  case $(dk "$MGR" inspect -f '{{.Status.State}}' "$t") in failed | rejected) failed_new=$((failed_new + 1)) ;; esac
done
same=$(comm -12 <(echo "$waiters") <(runners | awk '{ print $2 }' | sort) | wc -l)
echo "RESULT test=distributor phase=race-released containers_that_waited=2 same_containers_running_the_runner=$same failed_tasks_after_the_wait_started=$failed_new"
[[ $failed_new -eq 0 && $same -eq 2 ]] || fail "a waiting container failed or was replaced instead of starting the runner"

# ---------------------------------------------------------------------------------------------
# fresh: both nodes have the verified runner, nothing was installed by hand
# ---------------------------------------------------------------------------------------------
for n in "${nodes[@]}"; do
  check_volume "$n" "$NEW" "$new_pin"
  docker exec "$n" test ! -e /opt/machine-runner-swarm || fail "$n has a host install"
done
wait_until all_exe "$new_exe" 2
echo "RESULT test=distributor phase=fresh nodes=2 host_install=none version=$NEW sha256_pinned=yes root_owned=yes current=$(current "$MGR") runners_on_pinned_binary=$(runners | wc -l) downloads=$(count runner-distributor "^downloading circleci-runner $NEW")"
[[ $(count runner-distributor "^downloading circleci-runner $NEW") -eq 2 ]] || fail "expected one download per node"

# ---------------------------------------------------------------------------------------------
# join: a third node
# ---------------------------------------------------------------------------------------------
N3=swarm-test-n3-$$
dind_start "$N3" "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$MGR")"
dind_load "$N3" "$CIMG_IMAGE"
dk "$N3" swarm join --token "$(dk "$MGR" swarm join-token -q worker)" "$(docker exec "$MGR" hostname -i | awk '{ print $1 }'):2377" >/dev/null
nodes+=("$N3")
DIAG_NODES="$MGR $WRK $N3"
wait_until bash -c "[[ \$(docker exec $N3 readlink $vol/current 2>/dev/null) == versions/$NEW ]]"
check_volume "$N3" "$NEW" "$new_pin"
dk "$MGR" service scale -d "${STACK}_linux-default=3" >/dev/null
make_override "$work/ov.yaml" "linux-default 3 CIRCLECI_RUNNER_API_URL=$api MACHINE_RUNNER_SWARM_RUNNER_WAIT=300"   # the distributor is not held any more
wait_until all_exe "$new_exe" 3
[[ -n $(dk "$N3" ps -q --filter "label=com.docker.swarm.service.name=${STACK}_linux-default") ]] || fail "no replica runs on the new node"
echo "RESULT test=distributor phase=join node=$N3 installed_by_distributor=yes host_install=none replica_on_new_node=yes version=$NEW"

# ---------------------------------------------------------------------------------------------
# upgrade: three busy jobs, then the older version is deployed
# ---------------------------------------------------------------------------------------------
dk "$MGR" exec fake-api curl -fsS http://localhost:8099/_arm/3 >/dev/null
wait_until logs_have linux-default 'TASK uid=' 3
olds=$(runners)
while read -r n c; do [[ $(exe "$n" "$c") == "$new_exe" ]] || fail "$n: a busy runner is not on $NEW"; done <<< "$olds"
log "upgrade: three jobs run on $NEW; deploy $OLD"
sdeploy "$work/ov.yaml" "${old_env[@]}"
wait_until all_current "$OLD"
ended=$(count linux-default 'TASKEND')
seen=0 still=0
while read -r n c; do
  [[ $(dk "$n" inspect -f '{{.State.Running}}' "$c") == true ]] && still=$((still + 1))
  [[ $(dk "$n" exec "$c" readlink /opt/machine-runner-swarm/current) == "versions/$OLD" && $(exe "$n" "$c") == "$new_exe" ]] && seen=$((seen + 1))
done <<< "$olds"
echo "RESULT test=distributor phase=upgrade-flip flipped_to=$OLD nodes=3 jobs_ended_before_the_flip=$ended busy_containers_still_running=$still containers_that_see_the_new_link_but_run_the_old_binary=$seen"
[[ $ended -eq 0 && $still -eq 3 && $seen -eq 3 ]] || fail "the flip was too late for the jobs, or it stopped a container ($ended ended, $still running, $seen old binaries behind the new link)"
wait_until logs_have linux-default 'TASKEND' 3
codes=
while read -r n c; do wait_for 120 bash -c "[[ \$(docker exec $n docker inspect -f '{{.State.Running}}' $c) == false ]]" || fail "an old container did not stop"; codes="$codes$(dk "$n" inspect -f '{{.State.ExitCode}}' "$c") "; done <<< "$olds"
wait_until all_exe "$old_exe" 3
news=$(runners)
[[ -z $(comm -12 <(awk '{ print $2 }' <<< "$olds" | sort) <(awk '{ print $2 }' <<< "$news" | sort)) ]] || fail "a container was reused"
echo "RESULT test=distributor phase=upgrade-done jobs_finished_on=$NEW old_containers_exit_codes=${codes% } next_containers_on=$OLD downloads_of_$OLD=$(count runner-distributor "^downloading circleci-runner $OLD")"
[[ ${codes% } == "0 0 0" ]] || fail "an old container did not exit 0 (a job was interrupted?): $codes"

# ---------------------------------------------------------------------------------------------
# rollback: the old version is deployed again, the new one is in the volume already
# ---------------------------------------------------------------------------------------------
sdeploy "$work/ov.yaml"
wait_until all_current "$NEW"
wait_until all_exe "$new_exe" 3
echo "RESULT test=distributor phase=rollback flipped_to=$NEW downloads_of_$NEW=$(count runner-distributor "^downloading circleci-runner $NEW") switched_without_download=$(count runner-distributor "^circleci-runner $NEW is installed already") versions_kept=$(docker exec "$MGR" ls "$vol/versions" | paste -sd, -)"
[[ $(count runner-distributor "^downloading circleci-runner $NEW") -eq 3 && $(count runner-distributor "^circleci-runner $NEW is installed already") -ge 3 ]] || fail "the rollback downloaded again"

# ---------------------------------------------------------------------------------------------
# tamper: a file of the volume is replaced (as a privileged job could); the pin stops the next container
# ---------------------------------------------------------------------------------------------
docker exec "$MGR" sh -c "cd $vol/versions/$NEW/bin && cp circleci-runner x && echo tampered >> x && chmod 0755 x && mv x circleci-runner"
dk "$MGR" service update --force -d "${STACK}_linux-default" >/dev/null
wait_until logs_have linux-default 'does not match the pinned SHA-256' 1
wait_until bash -c "[[ \$(for t in \$(docker exec $MGR docker service ps -q ${STACK}_linux-default); do docker exec $MGR docker inspect -f '{{.Status.ContainerStatus.ExitCode}}' \$t; done | grep -c '^80\$') -ge 1 ]]"
echo "RESULT test=distributor phase=tamper exit_code=80 tasks_with_exit_80=$(exit80_tasks)"
dk "$MGR" service update --force -d "${STACK}_runner-distributor" >/dev/null
wait_until bash -c "[[ \$(docker exec $MGR sha256sum $vol/versions/$NEW/bin/circleci-runner | cut -d' ' -f1) == $new_pin ]]"
wait_until bash -c "[[ \$(docker exec $MGR docker service ls --filter name=${STACK}_linux-default --format '{{.Replicas}}') == 3/3 ]]"
all_exe "$new_exe" 3 || fail "the runners did not recover after the repair"
echo "RESULT test=distributor phase=tamper-repaired redownloads_on_the_node=$(count runner-distributor "^downloading circleci-runner $NEW") replicas=3/3"

# ---------------------------------------------------------------------------------------------
# mismatch: a download that does not match its pin installs nothing
# ---------------------------------------------------------------------------------------------
rc=0
out=$(dk "$MGR" run --rm -v /runner-distributor.sh:/runner-distributor.sh:ro -v bad-pin:/opt/machine-runner-swarm \
  -e MACHINE_RUNNER_SWARM_RUNNER_VERSION="$OLD" -e MACHINE_RUNNER_SWARM_RUNNER_SHA256_AMD64=$zeros -e MACHINE_RUNNER_SWARM_RUNNER_SHA256_ARM64=$zeros \
  "$DIST_IMAGE" sh /runner-distributor.sh 2>&1) || rc=$?
left=$(dk "$MGR" run --rm -v bad-pin:/v "$DIST_IMAGE" ls -A /v | paste -sd, -)
echo "RESULT test=distributor phase=mismatch exit=$rc installed_or_flipped=${left:-nothing}"
[[ $rc -ne 0 && $out == *"SHA-256 mismatch"* && $left == versions ]] || fail "a download with a wrong SHA-256 was accepted ($rc, $out, $left)"

dk "$N3" swarm leave --force >/dev/null 2>&1 || true
pass "no host install: the distributor fills every node (also a late joiner) with the SHA-256 pinned runner, an upgrade flips under running jobs that finish on their version, a rollback only flips, the entrypoint waits for an empty volume and exits 80 on a changed binary"
