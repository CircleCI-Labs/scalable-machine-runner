#!/usr/bin/env bash
# Job B of the Linux e2e (see docs/ci.md). Runs inside a runner container that
# claimed this job from cci-labs/scalable-machine-runner-e2e-linux.
#
#   ci/e2e-probe.sh PROBE_ID [--previous PROBE_ID] [--expect-sudo true|false]
#
# 1. Report residue that an earlier job left outside the working directory
#    ($HOME, /tmp, /var/tmp and, through sudo when the image allows it, /etc).
# 2. With --previous: read that probe's evidence and require that this job runs in a
#    different container (container ID, MACHINE_RUNNER_SWARM_INSTANCE_ID and the overlay upper directory must
#    all differ).
# 3. Leave residue in the same places for the next job.
# 4. Try to read the runner token as the job user, without and with sudo, and record the
#    outcome. With --expect-sudo false (the hardened service, MACHINE_RUNNER_SWARM_JOB_SUDO=false) the job
#    must not be able to read the token and sudo must give no rights.
# 5. Write evidence for the host job (job A) to /e2e-evidence/PROBE_ID.WORKFLOW_ID.
#
# Exit 0 only when no residue was found, residue was planted, a --previous container
# differs, the token is unreadable without sudo, and (hardened) also unreadable with sudo.
# The evidence file is written in every case, so the host job can stop early.
#
# The token is never printed: reads go to /dev/null and only byte counts are kept.
# Never print the environment here either.
set -uo pipefail

probe=${1:?usage: e2e-probe.sh PROBE_ID [--previous PROBE_ID] [--expect-sudo true|false]}
shift
previous=
expect_sudo=true
while [ $# -gt 0 ]; do
  case $1 in
    --previous) previous=${2:?--previous needs a probe id}; shift 2 ;;
    --expect-sudo) expect_sudo=${2:?--expect-sudo needs true or false}; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case ${expect_sudo} in true | false) ;; *) echo "--expect-sudo must be true or false" >&2; exit 2 ;; esac

ev_dir=${E2E_EVIDENCE_DIR:-/e2e-evidence}
token_file=${E2E_TOKEN_FILE:-/run/secrets/circleci_runner_config.yaml}
wf=${CIRCLE_WORKFLOW_ID:?CIRCLE_WORKFLOW_ID is not set (run this as a CircleCI job)}
marker_name=.swarm-e2e-marker
failures=()

fail() {
  echo "E2E PROBE ${probe}: FAIL: $*"
  failures+=("$*")
}

# Identity: the host job writes $ev_dir/host before it deploys the service.
if ! grep -qx "workflow=${wf}" "${ev_dir}/host" 2>/dev/null; then
  echo "E2E PROBE ${probe}: FAIL: not running on the e2e host of workflow ${wf}."
  echo "Either a runner outside this workflow holds the e2e token, or the host"
  echo "job failed and its sweeper claimed this job to end it."
  exit 1
fi

# Where this job is running. Swarm names a container's hostname after its ID unless the
# service sets one; the overlay upper directory is unique per container writable layer.
container=$(hostname)
layer=$(grep ' / / ' /proc/self/mountinfo | grep -oE 'upperdir=[^,]+' | md5sum | cut -c1-12)
# Docker bind-mounts /etc/hostname from /var/lib/docker/containers/<container ID>/hostname, so
# the full container ID is readable inside (the stack sets the hostname to a per-slot name).
container_id=$(grep -m1 ' /etc/hostname ' /proc/self/mountinfo | grep -oE '/containers/[0-9a-f]{64}/' | cut -d/ -f3 || true)
instance=${MACHINE_RUNNER_SWARM_INSTANCE_ID:-}
job_user=$(id -un 2>/dev/null || echo "?")

echo "probe=${probe} user=${job_user}($(id -u)) hostname=${container} expect_sudo=${expect_sudo}"
echo "container_id=${container_id:-<unknown>} layer=${layer} swarm_instance_id=${instance:-<unset>} workdir=$(pwd)"
[ "$(id -u)" -ne 0 ] || fail "the job runs as root; jobs must run as an unprivileged job user"
# (circleci-runner-entrypoint no longer exports MACHINE_RUNNER_SWARM_INSTANCE_ID: the container ID and the layer identify a container.)

# 1. Residue from an earlier job.
candidates=("${HOME}/${marker_name}" "/tmp/${marker_name}" "/var/tmp/${marker_name}" "/etc/swarm-e2e-marker")
residue=()
for m in "${candidates[@]}"; do
  if [ -e "${m}" ]; then
    residue+=("${m}")
    echo "STALE STATE: ${m} exists (written by: $(head -c 200 "${m}" 2>/dev/null))"
  fi
done
[ "${#residue[@]}" -eq 0 ] || fail "residue from an earlier job: ${residue[*]}"

# 2. A different container from the previous probe.
if [ -n "${previous}" ]; then
  prev_file="${ev_dir}/${previous}.${wf}"
  if [ ! -s "${prev_file}" ]; then
    fail "no evidence from previous probe ${previous} (${prev_file})"
  else
    prev_container=$(sed -n 's/^container_id=//p' "${prev_file}")
    prev_layer=$(sed -n 's/^layer=//p' "${prev_file}")
    prev_instance=$(sed -n 's/^swarm_instance_id=//p' "${prev_file}")
    echo "previous probe ${previous}: container_id=${prev_container:-<unknown>} layer=${prev_layer} swarm_instance_id=${prev_instance}"
    [ -z "${instance}" ] || [ "${prev_instance}" != "${instance}" ] || fail "same MACHINE_RUNNER_SWARM_INSTANCE_ID as ${previous}: the container was reused"
    [ -n "${container_id}" ] || fail "cannot read the container ID from /proc/self/mountinfo"
    [ "${prev_container}" != "${container_id}" ] || fail "same container ID as ${previous}: the container was reused"
    [ "${prev_layer}" != "${layer}" ] || fail "same writable layer as ${previous}: the container was reused"
  fi
fi

# 3. Leave residue for the next job.
planted=()
for m in "${HOME}/${marker_name}" "/tmp/${marker_name}" "/var/tmp/${marker_name}"; do
  if printf '%s %s\n' "${probe}" "${wf}" > "${m}" 2>/dev/null; then
    planted+=("${m}")
  fi
done
sudo_works=no
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo_works=yes
  if printf '%s %s\n' "${probe}" "${wf}" | sudo -n tee /etc/swarm-e2e-marker >/dev/null 2>&1; then
    planted+=(/etc/swarm-e2e-marker)
  fi
else
  echo "note: no passwordless sudo here; /etc is not exercised"
fi
[ "${#planted[@]}" -ge 2 ] || fail "could not plant residue (planted: ${planted[*]:-none})"
echo "planted residue: ${planted[*]:-none}"

# 4. Token readability, as the job user. Only byte counts are kept, never the content.
read_bytes() {  # read_bytes [sudo]: prints the number of bytes read, or "fail" (pipefail is on)
  local n
  if [ "${1:-}" = sudo ]; then
    n=$(sudo -n cat "${token_file}" 2>/dev/null | wc -c) || { echo fail; return; }
  else
    n=$(cat "${token_file}" 2>/dev/null | wc -c) || { echo fail; return; }
  fi
  echo "${n}"
}
token_nosudo=denied
token_sudo=no-sudo
token_env=absent
if [ -e "${token_file}" ] || sudo -n test -e "${token_file}" 2>/dev/null; then
  out=$(read_bytes)
  if [ "${out}" != fail ] && [ "${out}" -gt 0 ]; then token_nosudo=readable; fi
  if [ "${sudo_works}" = yes ]; then
    out=$(read_bytes sudo)
    if [ "${out}" != fail ] && [ "${out}" -gt 0 ]; then token_sudo=readable; else token_sudo=denied; fi
  fi
else
  token_nosudo=absent
  fail "the token file ${token_file} does not exist in this container"
fi
# Variable names only, never values.
# (Names go into a variable first: `... | grep -q` under pipefail fails when grep exits early.)
env_names=$(env | cut -d= -f1)
if grep -qx 'CIRCLECI_RUNNER_API_AUTH_TOKEN' <<< "${env_names}"; then token_env=present; fi
# The runner holds the token in its environment. Another user's /proc/PID/environ must be
# unreadable to the job user; root (sudo) can read it.
environ_foreign=0
me=$(id -u)
for f in /proc/[0-9]*/environ; do
  [ -e "${f}" ] || continue
  [ "$(stat -c %u "${f}" 2>/dev/null || echo "${me}")" = "${me}" ] && continue
  if [ -r "${f}" ] && head -c 1 "${f}" > /dev/null 2>&1; then environ_foreign=$((environ_foreign + 1)); fi
done
runner_environ_sudo=no-sudo
if [ "${sudo_works}" = yes ]; then
  runner_environ_sudo=no
  for pid in $(pgrep -x circleci-runner 2>/dev/null || true); do
    runner_env_names=$(sudo -n cat "/proc/${pid}/environ" 2>/dev/null | tr '\0' '\n' | cut -d= -f1) || true
    if grep -qx 'CIRCLECI_RUNNER_API_AUTH_TOKEN' <<< "${runner_env_names}"; then
      runner_environ_sudo=holds-token
    fi
  done
fi
# The entrypoint script is called circleci-runner-entrypoint, which the kernel shortens to "circleci-runner" (15 characters): skip it.
runner_user=$(ps -eo user:32=,comm=,args= 2>/dev/null | awk '$2 == "circleci-runner" && $0 !~ /entrypoint/ { print $1; exit }')
# The token must not be on any command line either (ps shows every process's arguments).
token_ps=absent
ps_args=$(ps -eo args= 2>/dev/null || true)
if grep -qE 'auth_token|API_AUTH_TOKEN' <<< "${ps_args}"; then token_ps=present; fi
echo "token: as ${job_user} without sudo=${token_nosudo}; with sudo=${token_sudo} (sudo works: ${sudo_works}); runner user=${runner_user:-?}; token in job env=${token_env}"
echo "token: other users' process environments readable by the job user=${environ_foreign}; runner environment via sudo=${runner_environ_sudo}; token on a command line=${token_ps}"
[ "${token_nosudo}" != readable ] || fail "the job user can read the runner token without sudo"
[ "${token_ps}" = absent ] || fail "the token (or its variable) appears on a process command line"
# The job runs through the entrypoint's step-down (sudo -niHu <job user> --): the image's own user,
# not the runner user.
[ "${job_user}" = circleci ] || fail "the job runs as ${job_user}, expected the image user circleci"
[ -z "${runner_user}" ] || [ "${runner_user}" != "${job_user}" ] || fail "the runner and the job run as the same user (${job_user})"
if [ "${expect_sudo}" = true ]; then
  [ "${sudo_works}" = yes ] || fail "the default service must keep passwordless sudo for the job user"
fi
[ "${environ_foreign}" -eq 0 ] || fail "the job user can read the environment of ${environ_foreign} process(es) of other users (the runner holds the token in its environment)"
if [ "${expect_sudo}" = false ]; then
  [ "${token_env}" = absent ] || fail "hardened service: CIRCLECI_RUNNER_API_AUTH_TOKEN is in the job environment"
  [ "${sudo_works}" = no ] || fail "hardened service: the job user has working sudo"
  [ "${token_sudo}" != readable ] || fail "hardened service: the job user can read the token with sudo"
fi

# 5. Evidence for the host job, written atomically.
result=pass
[ "${#failures[@]}" -eq 0 ] || result=fail
tmp="${ev_dir}/.${probe}.${wf}.tmp"
{
  echo "probe=${probe}"
  echo "workflow=${wf}"
  echo "job=${CIRCLE_JOB:-} build=${CIRCLE_BUILD_NUM:-}"
  echo "hostname=${container}"
  echo "container_id=${container_id}"
  echo "layer=${layer}"
  echo "arch=$(uname -m)"
  echo "swarm_instance_id=${instance}"
  echo "uid=$(id -u)"
  echo "user=${job_user}"
  echo "runner_user=${runner_user:-}"
  echo "os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}") $(uname -m)"
  echo "expect_sudo=${expect_sudo}"
  echo "sudo_works=${sudo_works}"
  echo "token_nosudo=${token_nosudo}"
  echo "token_sudo=${token_sudo}"
  echo "token_env=${token_env}"
  echo "token_ps=${token_ps}"
  echo "environ_foreign_readable=${environ_foreign}"
  echo "runner_environ_via_sudo=${runner_environ_sudo}"
  echo "residue=[${residue[*]:-}]"
  echo "planted=[${planted[*]:-}]"
  echo "result=${result}"
} > "${tmp}" && mv -f "${tmp}" "${ev_dir}/${probe}.${wf}"

echo "RESULT probe=${probe} residue=${#residue[@]} planted=${#planted[@]} token_nosudo=${token_nosudo} token_sudo=${token_sudo} expect_sudo=${expect_sudo} result=${result}"
[ "${result}" = pass ]
