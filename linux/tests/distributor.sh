#!/usr/bin/env bash
# distributor.sh: the runner-distributor service of linux/stack/runners.yaml, the only way a runner reaches a node. Token-free.
# Two nodes in DinD containers (manager and worker), a third joins later. The distributor downloads from the harness's local mirror
# (a manifest.json and tarballs of two REAL runner releases and a few fake ones; lib.sh publish_runner). The real runner runs
# against fake-api.py. A last phase uses CircleCI's real manifest. Phases:
#   race       the volume is empty (the distributor is held back): runners wait, then exit 80; released, they start in the same container
#   fresh      no host install anywhere: both nodes get the verified binary by themselves, root-owned, current -> versions/<v>, with a record
#   join       a third node joins: its distributor installs the runner, a replica there starts
#   upgrade    3 busy jobs, then the distributor is pinned to another version: current flips on every node while the jobs run; the jobs
#              finish on the version they started with, the next containers run the new one, and the runner service itself is not touched
#   rollback   the first version again: it is installed, so the distributor only flips (no download)
#   auto       version "current": the distributor follows the manifest by itself (the sha256 of current names the version), with no redeploy
#   major      the manifest's current moves to a major version we do not follow: nothing is downloaded, nothing flips
#   prune      only the last 3 versions that were active stay on the node, never the active one
#   tamper     a binary in the volume is replaced: new containers exit 80 on the record; the distributor repairs it by itself
#   mismatch   a download that does not match the pinned SHA-256 installs nothing; a list with the right one installs
#   real       version "current" against CircleCI's real manifest: the version it names, verified, with a matching record
# shellcheck disable=SC2329,SC2016  # functions run through wait_for; the single quotes are for the container shell
# Usage: distributor.sh        Env: TIMEOUT=300 (each wait), OLD_VERSION=3.1.11, SWARM_TEST_RUNNER_VERSION=3.1.12
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TIMEOUT=${TIMEOUT:-300}
NEW=$TEST_RUNNER_VERSION
OLD=${OLD_VERSION:-3.1.11}
DIST_IMAGE=$(sed -n 's/^    image: \(alpine:3@sha256:[0-9a-f]*\).*/\1/p' "$stack_dir/runners.yaml")
zeros=0000000000000000000000000000000000000000000000000000000000000000

session_begin --worker
MGR=$SWARM_TEST_MGR WRK=$SWARM_TEST_WRK
DIAG_NODES="$MGR $WRK"
nodes=("$MGR" "$WRK")
vol=/var/lib/docker/volumes/${STACK}_runner-bin/_data
new_exe=/opt/machine-runner-swarm/versions/$NEW/bin/circleci-runner
old_exe=/opt/machine-runner-swarm/versions/$OLD/bin/circleci-runner

# --- the mirror: two real releases (the manifest's current is the new one) -------------------------------------------------
publish_runner real "$OLD"
publish_runner real "$NEW"
new_pin=$(sha256sum "$(real_runner "$NEW")" | cut -d' ' -f1)   # the SHA-256 of the BINARY, which the distributor records
old_pin=$(sha256sum "$(real_runner "$OLD")" | cut -d' ' -f1)
DIST_ENV=(MACHINE_RUNNER_SWARM_CHECK_INTERVAL=5s)

# --- helpers
dk() { docker exec "$1" docker "${@:2}"; }   # lib.sh idocker reads stdin (docker exec -i), which would eat the lines of the while-read loops below
logs() { dk "$MGR" service logs --raw "${STACK}_$1" 2>&1 || true; }
count() { logs "$1" | grep -c -E "$2" || true; }
wait_until() { wait_for "$TIMEOUT" "$@" || fail "timeout (${TIMEOUT}s): $*"; }
logs_have() { [[ $(count "$1" "$2") -ge $3 ]]; }
dep() { # REPLICAS: deploy the stack with linux-default at REPLICAS, the distributor as DIST_VERSION/DIST_ENV/DIST_HOLD say
  make_override "$work/ov.yaml" "linux-default $1 CIRCLECI_RUNNER_API_URL=$api MACHINE_RUNNER_SWARM_RUNNER_WAIT=${WAIT_S:-300}"
  deploy_stack "$MGR" "$work/ov.yaml"
}
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
versions_on() { docker exec "$1" ls "$vol/versions" 2>/dev/null | sort | paste -sd, -; }
exit80_tasks() { local t k=0; for t in $(dk "$MGR" service ps -q "${STACK}_linux-default"); do [[ $(dk "$MGR" inspect -f '{{.Status.ContainerStatus.ExitCode}}' "$t" 2>/dev/null) == 80 ]] && k=$((k + 1)); done; echo "$k"; }
has_exit80() { [[ $(exit80_tasks) -ge 1 ]]; }
downloads() { count runner-distributor "^runner-distributor: downloading circleci-runner $1 "; }
service_spec() { dk "$MGR" service inspect -f '{{json .Spec}}' "${STACK}_$1" | sha256sum | cut -c1-16; }   # changes when the service is updated
check_volume() { # NODE VERSION PIN: the binary is the one that was pinned, its record says so, and nobody else can write
  [[ $(docker exec "$1" sha256sum "$vol/versions/$2/bin/circleci-runner" | cut -d' ' -f1) == "$3" ]] || fail "$1: the binary of $2 is not the pinned one"
  [[ $(docker exec "$1" sh -c "cd $vol/versions/$2 && cat SHA256") == "$3  bin/circleci-runner" ]] || fail "$1: the record of $2 does not name the binary"
  [[ $(docker exec "$1" cat "$vol/versions/$2/VERSION") == "$2" ]] || fail "$1: VERSION of $2"
  [[ -z $(docker exec "$1" find "$vol" ! -type l \( ! -user root -o -perm /022 \)) ]] || fail "$1: a file of the volume is not root-owned or is group/world writable"
}

docker cp "$tests_dir/fake-api.py" "$MGR:/fake-api.py"
api="http://$(docker exec "$MGR" hostname -i | awk '{ print $1 }'):8099"
create_secrets "$MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}"
start_api 0 75   # no task until armed, then every job is long

# ---------------------------------------------------------------------------------------------
# race: the volume is empty, because the distributor is held back (no node has the label)
# ---------------------------------------------------------------------------------------------
WAIT_S=15 DIST_HOLD=1 dep 1
wait_until logs_have linux-default "current is 'missing'" 1
wait_until has_exit80
[[ $(count linux-default 'waiting for the runner-distributor') -ge 1 ]] || fail "the entrypoint did not say that it waits"
echo "RESULT test=distributor phase=race waited=yes exit_code=80 tasks_with_exit_80=$(exit80_tasks) volume_empty=$([[ -z $(docker exec "$MGR" ls -A "$vol" 2>/dev/null) ]] && echo yes || echo no)"

log "race: a longer wait, the distributor still held: two containers wait in place"
before=$(dk "$MGR" service ps -q "${STACK}_linux-default" | sort)
DIST_HOLD=1 dep 2
waiting() { local n c k=0; while read -r n c; do dk "$n" logs "$c" 2>&1 | grep -q 'waiting for the runner-distributor' && k=$((k + 1)); done < <(runners); [[ $k -ge 2 ]]; }
wait_until waiting
waiters=$(runners | awk '{ print $2 }' | sort)
log "race: release the distributor; the same containers start the runner"
DIST_HOLD='' dep 2
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
echo "RESULT test=distributor phase=fresh nodes=2 host_install=none version=$NEW sha256_checked=yes record=yes root_owned=yes current=$(current "$MGR") runners_on_pinned_binary=$(runners | wc -l) downloads=$(downloads "$NEW")"
[[ $(downloads "$NEW") -eq 2 ]] || fail "expected one download per node"

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
dep 3
wait_until all_exe "$new_exe" 3
[[ -n $(dk "$N3" ps -q --filter "label=com.docker.swarm.service.name=${STACK}_linux-default") ]] || fail "no replica runs on the new node"
echo "RESULT test=distributor phase=join node=$N3 installed_by_distributor=yes host_install=none replica_on_new_node=yes version=$NEW"

# ---------------------------------------------------------------------------------------------
# upgrade: three busy jobs, then the distributor is pinned to the other version
# ---------------------------------------------------------------------------------------------
dk "$MGR" exec fake-api curl -fsS http://localhost:8099/_arm/3 >/dev/null
wait_until logs_have linux-default 'TASK uid=' 3
olds=$(runners)
while read -r n c; do [[ $(exe "$n" "$c") == "$new_exe" ]] || fail "$n: a busy runner is not on $NEW"; done <<< "$olds"
spec_before=$(service_spec linux-default)
log "upgrade: three jobs run on $NEW; pin the distributor to $OLD"
DIST_VERSION=$OLD dep 3
wait_until all_current "$OLD"
ended=$(count linux-default 'TASKEND')
seen=0 still=0
while read -r n c; do
  [[ $(dk "$n" inspect -f '{{.State.Running}}' "$c") == true ]] && still=$((still + 1))
  [[ $(dk "$n" exec "$c" readlink /opt/machine-runner-swarm/current) == "versions/$OLD" && $(exe "$n" "$c") == "$new_exe" ]] && seen=$((seen + 1))
done <<< "$olds"
untouched=no
[[ $(service_spec linux-default) == "$spec_before" ]] && untouched=yes
echo "RESULT test=distributor phase=upgrade-flip flipped_to=$OLD nodes=3 jobs_ended_before_the_flip=$ended busy_containers_still_running=$still containers_that_see_the_new_link_but_run_the_old_binary=$seen runner_service_untouched=$untouched"
[[ $ended -eq 0 && $still -eq 3 && $seen -eq 3 ]] || fail "the flip was too late for the jobs, or it stopped a container ($ended ended, $still running, $seen old binaries behind the new link)"
[[ $untouched == yes ]] || fail "the upgrade changed the runner service: only the distributor may change"
wait_until logs_have linux-default 'TASKEND' 3
codes=
while read -r n c; do wait_for 120 bash -c "[[ \$(docker exec $n docker inspect -f '{{.State.Running}}' $c) == false ]]" || fail "an old container did not stop"; codes="$codes$(dk "$n" inspect -f '{{.State.ExitCode}}' "$c") "; done <<< "$olds"
wait_until all_exe "$old_exe" 3
news=$(runners)
[[ -z $(comm -12 <(awk '{ print $2 }' <<< "$olds" | sort) <(awk '{ print $2 }' <<< "$news" | sort)) ]] || fail "a container was reused"
echo "RESULT test=distributor phase=upgrade-done jobs_finished_on=$NEW old_containers_exit_codes=${codes% } next_containers_on=$OLD downloads_of_$OLD=$(downloads "$OLD")"
[[ ${codes% } == "0 0 0" ]] || fail "an old container did not exit 0 (a job was interrupted?): $codes"
check_volume "$MGR" "$OLD" "$old_pin"

# ---------------------------------------------------------------------------------------------
# rollback: the first version is pinned again, it is in the volume already
# ---------------------------------------------------------------------------------------------
DIST_VERSION=$NEW dep 3
wait_until all_current "$NEW"
# idle runners keep the binary they started with until they recycle (their idle timeout): recycle them now
dk "$MGR" service update --force -d "${STACK}_linux-default" >/dev/null
wait_until all_exe "$new_exe" 3
echo "RESULT test=distributor phase=rollback flipped_to=$NEW downloads_of_$NEW=$(downloads "$NEW") switched_without_download=$(count runner-distributor "circleci-runner $NEW is installed already") versions_kept=$(versions_on "$MGR")"
[[ $(downloads "$NEW") -eq 3 ]] || fail "the rollback downloaded again"

# ---------------------------------------------------------------------------------------------
# tamper: a file of the volume is replaced (as a privileged job could); the record stops the next container, the distributor repairs it
# ---------------------------------------------------------------------------------------------
DIST_ENV=(MACHINE_RUNNER_SWARM_CHECK_INTERVAL=1h)   # no check of its own while the runners meet the changed binary
dep 3
wait_until logs_have runner-distributor 'check every 3600s' 3

docker exec "$MGR" sh -c "cd $vol/versions/$NEW/bin && cp circleci-runner x && echo tampered >> x && chmod 0755 x && mv x circleci-runner"
dk "$MGR" service update --force -d "${STACK}_linux-default" >/dev/null
wait_until logs_have linux-default 'does not match its SHA-256 record' 1
wait_until has_exit80
echo "RESULT test=distributor phase=tamper exit_code=80 tasks_with_exit_80=$(exit80_tasks)"
dk "$MGR" service update --force -d "${STACK}_runner-distributor" >/dev/null   # the check at its start
wait_until bash -c "[[ \$(docker exec $MGR sha256sum $vol/versions/$NEW/bin/circleci-runner | cut -d' ' -f1) == $new_pin ]]"
wait_until bash -c "[[ \$(docker exec $MGR docker service ls --filter name=${STACK}_linux-default --format '{{.Replicas}}') == 3/3 ]]"
all_exe "$new_exe" 3 || fail "the runners did not recover after the repair"
echo "RESULT test=distributor phase=tamper-repaired redownloads_on_the_node=$(count runner-distributor "^runner-distributor: downloading circleci-runner $NEW linux/$ARCH") replicas=3/3"
DIST_ENV=(MACHINE_RUNNER_SWARM_CHECK_INTERVAL=5s)   # its own check finds a changed binary too, with no redeploy and no runner in the way
dep 0
wait_until logs_have runner-distributor 'check every 5s' 3
docker exec "$MGR" sh -c "cd $vol/versions/$NEW/bin && cp circleci-runner x && echo tampered >> x && chmod 0755 x && mv x circleci-runner"
wait_until bash -c "[[ \$(docker exec $MGR sha256sum $vol/versions/$NEW/bin/circleci-runner | cut -d' ' -f1) == $new_pin ]]"
echo "RESULT test=distributor phase=tamper-repaired-by-its-check repaired=yes"

# ---------------------------------------------------------------------------------------------
# auto: version "current" follows the manifest by itself. No runner needed from here on.
# ---------------------------------------------------------------------------------------------
dk "$MGR" rm -f fake-api >/dev/null 2>&1 || true
DIST_VERSION=current
mirror_manifest "$OLD"   # current names $OLD by its sha256: the manifest says current, the distributor finds the version
dep 0
wait_until all_current "$OLD"
echo "RESULT test=distributor phase=auto current_in_manifest=$OLD resolved_by_sha256=yes flipped_to=$(current "$MGR") downloads_of_$OLD=$(downloads "$OLD")"
[[ $(downloads "$OLD") -eq 3 ]] || fail "current was resolved to $OLD, which is installed, but it was downloaded again"
publish_runner fake 3.1.20 3.1.20   # a release appears: the manifest's current moves; the distributor is not redeployed
DIST_VERSION=current
wait_until all_current 3.1.20
check=$(docker exec "$MGR" cat "$vol/versions/3.1.20/VERSION")
echo "RESULT test=distributor phase=auto-update appeared=3.1.20 adopted_without_redeploy=yes downloads=$(downloads 3.1.20) version_file=$check"
[[ $(downloads 3.1.20) -eq 3 && $check == 3.1.20 ]] || fail "current was not adopted exactly once on each node"

# ---------------------------------------------------------------------------------------------
# major: the manifest's current moves to a major version we do not follow
# ---------------------------------------------------------------------------------------------
publish_runner fake 4.0.0 4.0.0
DIST_VERSION=current
wait_until logs_have runner-distributor 'current is 4.0.0 \(major 4\), not 3: not adopting it' 3
sleep 12   # two more checks
[[ $(count runner-distributor '^runner-distributor: downloading circleci-runner 4\.0\.0') -eq 0 ]] || fail "4.0.0 was downloaded although MACHINE_RUNNER_SWARM_RUNNER_MAJOR is 3"
all_current 3.1.20 || fail "current moved to a version of another major"
[[ $(versions_on "$MGR") != *4.0.0* ]] || fail "4.0.0 is in the volume"
echo "RESULT test=distributor phase=major manifest_current=4.0.0 major=3 adopted=no downloaded=no current=$(current "$MGR")"

# ---------------------------------------------------------------------------------------------
# prune: only the last 3 versions that were active stay, never the active one
# ---------------------------------------------------------------------------------------------
publish_runner fake 3.1.21 3.1.21
DIST_VERSION=current
wait_until all_current 3.1.21
publish_runner fake 3.1.22 3.1.22
DIST_VERSION=current
wait_until all_current 3.1.22
wait_until bash -c "[[ \$(docker exec $MGR ls $vol/versions | sort | paste -sd, -) == 3.1.20,3.1.21,3.1.22 ]]"
kept=$(versions_on "$MGR")
echo "RESULT test=distributor phase=prune active=3.1.22 kept=$kept pruned=$NEW,$OLD$(for n in "${nodes[@]}"; do [[ $(versions_on "$n") == "$kept" ]] || echo " NODE-DIFFERS:$n"; done)"
[[ $(count runner-distributor "removing circleci-runner $OLD") -ge 1 ]] || fail "the oldest version was not pruned"
DIST_VERSION=3.1.20 dep 0   # a version that is kept can be pinned again: a flip
wait_until all_current 3.1.20
[[ $(downloads 3.1.20) -eq 3 && $(current "$MGR") == versions/3.1.20 && $(versions_on "$MGR") == 3.1.20,3.1.21,3.1.22 ]] || fail "pinning a kept version downloaded, or pruned the active one"
DIST_VERSION=$OLD dep 0   # a pruned one is downloaded again, and the active one is never pruned
wait_until all_current "$OLD"
echo "RESULT test=distributor phase=prune-rollback pinned_kept=3.1.20_by_a_flip pinned_pruned=$OLD downloaded_again=$(downloads "$OLD") active_kept=yes versions=$(versions_on "$MGR")"
docker exec "$MGR" test -x "$vol/versions/$OLD/bin/circleci-runner" || fail "the active version is missing"

# ---------------------------------------------------------------------------------------------
# mismatch: a download that does not match the pinned SHA-256 installs nothing
# ---------------------------------------------------------------------------------------------
dist_once() { # VOLUME ENV=VALUE...: the distributor script of this checkout in a container of its own, until it says ok or exits
  local v=$1 i
  shift
  local -a envs=(-e "MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL=$MIRROR_URL")
  for i in "$@"; do envs+=(-e "$i"); done
  dk "$MGR" rm -f dist-once >/dev/null 2>&1 || true
  dk "$MGR" run -d --name dist-once -v /runner-distributor.sh:/runner-distributor.sh:ro -v "$v":/opt/machine-runner-swarm "${envs[@]}" "$DIST_IMAGE" sh /runner-distributor.sh >/dev/null
  for ((i = 0; i < 60; i++)); do
    [[ $(dk "$MGR" inspect -f '{{.State.Running}}' dist-once) == true ]] || break
    dk "$MGR" logs dist-once 2>&1 | grep -q '\[ ok \]' && break
    sleep 1
  done
  dist_log=$(dk "$MGR" logs dist-once 2>&1)
  dist_rc=$(dk "$MGR" inspect -f '{{.State.ExitCode}}' dist-once)
  dist_running=$(dk "$MGR" inspect -f '{{.State.Running}}' dist-once)
  dk "$MGR" rm -f dist-once >/dev/null 2>&1 || true
}
dist_once bad-pin "MACHINE_RUNNER_SWARM_RUNNER_VERSION=$OLD" "MACHINE_RUNNER_SWARM_RUNNER_SHA256=$zeros"
left=$(dk "$MGR" run --rm -v bad-pin:/v "$DIST_IMAGE" ls -A /v | paste -sd, -)
echo "RESULT test=distributor phase=mismatch exit=$dist_rc running=$dist_running installed_or_flipped=${left:-nothing}"
[[ $dist_rc -ne 0 && $dist_log == *"SHA-256 mismatch"* && $left == versions ]] || fail "a download with a wrong SHA-256 was accepted ($dist_rc, $dist_log, $left)"
[[ -z $(dk "$MGR" run --rm -v bad-pin:/v "$DIST_IMAGE" ls -A /v/versions) ]] || fail "something was installed"
dist_once bad-pin "MACHINE_RUNNER_SWARM_RUNNER_VERSION=$OLD" "MACHINE_RUNNER_SWARM_RUNNER_SHA256=$zeros,${PUBLISHED_SHA[$OLD]^^}"   # the list holds one hash that matches, in capitals
echo "RESULT test=distributor phase=sha256-list accepted_with_the_right_hash_in_the_list=$([[ $dist_log == *"[ ok ] current -> versions/$OLD"* ]] && echo yes || echo no)"
[[ $dist_log == *"[ ok ] current -> versions/$OLD"* ]] || fail "a list that contains the right SHA-256 was refused: $dist_log"
dist_once bad-input "MACHINE_RUNNER_SWARM_RUNNER_VERSION=latest"
[[ $dist_rc -ne 0 && $dist_log == *"must be current or a version"* ]] || fail "a bad version was accepted: $dist_log"

# ---------------------------------------------------------------------------------------------
# real: CircleCI's own manifest and bucket, nothing mirrored
# ---------------------------------------------------------------------------------------------
want=$(curl -fsSL "$REAL_BASE_URL/manifest.json" | python3 -c "
import json, sys
r = json.load(sys.stdin)['releases']
sha = r['current']['linux']['$ARCH']['sha256']
print(sorted((tuple(int(x) for x in v.split('.')), v) for v, e in r.items() if v[:1].isdigit() and e['linux']['$ARCH']['sha256'] == sha)[-1][1])")
dk "$MGR" run -d --name dist-real -v /runner-distributor.sh:/runner-distributor.sh:ro -v real-vol:/opt/machine-runner-swarm \
  -e MACHINE_RUNNER_SWARM_RUNNER_MAJOR="${want%%.*}" "$DIST_IMAGE" sh /runner-distributor.sh >/dev/null
wait_for 180 bash -c "docker exec $MGR docker logs dist-real 2>&1 | grep -q '\[ ok \]'" || { dk "$MGR" logs dist-real 2>&1 | tail -n 5; fail "the distributor did not install the current release"; }
real_cur=$(dk "$MGR" run --rm -v real-vol:/v "$DIST_IMAGE" readlink /v/current)
real_sha=$(dk "$MGR" run --rm -v real-vol:/v "$DIST_IMAGE" sh -c 'cd /v/current && sha256sum -c SHA256 >/dev/null && cut -d" " -f1 SHA256')
real_ver=$(dk "$MGR" run --rm -v real-vol:/v "$CIMG_IMAGE" /v/current/bin/circleci-runner --version 2>&1 | head -n 1)
dk "$MGR" rm -f dist-real >/dev/null 2>&1 || true
echo "RESULT test=distributor phase=real manifest=circleci current_resolves_to=$want installed=${real_cur#versions/} runner_reports=\"$real_ver\" record_matches=yes"
[[ ${real_cur#versions/} == "$want" && $real_ver == *"version $want"* && -n $real_sha ]] || fail "the real manifest's current is $want, the distributor installed $real_cur ($real_ver)"

dk "$N3" swarm leave --force >/dev/null 2>&1 || true
pass "no host install: the distributor fills every node (also a late joiner) with the verified runner and a record; an upgrade touches only the distributor and flips under running jobs, a rollback only flips, current follows the manifest within its major version, old versions are pruned, a changed binary exits 80 and is repaired, a wrong SHA-256 installs nothing"
