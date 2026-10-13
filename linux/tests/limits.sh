#!/usr/bin/env bash
# limits.sh: the hardening knobs of linux/stack/runners.yaml actually take effect in Swarm. Token-free.
# Deploys the real stack (fake runner, continuous, idle) and inspects the running containers:
#   init: true (PID 1 is docker-init), ulimits (nofile 65536, core 0), pids limit 4096, memory and cpu
#   limits, the read-only /opt/smr bind, the `local` log driver, the container hostname, the capability
#   bounding set (default classes lose NET_RAW and MKNOD; the hardened class keeps exactly CHOWN, FOWNER, KILL,
#   SETGID, SETUID and AUDIT_WRITE), and resource RESERVATIONS: more replicas than the node can reserve stay Pending.
#
# Usage: limits.sh
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

session_begin
install_smr "$SMR_MGR" fake
create_secrets "$SMR_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}"
cpus=$(($(idocker "$SMR_MGR" node inspect self --format '{{.Description.Resources.NanoCPUs}}') / 1000000000))
# Every replica reserves 2 CPUs. Leave room for the one linux-hardened replica; ask for 2 more
# linux-default replicas than fit, and those two must stay Pending.
[[ $cpus -ge 4 ]] || { echo "SKIP: needs a node with at least 4 CPUs (this one has $cpus)"; exit 0; }
fit=$((cpus / 2 - 1))
replicas=$((fit + 2))
make_override "$work/ov.yaml" "linux-default 1 CIRCLECI_RUNNER_MODE=continuous FAKE_JOB_INTERVAL=300" "linux-hardened 1 CIRCLECI_RUNNER_MODE=continuous FAKE_JOB_INTERVAL=300"
deploy_stack "$SMR_MGR" "$work/ov.yaml"

running() { idocker "$SMR_MGR" service ps --filter desired-state=running --format '{{.CurrentState}}' "${STACK}_$1" | grep -c '^Running' || true; }
wait_for 180 bash -c "[ \$(docker exec $SMR_MGR docker service ps --filter desired-state=running --format '{{.CurrentState}}' ${STACK}_linux-hardened | grep -c '^Running') -ge 1 ]" ||
  fail "linux-hardened did not start"
# the hardened replica holds its reservation; now ask for more linux-default replicas than fit
idocker "$SMR_MGR" service scale -d "${STACK}_linux-default=$replicas" >/dev/null
wait_for 180 bash -c "[ \$(docker exec $SMR_MGR docker service ps --filter desired-state=running --format '{{.CurrentState}}' ${STACK}_linux-default | grep -c '^Running') -ge $fit ]" ||
  fail "$fit linux-default replicas did not start"
sleep 8
run_n=$(running linux-default)
pend_n=$(idocker "$SMR_MGR" service ps --no-trunc --filter desired-state=running --format '{{.CurrentState}}|{{.Error}}' "${STACK}_linux-default" | grep -c '^Pending.*insufficient resources' || true)
echo "RESULT test=limits step=reservations node_cpus=$cpus replicas_wanted=$replicas running=$run_n pending_insufficient_resources=$pend_n"
[[ $run_n -eq $fit && $pend_n -eq 2 ]] || fail "reservations: expected $fit running and 2 pending for insufficient resources"

c=$(running_container "$SMR_MGR" linux-default)
h=$(running_container "$SMR_MGR" linux-hardened)
cin() { idocker "$SMR_MGR" exec "$@"; }
pid1=$(cin "$c" cat /proc/1/comm)
nofile=$(cin -u circleci "$c" sh -c 'ulimit -n')
core=$(cin -u circleci "$c" sh -c 'ulimit -c')
pids=$(cin "$c" cat /sys/fs/cgroup/pids.max)
mem=$(cin "$c" cat /sys/fs/cgroup/memory.max)
cpu=$(cin "$c" cat /sys/fs/cgroup/cpu.max)
host=$(cin "$c" hostname)
logdrv=$(idocker "$SMR_MGR" inspect -f '{{.HostConfig.LogConfig.Type}}' "$c")
optsmr=$(cin "$c" sh -c 'touch /opt/smr/x 2>/dev/null && echo writable || echo read-only')
bnd_default=$(cin "$c" sh -c "grep CapBnd /proc/1/status | cut -f2")
bnd_hard=$(cin "$h" sh -c "grep CapBnd /proc/1/status | cut -f2")
echo "RESULT test=limits step=effective pid1=$pid1 nofile=$nofile core=$core pids=$pids memory=$mem cpu=\"$cpu\" hostname=$host log_driver=$logdrv opt_smr=$optsmr"
echo "RESULT test=limits step=capabilities default_bounding=$bnd_default hardened_bounding=$bnd_hard"
[[ $pid1 == docker-init || $pid1 == tini ]] || fail "init: true is not in effect (PID 1 is $pid1)"
[[ $nofile == 65536 && $core == 0 ]] || fail "ulimits are not in effect (nofile=$nofile core=$core)"
[[ $pids == 4096 && $mem == 4294967296 && $cpu == "200000 100000" ]] || fail "resource limits are not in effect"
[[ $host == *-linux-default-* ]] || fail "unexpected container hostname $host"
[[ $logdrv == local && $optsmr == read-only ]] || fail "log driver or the /opt/smr mount is wrong"
b=$((16#$bnd_default))
[[ $((b & (1 << 13))) -eq 0 && $((b & (1 << 27))) -eq 0 ]] || fail "NET_RAW or MKNOD is still in the default class's capability set"
[[ $((16#$bnd_hard)) -eq $((16#200000e9)) ]] || fail "the hardened class's capability set is not the documented one ($bnd_hard)"

pass "init, ulimits, pids/memory/cpu limits, reservations, read-only /opt/smr, local logs, hostnames and capability sets take effect"
