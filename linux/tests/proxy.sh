#!/usr/bin/env bash
# proxy.sh: the token proxy in front of the REAL circleci-runner, two classes through ONE proxy. Needs no CircleCI token.
#
# The real linux/stack/runners.yaml, the real entrypoints and runner binary, the proxy built from proxy/ and installed by the
# runner-distributor from the harness mirror (a SHA256SUMS next to the binary, as a GitHub release has it), and the fake API
# (fake-api.py, with token checks turned on: it answers a claim only when it carries a class token). The runners hold a placeholder
# config; the three class tokens are Swarm secrets of the proxy alone. Phases:
#   dist      the distributor installs the proxy next to the runner: SHA256SUMS, a record, root-owned; a wrong SHA256SUMS line or a hash that
#             MACHINE_RUNNER_SWARM_PROXY_SHA256 does not allow installs nothing; a changed binary is refused and repaired
#   order     the runners start BEFORE the proxy: when it comes up (a first start, no state) they claim at once, none is locked out
#   claims    each class claims with its own token and no other call carries one
#   midjob    the proxy restarts while the first jobs run: they finish (the API gets their step end and cleanup), the restart restores its state,
#             and the runners that claimed stay refused
#   checks    no class token in a runner container (files, environ and cmdline, as root), its spec or its log; one claim per container; 403 for a
#             container that is not a runner (either network); the proxy is hardened, healthy, and logs no token
#   restart   idle runners are present at a restart WITH state: they may claim afterwards (only a runner that claimed stays refused)
#   endjob    the proxy is down when the jobs end, and for a while after it: whether the runner reports the end of the job once the proxy is back
#   lost      the state file is gone but its marker is not: the proxy fails safe, every runner present is refused
#   fresh     the whole state directory is empty again (a first start): the idle runners present may claim
# Usage: proxy.sh        Env: TIMEOUT=240, JOB_S=60 (seconds a job runs)
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TIMEOUT=${TIMEOUT:-240}
JOB_S=${JOB_S:-75}
TOKEN_DEFAULT=CLASS-TOKEN-DEFAULT-7f3a91c0d2e84b65   # made up; only the proxy's secrets hold them
TOKEN_JAVA=CLASS-TOKEN-JAVA-2b6d0c58e19f4a73
TOKEN_HARDENED=CLASS-TOKEN-HARDENED-c41e8a07d95b3f26
PLACEHOLDER=machine-runner-swarm-placeholder
CLAIM=/api/v3/runner/claim
PROXY_IMAGE=$(sed -n 's/^    image: \(alpine:3\.[0-9]*\).*$/\1/p' "$stack_dir/runners.yaml")   # the image of the token-proxy service
DIST_IMAGE=$(sed -n 's/^    image: \(alpine:3@sha256:[0-9a-f]*\).*/\1/p' "$stack_dir/runners.yaml")   # and of the distributor
[[ -n $PROXY_IMAGE ]] || fail "no alpine image for token-proxy in runners.yaml"

session_begin
mgr=$SWARM_TEST_MGR
dind_load "$mgr" "$PROXY_IMAGE"
dind_load "$mgr" "$DIST_IMAGE"
publish_runner real
publish_proxy 0.0.1-test
state_dir=/var/lib/docker/volumes/${STACK}_proxy-state/_data
bin_vol=/var/lib/docker/volumes/${STACK}_runner-bin/_data
DIST_ENV=(MACHINE_RUNNER_SWARM_CHECK_INTERVAL=5s)

# --- the API, the secrets, the stack -----------------------------------------------------------------------------------
api_ip=$(docker exec "$mgr" hostname -i | awk '{ print $1 }')
docker cp "$tests_dir/fake-api.py" "$mgr:/fake-api.py"
idocker "$mgr" run -d --name fake-api --network host -v /fake-api.py:/fake-api.py:ro \
  -e "CLASS_TOKENS=linux-default=$TOKEN_DEFAULT,linux-java=$TOKEN_JAVA,linux-hardened=$TOKEN_HARDENED" \
  -e "PLACEHOLDER_TOKEN=$PLACEHOLDER" -e LOG_REQUESTS=1 "$CIMG_IMAGE" python3 /fake-api.py 8099 100 "$JOB_S" > /dev/null
config_yaml "$TOKEN_DEFAULT" | idocker "$mgr" secret create linux-default-token - > /dev/null
config_yaml "$TOKEN_JAVA" | idocker "$mgr" secret create linux-java-token - > /dev/null
config_yaml "$TOKEN_HARDENED" | idocker "$mgr" secret create linux-hardened-token - > /dev/null
config_yaml "$PLACEHOLDER" | idocker "$mgr" secret create runner-placeholder-token - > /dev/null
cat > "$work/proxy-ov.yaml" << EOF
services:
  token-proxy:
    command: ["-upstream", "http://$api_ip:8099", "-state-dir", "/var/tmp"]
  intruder-default:   # not a runner: another container on the class network
    image: $CIMG_IMAGE
    command: ["sleep", "infinity"]
    networks: [linux-default]
    deploy: {replicas: 1}
  intruder-java:
    image: $CIMG_IMAGE
    command: ["sleep", "infinity"]
    networks: [linux-java]
    deploy: {replicas: 1}
EOF
EXTRA_OVERRIDES="$work/proxy-ov.yaml"
dep() { # PROXY_REPLICAS: the stack with one runner of each class (they idle for 10 minutes), the proxy as given
  make_override "$work/ov.yaml" "linux-default 1 CIRCLECI_RUNNER_IDLE_TIMEOUT=600s" "linux-java 1 CIRCLECI_RUNNER_IDLE_TIMEOUT=600s" "token-proxy $1"
  deploy_stack "$mgr" "$work/ov.yaml"
}

# --- helpers ------------------------------------------------------------------------------------------------------------
dk() { docker exec "$mgr" docker "$@"; }
rlog() { service_logs "$mgr" "$1"; }   # runner log of a class
plog() { service_logs "$mgr" token-proxy; }
alog() { dk logs fake-api 2>&1; }
cont() { running_container "$mgr" "$1"; }
ip_of() { dk inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" | awk '{ print $1 }'; }
count() { grep -acF -- "$2" <<< "$1" || true; }
diagnostics() { echo "--- proxy"; plog | tail -n 25 | cut -c1-220; echo "--- runner linux-default"; rlog linux-default | tail -n 8 | cut -c1-200; echo "--- distributor"; rlog runner-distributor | tail -n 12 | cut -c1-200; echo "--- api"; alog | tail -n 15; }
probe() { local c=$1; shift; dk exec -u 0 "$c" "$@"; }   # as root in a container
claim_code() { probe "$1" curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $PLACEHOLDER" "http://token-proxy:8080$CLAIM" || true; }   # 000: no answer
upstream_claims() { count "$(alog)" "REQ POST $CLAIM"; }
api_count() { count "$(alog)" "$1"; }   # a literal piece of an API log line
hold() { dk exec fake-api touch /tmp/hold; }
release() { dk exec fake-api rm -f /tmp/hold; }
vol() { docker exec "$mgr" "$@"; }
proxy_restart() { dk service update -d --force "${STACK}_token-proxy" > /dev/null; }
OLD_PROXY=
plog_now() { dk logs "$(cont token-proxy)" 2>&1; }   # the log of the running container only
proxy_up() { # a container other than OLD_PROXY runs and has logged its start
  local c
  c=$(cont token-proxy)
  [[ -n $c && $c != "$OLD_PROXY" ]] && dk logs "$c" 2>&1 | grep -q 'listening on'
}
proxy_stop() {
  OLD_PROXY=$(cont token-proxy)
  dk service scale -d "${STACK}_token-proxy=0" > /dev/null
  no_proxy() { [[ -z $(cont token-proxy) ]]; }
  wait_for 60 no_proxy || fail "the proxy did not stop"
}
proxy_start() {
  dk service scale -d "${STACK}_token-proxy=1" > /dev/null
  wait_for 90 proxy_up || fail "the proxy did not come back: $(plog | tail -n 5)"
  state_line=$(plog_now | grep -aE 'state restored|no state|state lost' | tail -n 1 | cut -c21-)
}
# restart_proxy: restart it with the state it has, and wait until it is up again; the log line about its state is in $state_line
restart_proxy() {
  OLD_PROXY=$(cont token-proxy)
  proxy_restart
  wait_for 90 proxy_up || fail "the proxy did not come back: $(plog | tail -n 5)"
  state_line=$(plog_now | grep -aE 'state restored|no state|state lost' | tail -n 1 | cut -c21-)
}
claimed_from() { [[ $(count "$(plog)" "claim from $1 ($2): upstream status 200") -ge 1 ]]; }
polled_from() { [[ $(count "$(plog)" "claim from $1 ($2): upstream status 204") -ge 1 ]]; }
refused_from() { [[ $(count "$(plog)" "claim from $1 refused: this runner has already claimed") -ge 1 ]]; }
# scan CONTAINER NEEDLE...: files outside /proc, /sys and /dev, plus every process's environment and command line
scan() {
  local c=$1
  shift
  printf '%s\n' "$@" | idocker "$mgr" exec -i -u 0 "$c" sh -c 'cat > /dev/shm/needle
    grep -raFl -f /dev/shm/needle / --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev 2>/dev/null
    grep -aFl -f /dev/shm/needle /proc/[0-9]*/environ /proc/[0-9]*/cmdline 2>/dev/null; rm -f /dev/shm/needle' | grep -v '^$' | sed 's/^/    hit: /' || true
}
claims_of() { # CLASS: claim requests at the API that carried the class's own token
  api_count "REQ POST $CLAIM auth=CLASS:$1 "
}
# claimed N CLASS: the API has answered N claims of the class with a task (the proxy logs them as upstream status 200)
proxy_200() { count "$(plog)" "(tasks.$1): upstream status 200"; }
tasks_run() { count "$(rlog "$1")" 'TASK '; }   # the jobs that started in the runners of a class (the agent prints a TASK line)
jobs_ended() { # STEP: the API got this many calls of the end of a job (step end, and the cleanup event)
  api_count "REQ POST /api/v2/$1 auth=TASK"
}

# ---------------------------------------------------------------------------------------------
# dist: the distributor installs the proxy
# ---------------------------------------------------------------------------------------------
dep 0   # the proxy waits: the runners go first (phase order)
wait_for 120 vol test -L "$bin_vol/proxy/current" || fail "the distributor did not install the proxy: $(rlog runner-distributor | tail -n 5)"
[[ $(vol readlink "$bin_vol/proxy/current") == versions/$PROXY_VERSION ]] || fail "proxy/current is $(vol readlink "$bin_vol/proxy/current")"
installed=$(vol sha256sum "$bin_vol/proxy/versions/$PROXY_VERSION/bin/machine-runner-swarm-proxy" | cut -d' ' -f1)
[[ $installed == "$PROXY_SHA" ]] || fail "the installed proxy is not the one on the mirror"
[[ $(vol sh -c "cd $bin_vol/proxy/versions/$PROXY_VERSION && cat SHA256") == "$PROXY_SHA  bin/machine-runner-swarm-proxy" ]] || fail "the record of the proxy does not name the binary"
[[ $(vol cat "$bin_vol/proxy/versions/$PROXY_VERSION/VERSION") == "$PROXY_VERSION" ]] || fail "VERSION of the proxy"
[[ -z $(vol find "$bin_vol" ! -type l \( ! -user root -o -perm /022 \)) ]] || fail "a file of the volume is not root-owned or is group/world writable"
echo "RESULT test=proxy phase=dist installed=yes version=$PROXY_VERSION sha256sums_checked=yes record=yes root_owned=yes"

# a wrong line in SHA256SUMS, and a hash that the strict list does not allow: nothing is installed, the old proxy stays active
publish_proxy 0.0.2-test
sed -i "s/^[0-9a-f]\{64\}  machine-runner-swarm-proxy_linux_$ARCH\$/$(printf '2%.0s' $(seq 1 64))  machine-runner-swarm-proxy_linux_$ARCH/" "$work/mirror/proxy/v0.0.2-test/SHA256SUMS"
docker cp "$work/mirror/." "$mgr:/mirror/" > /dev/null
dep 0
bad() { [[ $(count "$(rlog runner-distributor)" 'SHA-256 mismatch for machine-runner-swarm-proxy_linux') -ge 1 ]]; }
wait_for 90 bad || fail "the distributor did not refuse a SHA256SUMS line that does not match the binary"
[[ $(vol readlink "$bin_vol/proxy/current") == versions/0.0.1-test ]] || fail "the active proxy changed after a mismatch"
vol test ! -d "$bin_vol/proxy/versions/0.0.2-test" || fail "a proxy that did not match was installed"
publish_proxy 0.0.3-test   # a good one again, but the strict list names another hash
DIST_ENV+=("MACHINE_RUNNER_SWARM_PROXY_SHA256=$(printf '3%.0s' $(seq 1 64))")
dep 0
strict() { [[ $(count "$(rlog runner-distributor)" 'does not allow: refusing to install') -ge 1 ]]; }
wait_for 90 strict || fail "the distributor ignored MACHINE_RUNNER_SWARM_PROXY_SHA256"
vol test ! -d "$bin_vol/proxy/versions/0.0.3-test" || fail "a proxy that the strict list does not allow was installed"
DIST_ENV=("MACHINE_RUNNER_SWARM_PROXY_SHA256=$PROXY_SHA")   # the right hash: it installs
dep 0
ok3() { [[ $(vol readlink "$bin_vol/proxy/current") == versions/0.0.3-test ]]; }
wait_for 90 ok3 || fail "the distributor did not install a proxy that the strict list allows: $(rlog runner-distributor | tail -n 5)"
echo "RESULT test=proxy phase=dist wrong_line_refused=yes strict_list_refused=yes strict_list_allowed=yes active=$(vol readlink "$bin_vol/proxy/current")"
DIST_ENV=(MACHINE_RUNNER_SWARM_CHECK_INTERVAL=5s)
dep 0

# ---------------------------------------------------------------------------------------------
# order: the runners are up and polling before the proxy exists; it starts (a first start), and they claim
# ---------------------------------------------------------------------------------------------
started() { [[ $(count "$(rlog linux-default)" 'circleci-runner-entrypoint: runner=') -ge 1 && $(count "$(rlog linux-java)" 'circleci-runner-entrypoint: runner=') -ge 1 ]]; }
wait_for "$TIMEOUT" started || fail "the runners did not start"
sleep 15   # they fail to claim: there is no proxy
before_def=$(cont linux-default)
before_java=$(cont linux-java)
[[ $(upstream_claims) -eq 0 ]] || fail "a claim reached the API without a proxy"
proxy_start
first_line=$state_line
class_claimed() { [[ $(count "$(plog)" "(tasks.$1): upstream status 200") -ge 1 ]]; }
wait_for "$TIMEOUT" class_claimed linux-default || fail "the runner that was there before the proxy did not claim after its first start"
wait_for "$TIMEOUT" class_claimed linux-java || fail "the runner that was there before the proxy did not claim after its first start"
# one task each is enough: hold the queue, so the containers that replace these two idle and poll (204)
hold
c_def=$(cont linux-default)
c_java=$(cont linux-java)
echo "RESULT test=proxy phase=order runners_before_the_proxy=2 same_containers_claimed=$([[ $c_def == "$before_def" && $c_java == "$before_java" ]] && echo yes || echo no) proxy_said=\"$first_line\""
[[ $c_def == "$before_def" && $c_java == "$before_java" ]] || fail "the claims did not come from the containers that waited for the proxy"
[[ $first_line == *"first start"* ]] || fail "the proxy did not treat its first start as one: $first_line"

# ---------------------------------------------------------------------------------------------
# claims
# ---------------------------------------------------------------------------------------------
ip_def=$(ip_of "$c_def")
ip_java=$(ip_of "$c_java")
echo "RESULT test=proxy phase=claims classes=2 default_ip=$ip_def java_ip=$ip_java proxy_claims=$(count "$(plog)" 'upstream status 200')"
# the label of the token at the API must match the class of the claimer: counted per class on both sides
same_count() { [[ $(count "$(plog)" "(tasks.$class): upstream status") -eq $(claims_of "$class") ]]; }
for class in linux-default linux-java; do
  wait_for 15 same_count || true   # a claim can be on its way
  at_proxy=$(count "$(plog)" "(tasks.$class): upstream status")
  at_api=$(claims_of "$class")
  echo "RESULT test=proxy phase=claims class=$class claims_at_proxy=$at_proxy claims_at_api_with_own_token=$at_api"
  [[ $at_proxy -ge 1 && $at_proxy -eq $at_api ]] || fail "$class: claims at the proxy ($at_proxy) and claims at the API with its own token ($at_api) differ"
done
[[ $(alog | grep -a "REQ POST $CLAIM" | grep -avc 'auth=CLASS:') -eq 0 ]] || fail "a claim reached the API without a class token"
[[ $(alog | grep -a 'auth=CLASS:' | grep -avc "REQ POST $CLAIM") -eq 0 ]] || fail "a class token reached an API call other than the claim"
alog | grep -a "REQ POST $CLAIM" | grep -aq 'ua=.*machine-runner-swarm-proxy/' || fail "the claim does not carry the proxy's User-Agent tag"
echo "RESULT test=proxy phase=claims api_calls: $(alog | grep -a '^REQ' | sed 's/^REQ //; s/ ua=.*//' | sort | uniq -c | tr '\n' ';' | tr -s ' ')"

# ---------------------------------------------------------------------------------------------
# midjob: the proxy restarts while the first two jobs run
# ---------------------------------------------------------------------------------------------
end0=$(jobs_ended step/end)
clean0=$(jobs_ended task/event/cleanup)
claims0=$(upstream_claims)
down=$SECONDS
proxy_stop
sleep 5
proxy_start
outage=$((SECONDS - down))
[[ $state_line == *"state restored: 2 runner"* ]] || fail "the restarted proxy did not restore the two runners that claimed: $state_line"
reachable() { [[ $(claim_code "$1") != 000 ]]; }   # the name token-proxy takes a moment to point at the new container
wait_for 30 reachable "$c_def" || fail "the restarted proxy is not reachable from the runner"
after_c_def=$(claim_code "$c_def")
after_c_java=$(claim_code "$c_java")
echo "RESULT test=proxy phase=midjob outage_seconds=$outage state=\"$state_line\" busy_runners_refused=$after_c_def,$after_c_java reached_upstream=$(($(upstream_claims) - claims0))"
[[ $after_c_def == 403 && $after_c_java == 403 && $(upstream_claims) == "$claims0" ]] || fail "a runner that had claimed could claim again after the restart"

# ---------------------------------------------------------------------------------------------
# checks: what no job can reach, who may claim, and the proxy itself
# ---------------------------------------------------------------------------------------------
# no class token in a runner container
for c in "$c_def" "$c_java"; do
  real_hits=$(scan "$c" "$TOKEN_DEFAULT" "$TOKEN_JAVA" "$TOKEN_HARDENED")
  ctrl_hits=$(scan "$c" "$PLACEHOLDER")
  echo "RESULT test=proxy phase=claims scan container=$c as=root real_token_hits=$(grep -c . <<< "$real_hits") placeholder_hits_control=$(grep -c . <<< "$ctrl_hits")"
  [[ -z $real_hits ]] || fail "a class token is in a runner container: $real_hits"
  [[ -n $ctrl_hits ]] || fail "the control scan did not find the placeholder: the scan is blind"
  [[ -z $(probe "$c" sh -c 'ls /run/secrets/*-token 2>/dev/null') ]] || fail "a class token file is mounted in a runner container"
done
spec=$(dk inspect "$c_def" "$c_java"; for s in linux-default linux-java; do dk service inspect "${STACK}_$s"; rlog "$s"; done)
for t in "$TOKEN_DEFAULT" "$TOKEN_JAVA" "$TOKEN_HARDENED"; do
  [[ $spec != *"$t"* ]] || fail "a class token is in a runner's spec or log"
done
c_proxy=$(cont token-proxy)
[[ $(dk exec -u 65534 "$c_proxy" cat /run/secrets/linux-default-token) == *"$TOKEN_DEFAULT"* ]] || fail "the proxy does not hold the class token: the scan control is void"

# one claim per container
before=$(upstream_claims)
second=$(claim_code "$c_def")
second_java=$(claim_code "$c_java")
echo "RESULT test=proxy phase=claims second_claim default=$second java=$second_java reached_upstream=$(($(upstream_claims) - before))"
[[ $second == 403 && $second_java == 403 && $(upstream_claims) == "$before" ]] || fail "a second claim from the same container was not refused"

# containers that are not runners, on either class network
i_def=$(cont intruder-default)
i_java=$(cont intruder-java)
code_def=$(claim_code "$i_def")
code_java=$(claim_code "$i_java")
raw=$(probe "$c_def" python3 -c 'import socket; socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)' > /dev/null 2>&1 && echo allowed || echo denied)
echo "RESULT test=proxy phase=claims intruder on_default_network=$code_def on_java_network=$code_java raw_socket_runner_as_root=$raw reached_upstream=$(($(upstream_claims) - before))"
[[ $code_def == 403 && $code_java == 403 && $(upstream_claims) == "$before" ]] || fail "a claim from a container that is not a runner was not refused"
[[ $raw == denied ]] || fail "root in a runner container can open a raw socket: runners.yaml no longer drops NET_RAW, so the source address can be spoofed"

# the proxy: hardened, healthy, quiet
health=$(probe "$i_def" curl -s -m 5 -o /dev/null -w '%{http_code}' http://token-proxy:8080/healthz)
healthy() { [[ $(dk inspect -f '{{.State.Health.Status}}' "$(cont token-proxy)") == healthy ]]; }
wait_for 60 healthy || fail "Swarm does not report the proxy healthy"
hard=$(dk inspect -f 'readonly={{.HostConfig.ReadonlyRootfs}} cap_drop={{.HostConfig.CapDrop}} user={{.Config.User}}' "$c_proxy")
echo "RESULT test=proxy phase=claims proxy health_endpoint=$health swarm_health=healthy $hard"
[[ $health == 200 && $hard == "readonly=true cap_drop=[ALL] user=65534" ]] || fail "the proxy is not healthy or not hardened: health=$health $hard"
for t in "$TOKEN_DEFAULT" "$TOKEN_JAVA" "$TOKEN_HARDENED"; do
  [[ $(plog) != *"$t"* ]] || fail "the proxy logged a class token"
done
[[ -n $(vol sh -c "cat $state_dir/state.json") ]] || fail "the proxy keeps no state"
echo "RESULT test=proxy phase=claims state=$(vol cat "$state_dir/state.json")"

# the jobs end on their own; the API gets the end of both, and the runners report success
ended() { [[ $(jobs_ended step/end) -ge $((end0 + 2)) && $(jobs_ended task/event/cleanup) -ge $((clean0 + 2)) ]]; }
wait_for "$TIMEOUT" ended || fail "the jobs that ran through a proxy restart did not report their end: step_end=$(jobs_ended step/end) cleanup=$(jobs_ended task/event/cleanup)"
exit0=$(for c in "$c_def" "$c_java"; do dk inspect -f '{{.State.ExitCode}}' "$c"; done | sort -u | tr '\n' ',')
echo "RESULT test=proxy phase=midjob jobs_reported_end=2 exit_codes=${exit0%,}"
[[ $exit0 == 0, ]] || fail "a runner container exited with $exit0 after a proxy restart in the middle of its job"

# ---------------------------------------------------------------------------------------------
# restart: idle runners are present at a restart with state: they may claim afterwards
# ---------------------------------------------------------------------------------------------
new_containers() { # the replacements of the containers $1 and $2: they are in n_def and n_java
  n_def=$(cont linux-default)
  n_java=$(cont linux-java)
  [[ -n $n_def && $n_def != "$1" && -n $n_java && $n_java != "$2" ]]
}
wait_for "$TIMEOUT" new_containers "$c_def" "$c_java" || fail "no new containers after the jobs"
nip_def=$(ip_of "$n_def")
nip_java=$(ip_of "$n_java")
idle() { polled_from "$1" tasks.linux-default && polled_from "$2" tasks.linux-java; }
wait_for 120 idle "$nip_def" "$nip_java" || fail "the new containers do not poll"
restart_proxy
echo "RESULT test=proxy phase=restart idle_runners_present=2 state=\"$state_line\""
[[ $state_line == *"state restored: 0 runner"* ]] || fail "the restart did not restore an empty latch: $state_line"
end1=$(jobs_ended step/end)
clean1=$(jobs_ended task/event/cleanup)
release
claimed_both() { claimed_from "$1" tasks.linux-default && claimed_from "$2" tasks.linux-java; }
wait_for "$TIMEOUT" claimed_both "$nip_def" "$nip_java" || fail "the idle runners that were present at a restart with state could not claim"
hold
echo "RESULT test=proxy phase=restart idle_runners_claimed_after_the_restart=yes"
[[ $(claim_code "$n_def") == 403 ]] || fail "a runner that claimed after the restart could claim twice"

# ---------------------------------------------------------------------------------------------
# endjob: the proxy is down when these jobs end (they end JOB_S seconds after their claim) and a while after
# ---------------------------------------------------------------------------------------------
proxy_stop
log "endjob: the proxy stays down until after the jobs end (up to ${JOB_S}s)"
exited() { [[ $(dk inspect -f '{{.State.Status}}' "$n_def") == exited && $(dk inspect -f '{{.State.Status}}' "$n_java") == exited ]]; }
if wait_for "$((JOB_S + 20))" exited; then ended_down=yes; else ended_down=no; fi
echo "RESULT test=proxy phase=endjob runner_containers_exited_while_the_proxy_was_down=$ended_down default=\"$(dk inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$n_def")\" java=\"$(dk inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$n_java")\""
sleep 10
proxy_start
endjob_report() { [[ $(jobs_ended step/end) -ge $((end1 + 2)) && $(jobs_ended task/event/cleanup) -ge $((clean1 + 2)) ]]; }
if wait_for 120 endjob_report; then reported=yes; else reported=no; fi
echo "RESULT test=proxy phase=endjob runner_reported_the_end_once_the_proxy_was_back=$reported step_end=$(($(jobs_ended step/end) - end1)) cleanup=$(($(jobs_ended task/event/cleanup) - clean1)) default=\"$(dk inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$n_def")\" java=\"$(dk inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$n_java")\" (the fake agent does not call the API: these are the calls of the runner)"

# ---------------------------------------------------------------------------------------------
# lost: the state file is gone, its marker is not
# ---------------------------------------------------------------------------------------------
wait_for "$TIMEOUT" new_containers "$n_def" "$n_java" || fail "no new containers after the second jobs"
lip_def=$(ip_of "$n_def")
lip_java=$(ip_of "$n_java")
wait_for 120 idle "$lip_def" "$lip_java" || fail "the replacement runners do not poll"
vol rm -f "$state_dir/state.json"
vol test -e "$state_dir/.initialized" || fail "the state marker is missing"
restart_proxy
echo "RESULT test=proxy phase=lost state=\"$state_line\""
[[ $state_line == *"state lost"* ]] || fail "a state without its file was not treated as lost: $state_line"
claims2=$(upstream_claims)
release
refused_both() { refused_from "$1" && refused_from "$2"; }
wait_for 60 refused_both "$lip_def" "$lip_java" || fail "a proxy that lost its state did not refuse the runners present"
[[ $(upstream_claims) == "$claims2" ]] || fail "a claim reached the API through a proxy that lost its state"
echo "RESULT test=proxy phase=lost idle_runners_refused=yes reached_upstream=0"

# ---------------------------------------------------------------------------------------------
# fresh: an empty state directory is a first start again
# ---------------------------------------------------------------------------------------------
hold
dk service update -d --force --update-parallelism 0 "${STACK}_linux-default" > /dev/null
dk service update -d --force --update-parallelism 0 "${STACK}_linux-java" > /dev/null
wait_for "$TIMEOUT" new_containers "$n_def" "$n_java" || fail "the idle runners were not replaced"
fip_def=$(ip_of "$n_def")
fip_java=$(ip_of "$n_java")
wait_for 120 idle "$fip_def" "$fip_java" || fail "the replacement runners do not poll"
vol sh -c "rm -f $state_dir/state.json $state_dir/.initialized"
restart_proxy
echo "RESULT test=proxy phase=fresh state=\"$state_line\""
[[ $state_line == *"first start"* ]] || fail "an empty state directory was not a first start: $state_line"
release
wait_for "$TIMEOUT" claimed_both "$fip_def" "$fip_java" || fail "the idle runners present at a first start could not claim"
hold
echo "RESULT test=proxy phase=fresh idle_runners_claimed=yes"

# ---------------------------------------------------------------------------------------------
# tamper: the binary in the volume is changed: the proxy does not start from it, the distributor repairs it
# ---------------------------------------------------------------------------------------------
active=$(vol readlink "$bin_vol/proxy/current")
# hold the distributor back (no node matches), so that it cannot repair the binary before the proxy looks at it
dk service update -d --constraint-add 'node.labels.hold == yes' "${STACK}_runner-distributor" > /dev/null
no_distributor() { [[ -z $(cont runner-distributor) ]]; }
wait_for 60 no_distributor || fail "the distributor did not stop"
docker exec "$mgr" sh -c "cd $bin_vol/proxy/$active/bin && cp machine-runner-swarm-proxy t && printf x >> t && mv t machine-runner-swarm-proxy"   # the running binary is busy: replace it
OLD_PROXY=$(cont token-proxy)
proxy_restart
refused_start() { [[ $(count "$(plog)" 'does not match its SHA-256 record') -ge 1 ]]; }
wait_for 90 refused_start || fail "the proxy started from a changed binary"
echo "RESULT test=proxy phase=tamper changed_binary_refused=yes"
dk service update -d --constraint-rm 'node.labels.hold == yes' "${STACK}_runner-distributor" > /dev/null   # the distributor is back and repairs it
wait_for 120 proxy_up || fail "the distributor did not repair the binary: $(rlog runner-distributor | tail -n 5)"
echo "RESULT test=proxy phase=tamper repaired_by_the_distributor=yes"

pass "the distributor installs the proxy from the SHA256SUMS of its release; runners that start before the proxy are not locked out; two classes claim through one proxy, each with its own token and nowhere else; no class token in a runner container; one claim per container; 403 for non-runners; a restart with state refuses only the runners that claimed, a lost state fails safe, and an empty one is a first start; a changed binary does not start"
