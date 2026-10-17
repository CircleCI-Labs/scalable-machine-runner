#!/usr/bin/env bash
# proxy.sh: the token proxy in front of the REAL circleci-runner, two classes through ONE proxy. Needs no CircleCI token.
#
# The real linux/stack/runners.yaml, the real entrypoint and runner binary (installed by the runner-distributor from the harness mirror),
# the proxy IMAGE built from proxy/ (lib.sh proxy_image_build) and the fake API (fake-api.py, with token checks turned on: it answers a
# claim only when it carries a class token). The runners hold a placeholder config; the three class tokens are Swarm secrets of the proxy
# alone. Phases:
#   order     the runners start BEFORE the proxy: when it comes up (a first start, no state) it asks the API (scale) how many tasks run, none do,
#             and they claim at once, none is locked out
#   claims    each class claims with its own token and no other call carries one
#   midjob    the proxy restarts while the first jobs run: they finish (the API gets their step end and cleanup), the restart restores its state,
#             and the runners that claimed stay refused
#   checks    no class token in a runner container (files, environ and cmdline, as root), its spec or its log; one claim per container; 403 for a
#             container that is not a runner (either network); the proxy is hardened (non-root, read-only, no capabilities), healthy through the
#             healthcheck of its image, and logs no token
#   restart   idle runners are present at a restart WITH state: they may claim afterwards (only an address that claimed stays refused, and it is
#             released once DNS has not listed it for 30 s)
#   endjob    the proxy is down when the jobs end, and for a while after it: whether the runner reports the end of the job once the proxy is back
#   savefail  the proxy cannot write its state when an idle runner claims: the runner does not get its task (503), the proxy removes state.json
#             and keeps the marker, and the start after that is the fail-safe one: the API says that tasks run, so every runner present is refused
#   lost      the state file is gone but its marker is not, and the API says that tasks run: every runner present is refused. The refused
#             runners keep polling and do not exit (the proxy answers 403, not 401: the runner does not exit on a 401 either, see docs/operations.md)
#   unknown   the same, and the scale call fails: the proxy fails safe, every runner present is refused
#   fresh     the whole state directory is empty again (a first start) and no task runs: the idle runners present may claim
#   lostanswer  a claim reaches the API and the API closes the connection without an answer: the proxy answers 502 and latches the runner
#             (fail closed: the task may have been handed out), saves it, and a restart keeps it refused
#   limits    one container that floods the proxy gets 429 with Retry-After for every path, and the others are not affected
#   summary   the proxy logs one summary line a minute with the counts, and does not log the claims that got no task (204)
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
SCALE=/api/v3/runner/scale
DIST_IMAGE=$(sed -n 's/^    image: \(alpine:3@sha256:[0-9a-f]*\).*/\1/p' "$stack_dir/runners.yaml")   # the image of the distributor
[[ -n $DIST_IMAGE ]] || fail "no alpine image for runner-distributor in runners.yaml"

session_begin
mgr=$SWARM_TEST_MGR
dind_load "$mgr" "$DIST_IMAGE"
publish_runner real
state_dir=/var/lib/docker/volumes/${STACK}_proxy-state/_data
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
    command: ["-upstream", "http://$api_ip:8099", "-state-dir", "/state"]
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
  deploy_stack "$mgr" "$work/ov.yaml" runners.yaml classes-extra.yaml   # three classes: linux-java and linux-hardened are in classes-extra.yaml
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
api_running() { dk exec fake-api python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8099/_running/$1')"; }   # what the scale call reports as running tasks
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

dep 0   # the proxy waits: the runners go first (phase order)

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
[[ $first_line == *"no state (a first start)"* && $first_line == *"tasks.linux-default: CircleCI reports 0 running tasks"* ]] || fail "the proxy did not treat its first start as one, and ask the API: $first_line"
[[ $(api_count "REQ GET $SCALE auth=CLASS:linux-default ") -ge 1 && $(api_count "REQ GET $SCALE auth=CLASS:linux-java ") -ge 1 ]] || fail "the proxy did not ask for the scale with the token of each class"

# ---------------------------------------------------------------------------------------------
# claims
# ---------------------------------------------------------------------------------------------
ip_def=$(ip_of "$c_def")
ip_java=$(ip_of "$c_java")
echo "RESULT test=proxy phase=claims classes=2 default_ip=$ip_def java_ip=$ip_java proxy_claims=$(count "$(plog)" 'upstream status 200')"
# The label of the token at the API must match the class of the claimer. The proxy logs the claims that got a task and no longer the ones
# that got none (204), so each task that it logged for a class is a claim at the API with the token of that class, and there are at
# least as many claims at the API (the 204 ones come on top).
for class in linux-default linux-java; do
  at_proxy=$(count "$(plog)" "(tasks.$class): upstream status 200")
  at_api=$(claims_of "$class")
  echo "RESULT test=proxy phase=claims class=$class tasks_at_proxy=$at_proxy claims_at_api_with_own_token=$at_api"
  [[ $at_proxy -ge 1 && $at_api -ge $at_proxy ]] || fail "$class: tasks at the proxy ($at_proxy) and claims at the API with its own token ($at_api) do not match"
done
[[ $(alog | grep -a "REQ POST $CLAIM" | grep -avc 'auth=CLASS:') -eq 0 ]] || fail "a claim reached the API without a class token"
[[ $(alog | grep -a 'auth=CLASS:' | grep -av -e "REQ POST $CLAIM" -e "REQ GET $SCALE " | wc -l) -eq 0 ]] || fail "a class token reached an API call other than the claim and the scale call of a start with no state"
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
[[ $state_line == *"state restored"* && $state_line == *"tasks.linux-default: 1 runner(s) have claimed"* && $state_line == *"tasks.linux-java: 1 runner(s) have claimed"* ]] || fail "the restarted proxy did not restore the two runners that claimed: $state_line"
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
[[ $(claims_of linux-default) -ge 1 && $(claims_of linux-java) -ge 1 ]] || fail "the API has not seen the class tokens, which only the proxy holds: the scan control is void"

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
body_def=$(probe "$i_def" curl -s -m 5 -X POST -H "Authorization: Bearer $PLACEHOLDER" "http://token-proxy:8080$CLAIM" || true)
raw=$(probe "$c_def" python3 -c 'import socket; socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)' > /dev/null 2>&1 && echo allowed || echo denied)
echo "RESULT test=proxy phase=claims intruder on_default_network=$code_def on_java_network=$code_java raw_socket_runner_as_root=$raw reached_upstream=$(($(upstream_claims) - before))"
[[ $code_def == 403 && $code_java == 403 && $(upstream_claims) == "$before" ]] || fail "a claim from a container that is not a runner was not refused"
[[ $body_def == "claim refused" ]] || fail "the 403 body is not the generic one: $body_def"
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
# idle: the idle runner of each class polls. The proxy does not log a claim that gets no task, but the API sees every claim that the proxy
# forwards, with the token of its class: a new claim of each class after this call starts is from the one idle runner of that class (the
# queue is held, and the claims of the containers that left are over). The arguments (the addresses) are for the reader.
claims_grew() { [[ $(claims_of linux-default) -gt $1 && $(claims_of linux-java) -gt $2 ]]; }
idle() {
  local d j
  d=$(claims_of linux-default)
  j=$(claims_of linux-java)
  wait_for 30 claims_grew "$d" "$j"
}
wait_for 120 idle "$nip_def" "$nip_java" || fail "the new containers do not poll"
restart_proxy
echo "RESULT test=proxy phase=restart idle_runners_present=2 state=\"$state_line\""
# the containers of the jobs that ended have left, but their addresses stay latched until DNS has not listed them for 30 s: they are in the state
[[ $state_line == *"state restored"* ]] || fail "the restart did not restore its state: $state_line"
end1=$(jobs_ended step/end)
clean1=$(jobs_ended task/event/cleanup)
release
claimed_both() { claimed_from "$1" tasks.linux-default && claimed_from "$2" tasks.linux-java; }
wait_for "$TIMEOUT" claimed_both "$nip_def" "$nip_java" || fail "the idle runners that were present at a restart with state could not claim"
hold
echo "RESULT test=proxy phase=restart idle_runners_claimed_after_the_restart=yes"
if [[ $nip_def != "$ip_def" && $nip_java != "$ip_java" ]]; then   # the addresses of the old containers are released after 30 s without DNS
  old_released() { [[ $(count "$(plog_now)" "released $ip_def (tasks.linux-default)") -ge 1 && $(count "$(plog_now)" "released $ip_java (tasks.linux-java)") -ge 1 ]]; }
  wait_for 90 old_released || fail "the addresses of the containers that left were not released"
  echo "RESULT test=proxy phase=restart addresses_of_the_old_containers_released=yes"
fi
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
# lost: the state file is gone, its marker is not, and the API says that tasks run
# ---------------------------------------------------------------------------------------------
wait_for "$TIMEOUT" new_containers "$n_def" "$n_java" || fail "no new containers after the second jobs"
lip_def=$(ip_of "$n_def")
lip_java=$(ip_of "$n_java")
wait_for 120 idle "$lip_def" "$lip_java" || fail "the replacement runners do not poll"
# savefail: the state cannot be written when the idle runners claim (a directory in the place of the temporary file of the state)
echo "RESULT test=proxy phase=savefail idle_runners_present=2"
tasks_before=$(($(tasks_run linux-default) + $(tasks_run linux-java)))
claims_before=$(upstream_claims)
got_before=$(count "$(plog_now)" "upstream status 200")
vol sh -c "mkdir -p $state_dir/state.json.tmp && touch $state_dir/state.json.tmp/x"
release
# Which write fails first is not fixed: the poll of the proxy (released addresses, every second) or the first claim that gets a task.
#  - a claim that gets a task and then cannot be latched is failed (503, "the task is not handed to the runner"), and its address stays
#    latched in memory, so its next claim is refused as one that has already claimed;
#  - once any write has failed, every other claim is refused (503, "refused: the state cannot be written") without reaching the API.
# Either way no runner gets a task. Each idle runner must end up in one of the two states, judged from the log of the proxy (polled with a
# deadline, whatever the order of the lines), and after that no claim may reach the API.
not_saved_ip() { # IP: this runner's claim was failed or refused because of the state, in the log snapshot $slog
  [[ $(count "$slog" "claim from $1 refused: the state cannot be written") -ge 1 ||
    ($(grep -acE "claim from ${1//./\\.} \(.*the task is not handed to the runner" <<< "$slog" || true) -ge 1 &&
      $(count "$slog" "claim from $1 refused: this runner has already claimed") -ge 1) ]]
}
not_saved() {
  slog=$(plog_now)
  not_saved_ip "$lip_def" && not_saved_ip "$lip_java"
}
wait_for 90 not_saved || fail "the claims of the idle runners were not failed although the state could not be written (default $lip_def, java $lip_java): $(plog_now | grep -aE "claim from ($lip_def|$lip_java)|state: cannot" | tail -n 8 | cut -c1-200)"
refusals_now() { count "$(plog_now)" "claim from $lip_def refused"; }
refusals_java_now() { count "$(plog_now)" "claim from $lip_java refused"; }
claims_gated=$(upstream_claims)
r_def=$(refusals_now)
r_java=$(refusals_java_now)
# both runners are refused again, and nothing of that reached the API
refused_again() { [[ $(refusals_now) -gt $r_def && $(refusals_java_now) -gt $r_java ]]; }
wait_for 60 refused_again || fail "the idle runners did not claim again while the state could not be written: the phase tests nothing"
[[ $(upstream_claims) -eq $claims_gated ]] || fail "a claim reached the API while the state could not be written ($claims_gated before, $(upstream_claims) after)"
hold
slog=$(plog_now)
got=$(($(count "$slog" "upstream status 200") - got_before))
not_handed=$(count "$slog" "the task is not handed to the runner")
[[ $got -eq $not_handed ]] || fail "$got claims got a task from the API in this phase and $not_handed were failed: a runner may have got its task"
echo "RESULT test=proxy phase=savefail claims_that_got_a_task=$got claims_failed_at_the_latch=$not_handed claims_at_the_api_in_the_phase=$((claims_gated - claims_before)) claims_at_the_api_once_both_were_refused=0"
vol test ! -e "$state_dir/state.json" || fail "a failed save left state.json, which is behind the latches in memory"
vol test -e "$state_dir/.initialized" || fail "a failed save removed the state marker"
unhealthy() { [[ $(probe "$i_def" curl -s -m 5 -o /dev/null -w '%{http_code}' http://token-proxy:8080/healthz || true) == 503 ]]; }
wait_for 20 unhealthy || fail "the proxy that cannot write its state does not report unhealthy"
sleep 5
[[ $(($(tasks_run linux-default) + $(tasks_run linux-java))) -eq $tasks_before ]] || fail "a runner got a task although its latch could not be saved"
echo "RESULT test=proxy phase=savefail runners_got_a_task=no state_json_removed=yes marker_kept=yes proxy_health=503"
proxy_stop
vol rm -rf "$state_dir/state.json.tmp"
api_running 2   # two tasks run, as far as the API says
proxy_start
echo "RESULT test=proxy phase=savefail state=\"$state_line\""
[[ $state_line == *"state lost"* && $state_line == *"tasks.linux-default: CircleCI reports 2 running task(s)"* ]] || fail "the start after a failed save was not the fail-safe one: $state_line"
refused_now() { [[ $(count "$(plog_now)" "claim from $1 refused: this runner has already claimed") -ge 1 ]]; }
refused_both() { refused_now "$1" && refused_now "$2"; }
wait_for 60 refused_both "$lip_def" "$lip_java" || fail "a proxy that started after a failed save did not refuse the runners present"
echo "RESULT test=proxy phase=savefail idle_runners_refused_after_the_next_start=yes"

# ---------------------------------------------------------------------------------------------
# lost: the state file is gone, its marker is not, and the API says that tasks run
# ---------------------------------------------------------------------------------------------
vol rm -f "$state_dir/state.json"
vol test -e "$state_dir/.initialized" || fail "the state marker is missing"
api_running 2   # two tasks run, as far as the API says
restart_proxy
echo "RESULT test=proxy phase=lost state=\"$state_line\""
[[ $state_line == *"state lost"* && $state_line == *"tasks.linux-default: CircleCI reports 2 running task(s)"* ]] || fail "a state without its file was not treated as lost, with the API's count: $state_line"
claims2=$(upstream_claims)
release
wait_for 60 refused_both "$lip_def" "$lip_java" || fail "a proxy that lost its state while tasks run did not refuse the runners present"
[[ $(upstream_claims) == "$claims2" ]] || fail "a claim reached the API through a proxy that lost its state"
echo "RESULT test=proxy phase=lost idle_runners_refused=yes reached_upstream=0"
# a refused runner keeps its container and polls on: it does not exit at the refusal (nor would it at a 401)
refusals=$(count "$(plog_now)" "claim from $lip_def refused")
sleep 12
[[ $(dk inspect -f '{{.State.Status}}' "$n_def") == running && $(dk inspect -f '{{.State.Status}}' "$n_java") == running ]] || fail "a refused runner exited"
[[ $(count "$(plog_now)" "claim from $lip_def refused") -gt $refusals ]] || fail "a refused runner does not poll on"
echo "RESULT test=proxy phase=lost refused_runners_keep_polling=yes"

# ---------------------------------------------------------------------------------------------
# unknown: the scale call fails (a first start again): fail safe
# ---------------------------------------------------------------------------------------------
dk exec fake-api touch /tmp/scale-fail
api_running 0   # the API would say 0, but the call fails
vol sh -c "rm -f $state_dir/state.json $state_dir/.initialized"
restart_proxy
echo "RESULT test=proxy phase=unknown state=\"$state_line\""
[[ $state_line == *"no state (a first start)"* && $state_line == *"CircleCI does not say how many tasks run"* && $state_line == *"failing safe"* ]] || fail "a failing scale call did not fail safe: $state_line"
wait_for 60 refused_both "$lip_def" "$lip_java" || fail "a proxy that cannot ask the API did not refuse the runners present"
[[ $(upstream_claims) == "$claims2" ]] || fail "a claim reached the API through a proxy that could not ask the scale"
dk exec fake-api rm -f /tmp/scale-fail
echo "RESULT test=proxy phase=unknown idle_runners_refused=yes reached_upstream=0"

# ---------------------------------------------------------------------------------------------
# fresh: an empty state directory is a first start again, and no task runs
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
[[ $state_line == *"no state (a first start)"* && $state_line == *"0 running tasks"* ]] || fail "an empty state directory was not a first start that asked the API: $state_line"
release
wait_for "$TIMEOUT" claimed_both "$fip_def" "$fip_java" || fail "the idle runners present at a first start could not claim"
hold
echo "RESULT test=proxy phase=fresh idle_runners_claimed=yes"

# ---------------------------------------------------------------------------------------------
# lostanswer: the API gets a claim and closes the connection without an answer (the outcome is unknown): fail closed
# ---------------------------------------------------------------------------------------------
hold
dk service update -d --force --update-parallelism 0 "${STACK}_linux-default" > /dev/null
dk service update -d --force --update-parallelism 0 "${STACK}_linux-java" > /dev/null
wait_for "$TIMEOUT" new_containers "$n_def" "$n_java" || fail "the idle runners were not replaced"
oip_def=$(ip_of "$n_def")
oip_java=$(ip_of "$n_java")
wait_for 120 idle "$oip_def" "$oip_java" || fail "the replacement runners do not poll"
# the fake agent prints a TASK line when a runner gets a task: read the logs of the two containers (a service log can hang right after an update)
tasks_in() { count "$(dk logs "$1" 2>&1)" 'TASK '; }
dk exec fake-api touch /tmp/drop   # the API reads a claim and closes the connection
release
unknown_outcome() { [[ $(count "$(plog_now)" "claim from $1 ($2): outcome unknown") -ge 1 ]]; }
unknown_both() { unknown_outcome "$oip_def" tasks.linux-default && unknown_outcome "$oip_java" tasks.linux-java; }
wait_for 90 unknown_both || fail "a claim whose answer was lost did not latch the runners: $(plog_now | grep -aE "claim from ($oip_def|$oip_java)" | tail -n 6 | cut -c1-220)"
dk exec fake-api rm -f /tmp/drop
hold
claims3=$(upstream_claims)
[[ $(claim_code "$n_def") == 403 && $(claim_code "$n_java") == 403 ]] || fail "a runner whose claim had an unknown outcome could claim again"
[[ $(upstream_claims) == "$claims3" ]] || fail "a claim of a latched runner reached the API"
vol grep -q "$oip_def" "$state_dir/state.json" && vol grep -q "$oip_java" "$state_dir/state.json" || fail "the latches of the claims with an unknown outcome were not saved"
sleep 5
[[ $(tasks_in "$n_def") -eq 0 && $(tasks_in "$n_java") -eq 0 ]] || fail "a runner got a task from a claim whose answer was lost"
echo "RESULT test=proxy phase=lostanswer latched=2 saved=yes second_claim=403 reached_upstream=0"
restart_proxy
[[ $state_line == *"state restored"* ]] || fail "the restart after a lost answer did not restore its state: $state_line"
wait_for 30 reachable "$n_def" || fail "the restarted proxy is not reachable from the runner"
wait_for 30 reachable "$n_java" || fail "the restarted proxy is not reachable from the runner"
[[ $(claim_code "$n_def") == 403 && $(claim_code "$n_java") == 403 ]] || fail "a runner whose claim had an unknown outcome could claim after a restart"
echo "RESULT test=proxy phase=lostanswer refused_after_a_restart=yes state=\"$state_line\""

# ---------------------------------------------------------------------------------------------
# limits: one container that floods the proxy is limited on every path, and a runner is not
# ---------------------------------------------------------------------------------------------
# 3000 requests for a pass-through path from the intruder of one class, 60 at a time: the burst is 200 and the rate 50 a second, so most get 429.
# The output is one line per answer: "<count> <status> <Retry-After or ->".
flood() {
  idocker "$mgr" exec -i -u 0 "$i_def" python3 - << 'PY'
import collections, concurrent.futures, http.client

def one(_):
    try:
        c = http.client.HTTPConnection("token-proxy", 8080, timeout=10)
        c.request("GET", "/api/v2/task/config")
        r = c.getresponse()
        r.read()
        c.close()
        return (str(r.status), r.getheader("Retry-After") or "-")
    except Exception as e:
        return ("error", type(e).__name__)

with concurrent.futures.ThreadPoolExecutor(60) as ex:
    n = collections.Counter(ex.map(one, range(3000)))
for (status, retry), k in sorted(n.items()):
    print(k, status, retry)
PY
}
flooded=$(flood)
echo "RESULT test=proxy phase=limits flood=\"$(tr '\n' ';' <<< "$flooded" | tr -s ' ')\""
[[ $(awk '$2 == 429 && $3 == 1 { n += $1 } END { print n + 0 }' <<< "$flooded") -ge 1 ]] || fail "a flood from one address was not limited with 429 and Retry-After: $flooded"
[[ $(awk '$2 == 200 { n += $1 } END { print n + 0 }' <<< "$flooded") -ge 150 ]] || fail "the burst of the per-address limit did not pass: $flooded"
[[ $(count "$(plog_now)" "request from $(ip_of "$i_def") refused: too many requests") -ge 1 && $(count "$(plog_now)" "refused: too many requests") -le 2 ]] || fail "the refusals of the flood are not one log line (and a count): $(count "$(plog_now)" 'refused: too many requests') lines"
sleep 3   # the bucket of the intruder refills
[[ $(probe "$i_java" curl -s -m 5 -o /dev/null -w '%{http_code}' http://token-proxy:8080/healthz || true) == 200 ]] || fail "the proxy does not answer another container after a flood"
[[ $(claim_code "$n_def") == 403 ]] || fail "the proxy does not answer a runner after a flood"

# ---------------------------------------------------------------------------------------------
# summary: one line a minute, and no line for a claim that got no task
# ---------------------------------------------------------------------------------------------
summary_line() { plog_now | grep -a 'summary of the last' | grep -a 'over the per-address limit [1-9]' | tail -n 1 | cut -c1-400; }
have_summary() { [[ -n $(summary_line) ]]; }
wait_for 90 have_summary || fail "no summary line counts the flood: $(plog_now | grep -a 'summary of the last' | tail -n 2)"
line=$(summary_line)
echo "RESULT test=proxy phase=summary line=\"${line#*summary of the last }\""
[[ $line == *"claims forwarded "* && $line == *"latched "* && $line == *"refused "* && $line == *"over capacity 0"* ]] || fail "the summary line lacks a count: $line"
two_summaries() { [[ $(dk logs -t "$(cont token-proxy)" 2>&1 | grep -ac 'summary of the last') -ge 2 ]]; }
wait_for 130 two_summaries || fail "the proxy did not log a second summary line"
stamps=$(dk logs -t "$(cont token-proxy)" 2>&1 | grep -a 'summary of the last' | cut -d' ' -f1 | head -n 2)
gap=$(($(date -d "$(sed -n 2p <<< "$stamps")" +%s) - $(date -d "$(sed -n 1p <<< "$stamps")" +%s)))
[[ $gap -ge 55 && $gap -le 65 ]] || fail "the summary lines are $gap seconds apart, want a minute"
[[ $(count "$(plog)" 'upstream status 204') -eq 0 ]] || fail "the proxy logs claims that got no task"

pass "the proxy runs from its image; runners that start before the proxy are not locked out; two classes claim through one proxy, each with its own token and nowhere else; no class token in a runner container; one claim per container; 403 for non-runners; a restart with state refuses only the runners that claimed; with no state the proxy asks the API how many tasks run: some, or no answer, and every runner present is refused, none and they may claim; a claim whose answer is lost latches the runner; one address that floods the proxy is limited; one summary line a minute"
