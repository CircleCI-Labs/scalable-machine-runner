#!/usr/bin/env bats
# Unit tests for linux/entrypoint/circleci-runner-entrypoint. Run them with linux/tests/bats/run.sh, which
# executes the suite as root inside stock images (cimg/base, Alpine, UBI minimal) so that every
# image's /bin/sh (dash, BusyBox ash, bash) and its useradd/adduser/sudo/setpriv are exercised.
#
# A stub replaces circleci-runner. It prints its arguments, who it runs as and whether it can read
# the config secret; with STUB_JOB=1 it also runs a probe through CIRCLECI_RUNNER_COMMAND_PREFIX the
# way the real runner runs the task agent. Every test starts from the image's original /etc.
# shellcheck disable=SC2030,SC2031,SC2154  # each @test runs in its own subshell; bats sets BATS_*

ENTRYPOINT_SRC=${SWARM_TEST_ENTRYPOINT_SRC:-/src/linux/entrypoint/circleci-runner-entrypoint}
ENTRYPOINT=/opt/machine-runner-swarm/bin/circleci-runner-entrypoint
STUB=/opt/machine-runner-swarm/bin/circleci-runner
SNAP=/tmp/swarm-etc-snapshot
CONFIG=/run/secrets/circleci_runner_config.yaml

setup_file() {
  cd /
  rm -rf "$SNAP"
  mkdir -p "$SNAP"
  for f in passwd group shadow gshadow sudoers; do
    if [ -e "/etc/$f" ]; then cp -p "/etc/$f" "$SNAP/$f"; fi
  done
  if [ -d /etc/sudoers.d ]; then cp -a /etc/sudoers.d "$SNAP/sudoers.d"; fi
  cp -a /home "$SNAP/home"
}

setup() {
  cd /
  restore_etc
  while read -r v; do unset "$v"; done < <(env | grep -oE '^(CIRCLECI_RUNNER_[A-Z_]*|MACHINE_RUNNER_SWARM_[A-Z_]*|STUB_[A-Z_]*)=' | tr -d =)
  rm -rf /opt/machine-runner-swarm /var/lib/circleci-runner /var/opt/circleci /run/secrets /tmp/swarm-test
  install -d -m 0755 -o 0 -g 0 /opt/machine-runner-swarm /opt/machine-runner-swarm/bin /run/secrets
  install -m 0755 -o 0 -g 0 "$ENTRYPOINT_SRC" "$ENTRYPOINT"
  # as in Swarm: the config secret belongs to the runner's uid 2000, mode 0400
  printf 'api:\n  auth_token: tok-from-secret\n' > "$CONFIG"
  chown 2000:2000 "$CONFIG"
  chmod 0400 "$CONFIG"
  cat > "$STUB" <<'EOF'
#!/bin/sh
echo "ARGS=$*"
echo "RUNNER uid=$(id -u) user=$(id -un) home=$HOME caps=$(grep -E '^Cap(Eff|Amb)' /proc/self/status | tr '\n\t' '  ') config=$(cat @CONFIG@ >/dev/null 2>&1 && echo readable || echo denied)"
env | sort
if [ -n "${STUB_JOB:-}" ]; then
  IFS='
'
  set -f
  # shellcheck disable=SC2046
  set -- $(printf '%s' "$CIRCLECI_RUNNER_COMMAND_PREFIX" | sed -e 's/^\["//' -e 's/"\]$//' -e 's/","/\n/g')
  # sudo -i flattens newlines in arguments, so the probe is a script, like the real task agent.
  "$@" /opt/machine-runner-swarm/bin/probe
fi
exit "${STUB_EXIT:-0}"
EOF
  sed -i "s|@CONFIG@|$CONFIG|" "$STUB"
  sed "s|@CONFIG@|$CONFIG|" > /opt/machine-runner-swarm/bin/probe <<'EOF'
#!/bin/sh
echo "JOB uid=$(id -u) user=$(id -un) home=$HOME"
echo "JOB caps=$(grep -E '^Cap(Prm|Eff|Amb)' /proc/self/status | tr '\n\t' '  ')"
echo "JOB token=${CIRCLECI_RUNNER_API_AUTH_TOKEN:-unset} java=${JAVA_HOME:-unset} name=${CIRCLECI_RUNNER_NAME:-unset}"
echo "JOB path=$PATH"
echo "JOB no_new_privs=$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/self/status)"
# a setuid-root binary (the test makes a copy of setpriv): its effective uid is root's unless the kernel ignores the setuid bit
if [ -x /tmp/swarm-test/suid-setpriv ]; then echo "JOB suid_euid=$(/tmp/swarm-test/suid-setpriv --dump | sed -n 's/^euid:[[:space:]]*//p')"; fi
if sudo -n true 2>/dev/null; then echo "JOB sudo=yes"; else echo "JOB sudo=no"; fi
if touch /opt/machine-runner-swarm/bin/x 2>/dev/null; then echo "JOB opt_swarm_writable=yes"; else echo "JOB opt_swarm_writable=no"; fi
if (: < "@CONFIG@") 2>/dev/null; then echo "JOB config=readable"; else echo "JOB config=denied"; fi
EOF
  chmod 0755 "$STUB" /opt/machine-runner-swarm/bin/probe
}

teardown() {
  rm -rf /tmp/swarm-test
}

restore_etc() {
  for f in passwd group shadow gshadow sudoers; do
    if [ -e "$SNAP/$f" ]; then cat "$SNAP/$f" > "/etc/$f"; fi
  done
  rm -rf /etc/sudoers.d
  if [ -d "$SNAP/sudoers.d" ]; then cp -a "$SNAP/sudoers.d" /etc/sudoers.d; fi
  local home_dir=/home
  rm -rf "${home_dir:?}"
  cp -a "$SNAP/home" "$home_dir"
}

ep() { sh "$ENTRYPOINT" "$@"; }
# Print a directory holding every command on PATH except the named ones; use it as PATH.
path_without() {
  # Not under $BATS_TEST_TMPDIR (mode 0700): the runner user must be able to search it.
  local dir=/tmp/swarm-test/path-without-$$-$RANDOM p f n skip
  install -d -m 0755 /tmp/swarm-test "$dir"
  local IFS=:
  for p in $PATH; do
    for f in "$p"/*; do
      [ -x "$f" ] && [ ! -d "$f" ] || continue
      n=${f##*/}
      skip=
      for s in "$@"; do [ "$n" = "$s" ] && skip=1; done
      [ -n "$skip" ] || [ -e "$dir/$n" ] || ln -s "$f" "$dir/$n"
    done
  done
  echo "$dir"
}
need() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || skip "needs $c"; done
}
# Delete every regular account (uid 1000-59999), e.g. circleci and ubuntu in cimg images.
remove_regular_users() {
  local name uid
  while IFS=: read -r name _ uid _; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ]; then
      if command -v userdel >/dev/null 2>&1; then userdel -r "$name" >/dev/null 2>&1 || true; else deluser "$name" >/dev/null 2>&1 || true; fi
      rm -rf "/home/${name:?}"
    fi
  done < /etc/passwd
}
mkuser() { # name [uid]
  if command -v useradd >/dev/null 2>&1; then useradd -m ${2:+-u "$2"} "$1"; else adduser -D ${2:+-u "$2"} "$1"; fi
}

# ---------------------------------------------------------------------------------------------
# The runner
# ---------------------------------------------------------------------------------------------
@test "execs the runner with the config secret, as uid 2000 (circleci-runner), never root or the job user" {
  run ep
  [ "$status" -eq 0 ]
  [[ $output == *"ARGS=machine --config /run/secrets/circleci_runner_config.yaml"* ]]
  [[ $output == *"RUNNER uid=2000 user=circleci-runner"* ]]
  [[ $output == *"config=readable"* ]]
  [[ $output == *"CIRCLECI_RUNNER_TASK_AGENT_DIRECTORY=/var/lib/circleci-runner/agent"* ]]
  [[ $output == *"CIRCLECI_RUNNER_WORK_DIR=/var/opt/circleci/workdir"* ]]
  [[ $output == *"CIRCLECI_RUNNER_CLEANUP_WORK_DIR=false"* ]]
  [[ $output != *"CIRCLECI_RUNNER_API_AUTH_TOKEN"* ]]
}

@test "arguments replace the default runner arguments; the exit code passes through" {
  STUB_EXIT=7 run ep machine --config /elsewhere.yaml
  [ "$status" -eq 7 ]
  [[ $output == *"ARGS=machine --config /elsewhere.yaml"* ]]
}

@test "keeps the directories the stack sets" {
  CIRCLECI_RUNNER_WORK_DIR=/var/opt/circleci/other CIRCLECI_RUNNER_TASK_AGENT_DIRECTORY=/var/lib/circleci-runner/other-agent \
    CIRCLECI_RUNNER_CLEANUP_WORK_DIR=true run ep
  [ "$status" -eq 0 ]
  [[ $output == *"CIRCLECI_RUNNER_WORK_DIR=/var/opt/circleci/other"* ]]
  [[ $output == *"CIRCLECI_RUNNER_CLEANUP_WORK_DIR=true"* ]]
  [ "$(stat -c %u /var/lib/circleci-runner/other-agent)" = 2000 ]
}

@test "directories: the task agent belongs to the runner, the working directory to the job user" {
  run ep
  [ "$status" -eq 0 ]
  [ "$(stat -c %u /var/lib/circleci-runner/agent)" = 2000 ]
  [ "$(stat -c %a /var/lib/circleci-runner/agent)" = 755 ]
  [ "$(stat -c %u /var/opt/circleci/workdir)" = "$(id -u circleci)" ]
  [ "$(stat -c %u /var/opt/circleci)" = "$(id -u circleci)" ]
}

# ---------------------------------------------------------------------------------------------
# Exit 80: a prerequisite is missing
# ---------------------------------------------------------------------------------------------
@test "exit 80: runner binary missing" {
  rm -f "$STUB"
  run ep
  [ "$status" -eq 80 ]
  [[ $output == *"is missing"* ]]
}

@test "exit 80: /opt/machine-runner-swarm or the runner writable by others, or not owned by root" {
  chmod 0775 /opt/machine-runner-swarm
  run ep
  [ "$status" -eq 80 ]
  [[ $output == *"/opt/machine-runner-swarm must be owned by root"* ]]
  chmod 0755 /opt/machine-runner-swarm
  chmod 0777 "$STUB"
  run ep
  [ "$status" -eq 80 ]
  chmod 0755 "$STUB"
  chown 1234:1234 /opt/machine-runner-swarm/bin
  run ep
  [ "$status" -eq 80 ]
}

@test "exit 80: neither sudo nor setpriv, with the package names" {
  PATH=$(path_without sudo setpriv) run ep
  [ "$status" -eq 80 ]
  [[ $output == *"needs sudo or util-linux setpriv"* ]]
  [[ $output == *"apt-get install sudo"* ]]
  [[ $output != *"ARGS="* ]]
}

@test "exit 80: MACHINE_RUNNER_SWARM_JOB_SUDO must be true or false (a typo must not leave sudo on)" {
  MACHINE_RUNNER_SWARM_JOB_SUDO=False run ep
  [ "$status" -eq 80 ]
}

# ---------------------------------------------------------------------------------------------
# Users and step-down
# ---------------------------------------------------------------------------------------------
@test "creates the runner (uid 2000) and, when missing, the job user (circleci, uid 2001) with a home" {
  remove_regular_users
  run ep
  [ "$status" -eq 0 ]
  [ "$(id -u circleci-runner)" = 2000 ]
  [ "$(id -u circleci)" = 2001 ]
  [ -d /home/circleci ] && [ "$(stat -c %u /home/circleci)" = 2001 ]
}

@test "exit 80: an existing circleci-runner account must have uid 2000" {
  mkuser circleci-runner 2999
  run ep
  [ "$status" -eq 80 ]
  [[ $output == *"circleci-runner account with uid 2999"* ]]
  [[ $output != *"ARGS="* ]]
}

@test "MACHINE_RUNNER_SWARM_JOB_USER selects another job user (created if missing)" {
  MACHINE_RUNNER_SWARM_JOB_USER=builder run ep
  [ "$status" -eq 0 ]
  [[ $output == *"job=builder"* ]]
  [ "$(id -u builder)" = 2001 ]
}

@test "sudo step-down: jobs run as the job user with the image environment, without the token" {
  need sudo
  export JAVA_HOME=/opt/test-jdk CIRCLECI_RUNNER_NAME=unit-1 CIRCLECI_RUNNER_API_AUTH_TOKEN=must-not-leak
  STUB_JOB=1 run ep
  [ "$status" -eq 0 ]
  [[ $output == *'CIRCLECI_RUNNER_COMMAND_PREFIX=["sudo","-niHu","circleci","--"]'* ]]
  [[ $output == *"JOB uid="*" user=circleci home=/home/circleci"* ]]
  [[ $output == *"JOB token=unset java=/opt/test-jdk name=unit-1"* ]]
  [[ $output == *"JOB caps=CapPrm: 0000000000000000 CapEff: 0000000000000000 CapAmb: 0000000000000000"* ]]
  [[ $output == *"RUNNER uid=2000"*"CapEff: 0000000000000000 CapAmb: 0000000000000000"* ]]
  [[ $output == *"opt_swarm_writable=no"* ]]
  [[ $output == *"JOB config=denied"* ]]
  [[ $output == *"JOB path="*"$(dirname "$(command -v sh)")"* ]]
}

@test "sudo step-down: the runner may only sudo to the job user; a created job user gets sudo" {
  need sudo
  remove_regular_users
  STUB_JOB=1 run ep
  [ "$status" -eq 0 ]
  [[ $output == *"JOB sudo=yes"* ]]
  out=$(sudo -n -l -U circleci-runner 2>&1)
  [[ $out == *"(circleci) NOPASSWD: ALL"* ]]
  [[ $out != *"(root)"* ]] && [[ $out != *"(ALL"* ]]
}

@test "setpriv step-down (no sudo in the image): no capabilities, no sudo; the runner keeps only setuid/setgid" {
  need setpriv
  PATH=$(path_without sudo) STUB_JOB=1 run ep
  [ "$status" -eq 0 ]
  [[ $output == *"stepdown=setpriv"* ]]
  [[ $output == *'"setpriv","--reuid='* ]]
  [[ $output == *"JOB uid="*" user=circleci home=/home/circleci"* ]]
  [[ $output == *"JOB caps=CapPrm: 0000000000000000 CapEff: 0000000000000000 CapAmb: 0000000000000000"* ]]
  [[ $output == *"JOB sudo=no"* ]]
  [[ $output == *"JOB config=denied"* ]]
  [[ $output == *"CapAmb: 00000000000000c0"* ]]
  # the default class is unchanged: no no-new-privs flag
  [[ $output != *"--no-new-privs"* ]]
  [[ $output == *"JOB no_new_privs=0"* ]]
}

@test "su starts the runner when setpriv is missing (sudo still steps jobs down)" {
  need sudo su
  PATH=$(path_without setpriv) STUB_JOB=1 run ep
  [ "$status" -eq 0 ]
  [[ $output == *"RUNNER uid=2000 user=circleci-runner"* ]]
  [[ $output == *"JOB uid="*" user=circleci"* ]]
}

# ---------------------------------------------------------------------------------------------
# MACHINE_RUNNER_SWARM_JOB_SUDO=false (hardened)
# ---------------------------------------------------------------------------------------------
@test "hardened: removes the job user's sudo rights, keeps everyone else's, and still steps down" {
  need sudo
  mkuser deploy
  {
    echo 'circleci ALL=(ALL) NOPASSWD: ALL'
    echo 'deploy ALL=(ALL) NOPASSWD: ALL'
    echo 'Defaults:circleci !requiretty'
  } > /etc/sudoers.d/60-test
  chmod 0440 /etc/sudoers.d/60-test
  MACHINE_RUNNER_SWARM_JOB_SUDO=false STUB_JOB=1 run ep
  [ "$status" -eq 0 ]
  [[ $output == *"JOB sudo=no"* ]]
  [[ $output == *"JOB uid="*" user=circleci"* ]]
  [[ $output == *"JOB config=denied"* ]]
  grep -q '^deploy ALL' /etc/sudoers.d/60-test
  grep -q '^Defaults:circleci' /etc/sudoers.d/60-test
  [[ $(sudo -n -l -U circleci 2>&1) == *"not allowed to run sudo"* ]]
  [[ $(sudo -n -l -U deploy 2>&1) == *"may run the following commands"* ]]
}

@test "hardened: group memberships (sudo, wheel, admin), rules by uid (#n) and for ALL are removed too" {
  need sudo
  for g in sudo wheel admin; do
    grep -q "^$g:" /etc/group || echo "$g:x:$((3900 + ${#g})):" >> /etc/group
  done
  mkuser circleci 1234 2>/dev/null || true
  for g in sudo wheel admin; do sed -i "s/^\($g:[^:]*:[^:]*:\)\(.*\)$/\1circleci/" /etc/group; done
  {
    echo '%sudo ALL=(ALL) NOPASSWD: ALL'
    echo '%wheel ALL=(ALL) NOPASSWD: ALL'
    echo "#$(id -u circleci) ALL=(ALL) NOPASSWD: ALL"
    echo 'ALL ALL=(ALL) NOPASSWD: /bin/true'
  } > /etc/sudoers.d/62-more
  chmod 0440 /etc/sudoers.d/62-more
  MACHINE_RUNNER_SWARM_JOB_SUDO=false STUB_JOB=1 run ep
  [ "$status" -eq 0 ]
  [[ $output == *"JOB sudo=no"* ]]
  groups=" $(id -Gn circleci) "
  [[ $groups != *" sudo "* ]] && [[ $groups != *" wheel "* ]] && [[ $groups != *" admin "* ]]
}

@test "hardened: exit 80 when a right cannot be removed (a rule through an alias, or a user list)" {
  need sudo
  printf 'User_Alias ADMINS = circleci\nADMINS ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/64-alias
  chmod 0440 /etc/sudoers.d/64-alias
  MACHINE_RUNNER_SWARM_JOB_SUDO=false run ep
  [ "$status" -eq 80 ]
  [[ $output == *"could not remove every sudo right"* ]]
  [[ $output != *"ARGS="* ]]
  rm -f /etc/sudoers.d/64-alias
  printf 'other,circleci ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/65-list
  chmod 0440 /etc/sudoers.d/65-list
  MACHINE_RUNNER_SWARM_JOB_SUDO=false run ep
  [ "$status" -eq 80 ]
}

@test "hardened: without sudo in the image there is nothing to remove" {
  need setpriv
  PATH=$(path_without sudo) MACHINE_RUNNER_SWARM_JOB_SUDO=false STUB_JOB=1 run ep
  [ "$status" -eq 0 ]
  [[ $output == *"JOB sudo=no"* ]]
}

@test "hardened: steps down with setpriv --no-new-privs even when the image has sudo, so a setuid binary cannot elevate" {
  need sudo
  need setpriv
  mkdir -p /tmp/swarm-test
  cp "$(command -v setpriv)" /tmp/swarm-test/suid-setpriv
  chown 0:0 /tmp/swarm-test/suid-setpriv
  chmod 4755 /tmp/swarm-test/suid-setpriv
  chmod 0755 /tmp/swarm-test
  MACHINE_RUNNER_SWARM_JOB_SUDO=false STUB_JOB=1 run ep
  [ "$status" -eq 0 ]
  [[ $output == *"sudo=false stepdown=setpriv no_new_privs=yes"* ]]
  [[ $output == *'"--ambient-caps=-all","--no-new-privs","--","env"'* ]]
  [[ $output != *'"sudo","-niHu"'* ]]
  [[ $output == *"JOB no_new_privs=1"* ]]
  [[ $output == *"JOB sudo=no"* ]]
  [[ $output == *"JOB caps=CapPrm: 0000000000000000 CapEff: 0000000000000000 CapAmb: 0000000000000000"* ]]
  # the setuid-root copy of setpriv stays the job user (2001 or the image's circleci uid), not root
  [[ $output == *"JOB suid_euid="* ]]
  [[ $output != *"JOB suid_euid=0"* ]]
}

@test "default class with a setuid binary: no no-new-privs flag, the setuid bit still works (the control of the test above)" {
  need sudo
  need setpriv
  mkdir -p /tmp/swarm-test
  cp "$(command -v setpriv)" /tmp/swarm-test/suid-setpriv
  chown 0:0 /tmp/swarm-test/suid-setpriv
  chmod 4755 /tmp/swarm-test/suid-setpriv
  chmod 0755 /tmp/swarm-test
  STUB_JOB=1 run ep
  [ "$status" -eq 0 ]
  [[ $output == *"sudo=true stepdown=sudo no_new_privs=no"* ]]
  [[ $output == *"JOB no_new_privs=0"* ]]
  [[ $output == *"JOB suid_euid=0"* ]]
}

@test "hardened: exit 80 without util-linux setpriv, even when sudo is installed (no unprotected step-down)" {
  need sudo
  PATH=$(path_without setpriv) MACHINE_RUNNER_SWARM_JOB_SUDO=false run ep
  [ "$status" -eq 80 ]
  [[ $output == *"MACHINE_RUNNER_SWARM_JOB_SUDO=false needs util-linux setpriv with --no-new-privs"* ]]
  [[ $output != *"ARGS="* ]]
}

# ---------------------------------------------------------------------------------------------
# Signals and the Docker socket
# ---------------------------------------------------------------------------------------------
@test "SIGTERM reaches the runner, which can finish its job before exiting" {
  cat > "$STUB" <<'EOF'
#!/bin/sh
trap 'echo "DRAINING"; sleep 2; echo "JOB FINISHED"; exit 0' TERM
echo "RUNNER READY"
while true; do sleep 1; done
EOF
  chmod 0755 "$STUB"
  sh "$ENTRYPOINT" > "$BATS_TEST_TMPDIR/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 40); do grep -q 'RUNNER READY' "$BATS_TEST_TMPDIR/out" && break; sleep 0.25; done
  grep -q 'RUNNER READY' "$BATS_TEST_TMPDIR/out"
  kill -TERM "$pid"
  wait "$pid"
  rc=$?
  grep -q DRAINING "$BATS_TEST_TMPDIR/out"
  grep -q 'JOB FINISHED' "$BATS_TEST_TMPDIR/out"
  [ "$rc" -eq 0 ]
}

@test "docker socket: the job user joins the socket's group (docker-build pattern)" {
  need python3
  python3 - <<'EOF' &
import os, socket, time
p = "/var/run/docker.sock"
if os.path.exists(p): os.unlink(p)
s = socket.socket(socket.AF_UNIX); s.bind(p); os.chown(p, 0, 4242); s.listen(1)
time.sleep(30)
EOF
  sockpid=$!
  for _ in $(seq 1 20); do [ -S /var/run/docker.sock ] && break; sleep 0.2; done
  run ep
  kill "$sockpid" 2>/dev/null || true
  rm -f /var/run/docker.sock
  [ "$status" -eq 0 ]
  id -G circleci | tr ' ' '\n' | grep -qx 4242
}
