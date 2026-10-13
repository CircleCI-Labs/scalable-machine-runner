#!/usr/bin/env bash
# token.sh: can a job read the runner token? Token-free (a sentinel stands in for the token).
#
# Deploys the real linux/stack/runners.yaml services linux-default (SMR_JOB_SUDO=true) and
# linux-hardened (SMR_JOB_SUDO=false) into a single-node Swarm inside DinD, with the REAL
# circleci-runner binary pointed at an unreachable API so it stays up with the sentinel token. The
# token is a Swarm secret, a runner config file owned by the runner (uid 2000, mode 0400); it is in no
# environment variable. The "job" is a probe run with `docker exec -u circleci`: same user, same
# capabilities and the same filesystem as a stepped-down job.
#
# What it proves (and what it reports without asserting):
#   linux-default, job WITHOUT using sudo   secret file, runner environment and own environment: denied
#   linux-default, job WITH sudo            REPORTED. Root (sudo) can read the secret file, so the default
#                                           class cannot protect the token
#   linux-hardened                          denied everywhere, and sudo itself is unusable
#   control (root)                          the probe CAN see the sentinel, so "denied" is meaningful
#
# Usage: token.sh
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

session_begin
install_smr "$SMR_MGR" real
create_secrets "$SMR_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}"
make_override "$work/ov.yaml" \
  "linux-default 1 CIRCLECI_RUNNER_API_URL=http://127.0.0.1:9" \
  "linux-hardened 1 CIRCLECI_RUNNER_API_URL=http://127.0.0.1:9"
deploy_stack "$SMR_MGR" "$work/ov.yaml"

cexec() { # container user script...
  local c=$1 u=$2
  shift 2
  idocker "$SMR_MGR" exec -i -u "$u" "$c" "$@"
}
# shellcheck disable=SC2016  # the single-quoted script runs in the container
runner_pid() { # container
  idocker "$SMR_MGR" exec "$1" sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = circleci-runner ] && echo ${p#/proc/} && break; done'
}

# Prints key=value lines. $RP is the runner's pid; $SENTINEL is a shell variable, deliberately not
# exported, so the probe's own environment stays clean.
read -r -d '' probe <<'EOF' || true
secret=/run/secrets/circleci_runner_config.yaml
sees() { if "$@" 2>/dev/null | tr '\0' '\n' | grep -q "$SENTINEL"; then echo READABLE; else echo denied; fi; }
echo "whoami=$(id -un)"
echo "secret_file=$(sees cat $secret)"
echo "runner_environ=$(sees cat /proc/$RP/environ)"
echo "own_environment=$(sees env)"
echo "opt_smr_writable=$(touch /opt/smr/bin/x 2>/dev/null && echo yes || echo no)"
if sudo -n true 2>/dev/null; then
  echo "sudo=works"
  echo "sudo_secret_file=$(sees sudo -n cat $secret)"
  echo "sudo_runner_environ_as_root=$(sees sudo -n cat /proc/$RP/environ)"
  # root can become the runner's uid (CAP_SETUID), which the image's sudoers rule "circleci ALL=NOPASSWD: ALL"
  # does not offer through "sudo -u", so use setpriv
  echo "sudo_runner_environ_as_runner_user=$(sees sudo -n setpriv --reuid=smr-runner --regid=smr-runner --clear-groups -- cat /proc/$RP/environ)"
else
  echo "sudo=unusable ($(LC_ALL=C sudo -n -l 2>&1 | head -n 1 | cut -c1-90))"
fi
EOF

wait_runner() { # service -> prints container id, sets pid
  local svc=$1 c pid
  wait_for 120 bash -c "docker exec $SMR_MGR docker ps -q --filter label=com.docker.swarm.service.name=${STACK}_$svc | grep -q ." || fail "$svc did not start"
  c=$(running_container "$SMR_MGR" "$svc")
  wait_for 60 bash -c "[ -n \"\$(docker exec $SMR_MGR docker exec $c sh -c 'for p in /proc/[0-9]*; do [ \"\$(cat \$p/comm 2>/dev/null)\" = circleci-runner ] && echo y; done')\" ]" ||
    fail "the real runner is not running in $svc"
  pid=$(runner_pid "$c")
  echo "$c $pid"
}

kv() { sed -n "s/^$1=//p" <<< "$2"; }

# --- linux-default ---------------------------------------------------------------------------
read -r def_c def_pid <<< "$(wait_runner linux-default)"
def_runner_user=$(idocker "$SMR_MGR" exec "$def_c" stat -c %U "/proc/$def_pid")
def_runner_caps=$(idocker "$SMR_MGR" exec "$def_c" sh -c "grep CapEff /proc/$def_pid/status | cut -f2")
out_def=$(printf 'RP=%s\nSENTINEL=%s\n%s\n' "$def_pid" "$SENTINEL_TOKEN" "$probe" | cexec "$def_c" circleci sh -s)
control=$(printf 'RP=%s\nSENTINEL=%s\n%s\n' "$def_pid" "$SENTINEL_TOKEN" "$probe" | cexec "$def_c" root sh -s)
echo "RESULT test=token class=linux-default job=circleci runner_user=$def_runner_user runner_cap_eff=$def_runner_caps"
echo "RESULT test=token class=linux-default without_sudo: secret_file=$(kv secret_file "$out_def") runner_environ=$(kv runner_environ "$out_def") own_environment=$(kv own_environment "$out_def") opt_smr_writable=$(kv opt_smr_writable "$out_def")"
echo "RESULT test=token class=linux-default with_sudo: sudo=$(kv sudo "$out_def") secret_file=$(kv sudo_secret_file "$out_def") runner_environ_as_root=$(kv sudo_runner_environ_as_root "$out_def") runner_environ_as_runner_user=$(kv sudo_runner_environ_as_runner_user "$out_def") (the token is in no environment variable)"
echo "RESULT test=token control user=root secret_file=$(kv secret_file "$control") runner_environ=$(kv runner_environ "$control")"

# --- linux-hardened --------------------------------------------------------------------------
read -r hard_c hard_pid <<< "$(wait_runner linux-hardened)"
hard_runner_user=$(idocker "$SMR_MGR" exec "$hard_c" stat -c %U "/proc/$hard_pid")
out_hard=$(printf 'RP=%s\nSENTINEL=%s\n%s\n' "$hard_pid" "$SENTINEL_TOKEN" "$probe" | cexec "$hard_c" circleci sh -s)
hard_hostmsg=$(idocker "$SMR_MGR" exec "$hard_c" sh -c 'LC_ALL=C sudo -n -l -U circleci 2>&1 | head -n 1')
echo "RESULT test=token class=linux-hardened job=circleci runner_user=$hard_runner_user"
echo "RESULT test=token class=linux-hardened: secret_file=$(kv secret_file "$out_hard") runner_environ=$(kv runner_environ "$out_hard") own_environment=$(kv own_environment "$out_hard") sudo=$(kv sudo "$out_hard") opt_smr_writable=$(kv opt_smr_writable "$out_hard")"
echo "       sudo -l -U circleci: $hard_hostmsg"

# --- assertions ------------------------------------------------------------------------------
[[ $def_runner_user == smr-runner && $hard_runner_user == smr-runner ]] || fail "the runner does not run as smr-runner"
[[ $def_runner_caps == 0000000000000000 ]] || fail "the runner process holds capabilities ($def_runner_caps)"
[[ $(kv secret_file "$control") == READABLE ]] || fail "the control (root) cannot read the secret file: the probe is blind"
[[ $(kv secret_file "$out_def") == denied && $(kv runner_environ "$out_def") == denied && $(kv own_environment "$out_def") == denied ]] ||
  fail "linux-default: a job that does not use sudo can reach the token"
[[ $(kv opt_smr_writable "$out_def") == no && $(kv opt_smr_writable "$out_hard") == no ]] || fail "a job can write /opt/smr"
[[ $(kv secret_file "$out_hard") == denied && $(kv runner_environ "$out_hard") == denied && $(kv own_environment "$out_hard") == denied ]] ||
  fail "linux-hardened: a job can reach the token"
[[ $(kv sudo "$out_hard") == unusable* && $hard_hostmsg == *"not allowed to run sudo"* ]] || fail "linux-hardened: the job user can still use sudo"
[[ $(kv sudo "$out_def") == works ]] || fail "linux-default: the job user has no sudo (expected passwordless sudo by default)"

if [[ $(kv sudo_secret_file "$out_def") == READABLE ]]; then
  finding="a job that uses sudo CAN read the token in the default class (secret file via sudo: READABLE); only SMR_JOB_SUDO=false protects it"
else
  finding="UNEXPECTED: sudo did not expose the token in the default class; update the docs"
fi
pass "no sudo: denied; hardened: denied and sudo unusable; finding: $finding"
