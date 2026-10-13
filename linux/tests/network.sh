#!/usr/bin/env bash
# network.sh: what Swarm can and cannot isolate. Token-free. This backs the comments in
# linux/stack/runners.yaml and the docs, and fails when Docker's behaviour changes.
#
#   1. replicas of ONE class can reach each other (Swarm has no way to stop that: see part 3)
#   2. different classes are on different overlay networks and cannot reach each other
#   3. a swarm-scoped bridge network created with enable_icc=false does NOT isolate its replicas
#      (the option is dropped for swarm scope), and a stack cannot use a local bridge
#
# The probe servers are plain `python3 -m http.server` processes that the fake runner execs
# (FAKE_RUNNER_SERVE=1) as circleci-runner, after all the real entrypoint's user and sudo setup.
#
# Usage: network.sh
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

session_begin
install_swarm "$SWARM_TEST_MGR" fake
create_secrets "$SWARM_TEST_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}"
make_override "$work/ov.yaml" "linux-default 2 FAKE_RUNNER_SERVE=1" "linux-hardened 1 FAKE_RUNNER_SERVE=1"
deploy_stack "$SWARM_TEST_MGR" "$work/ov.yaml"

containers_of() { idocker "$SWARM_TEST_MGR" ps -q --filter "label=com.docker.swarm.service.name=${STACK}_$1"; }
ip_of() { idocker "$SWARM_TEST_MGR" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" | awk '{ print $1 }'; }
reach() { # from-container ip -> reachable|unreachable
  if idocker "$SWARM_TEST_MGR" exec "$1" bash -c "timeout 3 bash -c '</dev/tcp/$2/8000'" >/dev/null 2>&1; then echo reachable; else echo unreachable; fi
}
wait_for 120 bash -c "[ \$(docker exec $SWARM_TEST_MGR docker ps -q --filter label=com.docker.swarm.service.name=${STACK}_linux-default | wc -l) -eq 2 ] && [ \$(docker exec $SWARM_TEST_MGR docker ps -q --filter label=com.docker.swarm.service.name=${STACK}_linux-hardened | wc -l) -eq 1 ]" ||
  fail "the replicas did not start"
sleep 5   # let the servers bind
mapfile -t defaults < <(containers_of linux-default)
hardened=$(containers_of linux-hardened)
same=$(reach "${defaults[0]}" "$(ip_of "${defaults[1]}")")
cross=$(reach "${defaults[0]}" "$(ip_of "$hardened")")
echo "RESULT test=network part=stack same_class_peer=$same other_class=$cross"
[[ $same == reachable ]] || fail "replicas of one class cannot reach each other: the documented limitation changed, update runners.yaml and the docs"
[[ $cross == unreachable ]] || fail "a replica can reach another class: the per-class overlay networks do not isolate"

# --- part 3: the enable_icc option on a swarm-scoped bridge ----------------------------------
idocker "$SWARM_TEST_MGR" network create -d bridge --scope swarm -o com.docker.network.bridge.enable_icc=false swarm-icc-off >/dev/null
idocker "$SWARM_TEST_MGR" service create -d --name icc-off --replicas 2 --network swarm-icc-off --entrypoint python3 "$CIMG_IMAGE" -m http.server 8000 >/dev/null
wait_for 90 bash -c "[ \$(docker exec $SWARM_TEST_MGR docker ps -q --filter label=com.docker.swarm.service.name=icc-off | wc -l) -eq 2 ]" || fail "the icc-off replicas did not start"
sleep 5
mapfile -t icc < <(idocker "$SWARM_TEST_MGR" ps -q --filter label=com.docker.swarm.service.name=icc-off)
peer=$(reach "${icc[0]}" "$(ip_of "${icc[1]}")")
options=$(idocker "$SWARM_TEST_MGR" network inspect swarm-icc-off -f '{{json .Options}}')
echo "RESULT test=network part=bridge-enable_icc=false peer=$peer network_options=$options"
[[ $peer == reachable ]] || fail "enable_icc=false now isolates swarm-scoped replicas: adopt it in runners.yaml"
# a stack cannot create such a network itself: bridge networks from a stack are node-local
printf 'services:\n  a:\n    image: %s\n    networks: [iso]\nnetworks:\n  iso:\n    driver: bridge\n' "$CIMG_IMAGE" > "$work/bridge.yaml"
docker cp "$work/bridge.yaml" "$SWARM_TEST_MGR:/bridge.yaml"
if idocker "$SWARM_TEST_MGR" stack deploy --resolve-image never -c /bridge.yaml bridgetest >/dev/null 2>&1; then
  idocker "$SWARM_TEST_MGR" stack rm bridgetest >/dev/null 2>&1 || true
  fail "a stack can now use a bridge network: revisit replica isolation"
fi
echo "RESULT test=network part=stack-bridge refused=yes"
idocker "$SWARM_TEST_MGR" stack rm bridgetest >/dev/null 2>&1 || true

pass "replicas of a class share a network (Swarm cannot stop that); classes are isolated from each other; enable_icc=false is ignored on swarm scope"
