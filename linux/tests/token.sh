#!/usr/bin/env bash
# token.sh: can a job read the runner token? Token-free (a sentinel stands in for the token).
#
# Deploys the real linux/stack services linux-default of runners.yaml (MACHINE_RUNNER_SWARM_JOB_SUDO=true) and
# linux-hardened of classes-extra.yaml (MACHINE_RUNNER_SWARM_JOB_SUDO=false) into a single-node Swarm inside DinD, with the REAL
# circleci-runner binary pointed at an unreachable API so it stays up with the sentinel token. The
# token is a Swarm secret, a runner config file owned by the runner (uid 2000, mode 0400); it is in no
# environment variable. The "job" is a probe run with `docker exec -u circleci`: same user, same
# capabilities and the same filesystem as a stepped-down job.
#
# What it proves (and what it reports without asserting):
#   linux-default, job WITHOUT using sudo   secret file, runner environment and own environment: denied
#   linux-default, job WITH sudo            REPORTED. Root (sudo) can read the secret file, so the default
#                                           class cannot protect the token
#   linux-hardened                          denied for a job that does not use sudo
#   linux-hardened, through the step-down   the job runs the way the runner starts it (the entrypoint's setpriv
#                                           prefix, from the runner's own environment): NoNewPrivs is set, so a
#                                           setuid-root binary stays the job user and cannot reach the token, and
#                                           sudo (still configured: the entrypoint edits no file) and su cannot elevate.
#                                           Swarm ignores no-new-privileges; the prefix supplies it. The job sees no
#                                           CIRCLECI_RUNNER_* or MACHINE_RUNNER_SWARM_* variable except the runner name
#   control (no step-down)                  the same setuid-root binary run without the flag DOES reach the token
#   control (root)                          the probe CAN see the sentinel, so "denied" is meaningful
#
# Usage: token.sh
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

session_begin
publish_runner real
create_secrets "$SWARM_TEST_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}" "${EXTRA_SERVICES[@]}"
make_override "$work/ov.yaml" \
  "linux-default 1 CIRCLECI_RUNNER_API_URL=http://127.0.0.1:9" \
  "linux-hardened 1 CIRCLECI_RUNNER_API_URL=http://127.0.0.1:9"
deploy_stack "$SWARM_TEST_MGR" "$work/ov.yaml" runners.yaml classes-extra.yaml   # linux-hardened is in classes-extra.yaml

cexec() { # container user script...
  local c=$1 u=$2
  shift 2
  idocker "$SWARM_TEST_MGR" exec -i -u "$u" "$c" "$@"
}
# shellcheck disable=SC2016  # the single-quoted script runs in the container
runner_pid() { # container
  idocker "$SWARM_TEST_MGR" exec "$1" sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = circleci-runner ] && tr "\0" " " < $p/cmdline | grep -q "circleci-runner machine" && echo ${p#/proc/} && break; done'
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
echo "opt_swarm_writable=$(touch /opt/machine-runner-swarm/x 2>/dev/null && echo yes || echo no)"
if sudo -n true 2>/dev/null; then
  echo "sudo=works"
  echo "sudo_secret_file=$(sees sudo -n cat $secret)"
  echo "sudo_runner_environ_as_root=$(sees sudo -n cat /proc/$RP/environ)"
  # root can become the runner's uid (CAP_SETUID), which the image's sudoers rule "circleci ALL=NOPASSWD: ALL"
  # does not offer through "sudo -u", so use setpriv
  echo "sudo_runner_environ_as_runner_user=$(sees sudo -n setpriv --reuid=circleci-runner --regid=circleci-runner --clear-groups -- cat /proc/$RP/environ)"
else
  echo "sudo=unusable ($(LC_ALL=C sudo -n -l 2>&1 | head -n 1 | cut -c1-90))"
fi
EOF

wait_runner() { # service -> prints container id, sets pid
  local svc=$1 c pid
  wait_for 120 bash -c "docker exec $SWARM_TEST_MGR docker ps -q --filter label=com.docker.swarm.service.name=${STACK}_$svc | grep -q ." || fail "$svc did not start"
  c=$(running_container "$SWARM_TEST_MGR" "$svc")
  wait_for 60 bash -c "[ -n \"\$(docker exec $SWARM_TEST_MGR docker exec $c sh -c 'for p in /proc/[0-9]*; do [ \"\$(cat \$p/comm 2>/dev/null)\" = circleci-runner ] && tr \"\\0\" \" \" < \$p/cmdline | grep -q \"circleci-runner machine\" && echo y; done')\" ]" ||
    fail "the real runner is not running in $svc"
  pid=$(runner_pid "$c")
  echo "$c $pid"
}

kv() { sed -n "s/^$1=//p" <<< "$2"; }

# --- linux-default ---------------------------------------------------------------------------
read -r def_c def_pid <<< "$(wait_runner linux-default)"
def_runner_user=$(idocker "$SWARM_TEST_MGR" exec "$def_c" stat -c %U "/proc/$def_pid")
def_runner_caps=$(idocker "$SWARM_TEST_MGR" exec "$def_c" sh -c "grep CapEff /proc/$def_pid/status | cut -f2")
out_def=$(printf 'RP=%s\nSENTINEL=%s\n%s\n' "$def_pid" "$SENTINEL_TOKEN" "$probe" | cexec "$def_c" circleci sh -s)
control=$(printf 'RP=%s\nSENTINEL=%s\n%s\n' "$def_pid" "$SENTINEL_TOKEN" "$probe" | cexec "$def_c" root sh -s)
echo "RESULT test=token class=linux-default job=circleci runner_user=$def_runner_user runner_cap_eff=$def_runner_caps"
echo "RESULT test=token class=linux-default without_sudo: secret_file=$(kv secret_file "$out_def") runner_environ=$(kv runner_environ "$out_def") own_environment=$(kv own_environment "$out_def") opt_swarm_writable=$(kv opt_swarm_writable "$out_def")"
echo "RESULT test=token class=linux-default with_sudo: sudo=$(kv sudo "$out_def") secret_file=$(kv sudo_secret_file "$out_def") runner_environ_as_root=$(kv sudo_runner_environ_as_root "$out_def") runner_environ_as_runner_user=$(kv sudo_runner_environ_as_runner_user "$out_def") (the token is in no environment variable)"
echo "RESULT test=token control user=root secret_file=$(kv secret_file "$control") runner_environ=$(kv runner_environ "$control")"

# --- linux-hardened --------------------------------------------------------------------------
read -r hard_c hard_pid <<< "$(wait_runner linux-hardened)"
hard_runner_user=$(idocker "$SWARM_TEST_MGR" exec "$hard_c" stat -c %U "/proc/$hard_pid")
out_hard=$(printf 'RP=%s\nSENTINEL=%s\n%s\n' "$hard_pid" "$SENTINEL_TOKEN" "$probe" | cexec "$hard_c" circleci sh -s)
# The entrypoint edits no sudo file: the image's rule for the job user is still there, and no-new-privs is what makes it useless.
hard_sudoers=$(idocker "$SWARM_TEST_MGR" exec "$hard_c" sh -c 'LC_ALL=C sudo -n -l -U circleci 2>&1' | tr '\n' ' ')
echo "RESULT test=token class=linux-hardened job=circleci runner_user=$hard_runner_user"
echo "RESULT test=token class=linux-hardened: secret_file=$(kv secret_file "$out_hard") runner_environ=$(kv runner_environ "$out_hard") own_environment=$(kv own_environment "$out_hard") opt_swarm_writable=$(kv opt_swarm_writable "$out_hard") (a plain docker exec has no no-new-privs flag: sudo=$(kv sudo "$out_hard"), see the step-down below)"
echo "       sudo -l -U circleci: $hard_sudoers"

# --- linux-hardened: setuid binaries ---------------------------------------------------------
# Swarm ignores no-new-privileges, and the hardened class keeps SETUID and SETGID in its bounding set for the
# step-down, so a setuid-root binary would otherwise lift a job to root and reach the secret (root cannot read it
# directly without CAP_DAC_OVERRIDE, but can become uid 2000). The entrypoint therefore steps jobs down with
# setpriv --no-new-privs, even though the image has sudo. A setuid-root copy of setpriv stands in for a vulnerable binary:
# it reports its effective uid (--dump) and can switch to the runner's uid.
# shellcheck disable=SC2016  # the single-quoted script runs in the container
idocker "$SWARM_TEST_MGR" exec "$hard_c" sh -c 'cp "$(command -v setpriv)" /tmp/suid-setpriv && chown 0:0 /tmp/suid-setpriv && chmod 4755 /tmp/suid-setpriv'
# The runner's environment is readable only by a process that is the runner user and holds the runner's capabilities
# (the ambient SETUID and SETGID of the step-down), so read it the way the entrypoint starts the runner.
# shellcheck disable=SC2016  # the single-quoted script runs in the container
prefix_words=$(idocker "$SWARM_TEST_MGR" exec "$hard_c" setpriv --reuid=2000 --regid=2000 --clear-groups --inh-caps=+setuid,+setgid --ambient-caps=+setuid,+setgid -- sh -c 'tr "\0" "\n" < /proc/'"$hard_pid"'/environ | sed -n "s/^CIRCLECI_RUNNER_COMMAND_PREFIX=//p"' |
  sed -e 's/^\[//' -e 's/\]$//' -e 's/"//g' -e 's/,/ /g')
[[ $prefix_words == "setpriv "* && $prefix_words == *"--no-new-privs"* ]] || fail "linux-hardened: the step-down prefix is not setpriv --no-new-privs ($prefix_words)"
read -r -d '' suid_probe <<'EOF' || true
secret=/run/secrets/circleci_runner_config.yaml
sees() { if "$@" 2>/dev/null | tr '\0' '\n' | grep -q "$SENTINEL"; then echo READABLE; else echo denied; fi; }
echo "whoami=$(id -un)"
echo "uid=$(id -u)"
echo "no_new_privs=$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/self/status)"
echo "cap_eff=$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status)"
echo "settings=$(env | cut -d= -f1 | grep -E '^(CIRCLECI_RUNNER|MACHINE_RUNNER_SWARM)_' | grep -vx CIRCLECI_RUNNER_NAME | tr '\n' ' ')"
echo "suid_euid=$(/tmp/suid-setpriv --dump | sed -n 's/^euid:[[:space:]]*//p')"
echo "suid_secret_file=$(sees /tmp/suid-setpriv --reuid=2000 --regid=2000 --clear-groups -- cat $secret)"
echo "secret_file=$(sees cat $secret)"
if sudo -n true </dev/null 2>/dev/null; then echo "sudo=works"; else echo "sudo=unusable"; fi
if su -c true root </dev/null 2>/dev/null; then echo "su=works"; else echo "su=unusable"; fi
echo "setuid_binaries=$(find /usr/bin /bin /usr/sbin /sbin -xdev -perm -4000 -type f 2>/dev/null | wc -l)"
EOF
# As the runner starts a job: the runner user (uid 2000, ambient setuid and setgid) runs the prefix, which steps down to the job user.
# shellcheck disable=SC2086  # the prefix is a list of words
out_nnp=$(printf 'SENTINEL=%s\n%s\n' "$SENTINEL_TOKEN" "$suid_probe" | idocker "$SWARM_TEST_MGR" exec -i -u root "$hard_c" setpriv --reuid=2000 --regid=2000 --clear-groups \
  --inh-caps=+setuid,+setgid --ambient-caps=+setuid,+setgid -- $prefix_words sh -s)
# Without the step-down (docker exec -u circleci: no no-new-privs flag): what a setuid-root bug would give.
out_nonnp=$(printf 'SENTINEL=%s\n%s\n' "$SENTINEL_TOKEN" "$suid_probe" | cexec "$hard_c" circleci sh -s)
echo "RESULT test=token class=linux-hardened through_step_down: user=$(kv whoami "$out_nnp") no_new_privs=$(kv no_new_privs "$out_nnp") cap_eff=$(kv cap_eff "$out_nnp") suid_euid=$(kv suid_euid "$out_nnp") suid_secret_file=$(kv suid_secret_file "$out_nnp") secret_file=$(kv secret_file "$out_nnp") sudo=$(kv sudo "$out_nnp") su=$(kv su "$out_nnp") setuid_binaries_in_image=$(kv setuid_binaries "$out_nnp") settings_in_the_job_env=\"$(kv settings "$out_nnp")\""
echo "RESULT test=token class=linux-hardened control_without_no_new_privs: no_new_privs=$(kv no_new_privs "$out_nonnp") suid_euid=$(kv suid_euid "$out_nonnp") suid_secret_file=$(kv suid_secret_file "$out_nonnp") (what a setuid-root bug would reach without the flag)"

# --- assertions ------------------------------------------------------------------------------
[[ $def_runner_user == circleci-runner && $hard_runner_user == circleci-runner ]] || fail "the runner does not run as circleci-runner"
[[ $def_runner_caps == 0000000000000000 ]] || fail "the runner process holds capabilities ($def_runner_caps)"
[[ $(kv secret_file "$control") == READABLE ]] || fail "the control (root) cannot read the secret file: the probe is blind"
[[ $(kv secret_file "$out_def") == denied && $(kv runner_environ "$out_def") == denied && $(kv own_environment "$out_def") == denied ]] ||
  fail "linux-default: a job that does not use sudo can reach the token"
[[ $(kv opt_swarm_writable "$out_def") == no && $(kv opt_swarm_writable "$out_hard") == no ]] || fail "a job can write /opt/machine-runner-swarm"
[[ $(kv secret_file "$out_hard") == denied && $(kv runner_environ "$out_hard") == denied && $(kv own_environment "$out_hard") == denied ]] ||
  fail "linux-hardened: a job can reach the token"
[[ $hard_sudoers == *"NOPASSWD: ALL"* ]] || fail "linux-hardened: the sudo rule of the job user was removed, but no-new-privs is meant to be the mechanism ($hard_sudoers)"
[[ $(kv sudo "$out_def") == works ]] || fail "linux-default: the job user has no sudo (expected passwordless sudo by default)"

[[ $(kv no_new_privs "$out_nnp") == 1 && $(kv cap_eff "$out_nnp") == 0000000000000000 ]] || fail "linux-hardened: the job does not run with no-new-privs and no capabilities"
[[ $(kv whoami "$out_nnp") == "$(kv whoami "$out_hard")" && $(kv uid "$out_nnp") != 0 && $(kv suid_euid "$out_nnp") == "$(kv uid "$out_nnp")" ]] ||
  fail "linux-hardened: a setuid-root binary run by the job user became root"
[[ $(kv suid_secret_file "$out_nnp") == denied && $(kv secret_file "$out_nnp") == denied ]] || fail "linux-hardened: a setuid binary reached the token"
[[ $(kv sudo "$out_nnp") == unusable && $(kv su "$out_nnp") == unusable ]] || fail "linux-hardened: sudo or su works for the job user"
[[ -z $(kv settings "$out_nnp") ]] || fail "linux-hardened: runner or stack settings reach the job ($(kv settings "$out_nnp"))"
[[ $(kv no_new_privs "$out_nonnp") == 0 && $(kv suid_euid "$out_nonnp") == 0 && $(kv suid_secret_file "$out_nonnp") == READABLE ]] ||
  fail "the setuid control did not reach the token without the flag: the probe is blind"

if [[ $(kv sudo_secret_file "$out_def") == READABLE ]]; then
  finding="a job that uses sudo CAN read the token in the default class (secret file via sudo: READABLE); only MACHINE_RUNNER_SWARM_JOB_SUDO=false protects it"
else
  finding="UNEXPECTED: sudo did not expose the token in the default class; update the docs"
fi
pass "no sudo: denied; hardened: denied, and under no-new-privs sudo and su are unusable and a setuid-root binary stays the job user (control without the flag reaches the token), with no runner or stack setting in the job; finding: $finding"
