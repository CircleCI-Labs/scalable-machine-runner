#!/usr/bin/env bash
# placement.sh: constraints keep a service where it belongs, and capability labels move it. Token-free.
#
# Two nodes, both inside DinD containers: a Swarm manager and a worker. The real linux/stack/runners.yaml
# plus docker-build.yaml are deployed with the REAL runner binary (pointed at an unreachable API so it stays up). Checks:
#   1. linux-docker-build (constraint: node.labels.machine-runner-swarm.docker-build == true, node.role == worker)
#      stays PENDING while no node has the label, with Swarm's "no suitable node" reason
#   2. the label on the MANAGER alone does not place it (the role constraint): still pending
#   3. the label on the WORKER places it there, and the job user can use the bound Docker socket
#      without sudo (pattern A) through the group the entrypoint adds
#   4. linux-default (placement preference spread: node.id) puts its two replicas on different nodes
#
# Usage: placement.sh        Env: TIMEOUT=120
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TIMEOUT=${TIMEOUT:-120}

DIAG_NODES=""
session_begin --worker
DIAG_NODES=$SWARM_TEST_MGR
install_swarm "$SWARM_TEST_MGR" real
install_swarm "$SWARM_TEST_WRK" real
create_secrets "$SWARM_TEST_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}" linux-docker-build
api="CIRCLECI_RUNNER_API_URL=http://127.0.0.1:9"
make_override "$work/ov.yaml" "linux-default 2 $api" "linux-docker-build 1 $api"
deploy_stack "$SWARM_TEST_MGR" "$work/ov.yaml" runners.yaml docker-build.yaml

ps_line() { # service -> "node|state|error" of the current task
  idocker "$SWARM_TEST_MGR" service ps --no-trunc --filter desired-state=running --format '{{.Node}}|{{.CurrentState}}|{{.Error}}' "${STACK}_$1" | head -n 1
}
state_of() { ps_line "$1" | cut -d'|' -f2; }
# shellcheck disable=SC2329  # called through wait_for
running_on() { # service node
  [[ $(ps_line "$1") == "$2|Running"* ]]
}

# 1. no node has the label
wait_for "$TIMEOUT" bash -c "docker exec $SWARM_TEST_MGR docker service ps --no-trunc --filter desired-state=running --format '{{.CurrentState}}|{{.Error}}' ${STACK}_linux-docker-build | head -n 1 | grep -q '^Pending.*no suitable node'" ||
  fail "linux-docker-build did not go pending with 'no suitable node'"
reason=$(ps_line linux-docker-build | cut -d'|' -f3)
containers=$(idocker "$SWARM_TEST_MGR" ps -q --filter "label=com.docker.swarm.service.name=${STACK}_linux-docker-build" | wc -l)
containers=$((containers + $(idocker "$SWARM_TEST_WRK" ps -q --filter "label=com.docker.swarm.service.name=${STACK}_linux-docker-build" | wc -l)))
echo "RESULT test=placement step=no_label state=Pending containers=$containers reason=\"$(tr -d '"' <<< "$reason" | cut -c1-130)\""
[[ $containers -eq 0 ]] || fail "linux-docker-build started on a node without the label"

# 4. spread (checked while we wait)
wait_for "$TIMEOUT" bash -c "[ \$(docker exec $SWARM_TEST_MGR docker service ps --filter desired-state=running --format '{{.CurrentState}}' ${STACK}_linux-default | grep -c '^Running') -eq 2 ]" ||
  fail "the two linux-default replicas did not start"
nodes=$(idocker "$SWARM_TEST_MGR" service ps --filter desired-state=running --format '{{.Node}}' "${STACK}_linux-default" | sort -u | paste -sd, -)
echo "RESULT test=placement step=spread service=linux-default nodes=$nodes"
[[ $nodes == "$SWARM_TEST_MGR,$SWARM_TEST_WRK" || $nodes == "$SWARM_TEST_WRK,$SWARM_TEST_MGR" ]] || fail "replicas were not spread over both nodes: $nodes"

# 2. label on the manager only
idocker "$SWARM_TEST_MGR" node update --label-add machine-runner-swarm.docker-build=true "$SWARM_TEST_MGR" >/dev/null
sleep 15
state=$(state_of linux-docker-build)
echo "RESULT test=placement step=label_on_manager_only state=${state%% *} (node.role == worker is not met)"
[[ $state == Pending* ]] || fail "the label on a manager placed linux-docker-build ($state)"

# 3. label on the worker
idocker "$SWARM_TEST_MGR" node update --label-add machine-runner-swarm.docker-build=true "$SWARM_TEST_WRK" >/dev/null
wait_for "$TIMEOUT" running_on linux-docker-build "$SWARM_TEST_WRK" || fail "linux-docker-build did not start on the labelled worker"
echo "RESULT test=placement step=label_on_worker state=Running node=$SWARM_TEST_WRK"
c=$(idocker "$SWARM_TEST_WRK" ps -q --filter "label=com.docker.swarm.service.name=${STACK}_linux-docker-build" | head -n 1)
wait_for 60 bash -c "docker exec $SWARM_TEST_WRK docker exec $c sh -c 'for p in /proc/[0-9]*; do [ \"\$(cat \$p/comm 2>/dev/null)\" = circleci-runner ] && exit 0; done; exit 1'" ||
  fail "the runner did not start in linux-docker-build"
as_job=$(idocker "$SWARM_TEST_WRK" exec -u circleci "$c" sh -c 'docker version --format "{{.Server.Version}}" 2>&1; id -Gn' | tr '\n' ' ')
sudo_used=$(idocker "$SWARM_TEST_WRK" exec -u circleci "$c" sh -c 'docker ps >/dev/null 2>&1 && echo yes || echo no')
echo "RESULT test=placement step=pattern_a job_user=circleci docker_without_sudo=$sudo_used detail=\"${as_job% }\""
[[ $sudo_used == yes ]] || fail "the job user cannot use the bound Docker socket without sudo"

pass "constraints and labels place services (pending on a mismatch, the role constraint holds, spread works, socket group for pattern A)"
