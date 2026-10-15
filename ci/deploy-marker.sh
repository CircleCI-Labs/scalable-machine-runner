#!/usr/bin/env bash
# deploy-marker.sh: record a deploy in the Deploys view of CircleCI, with the deploy markers of the task agent
# (circleci run release plan / update). docs/ci.md, "Deploys".
#
#   ci/deploy-marker.sh plan NAME COMPONENT ENVIRONMENT VERSION
#   ci/deploy-marker.sh update NAME RUNNING|SUCCESS|FAILED|CANCELED [REASON]
#   ci/deploy-marker.sh guard NAME COMMAND...
#
#   plan     creates the deploy NAME (pending): the component COMPONENT at VERSION in the environment ENVIRONMENT. CircleCI
#            creates the component and the environment on first use.
#   update   moves the deploy NAME to a status. REASON (FAILED only) is the failure reason. A failed or canceled deploy
#            gives the live version back to the last good one.
#   guard    runs COMMAND, and when a cancel ends the step (SIGTERM or SIGINT reaches the script) it stops the command, gives the deploy
#            NAME the status CANCELED and exits 143. Without it a canceled job leaves its deploy at RUNNING: a canceled step runs no later
#            step, not even one with `when: on_fail`. The exit status of COMMAND is the exit status of guard; guard sends no other status.
#
# A marker never breaks the job it describes: when the task agent refuses a call (the Deploys feature is not available to
# the organization, a name clash), the script says so and exits 0. Only a wrong use of the script exits 2. It remembers its
# state in $DEPLOY_MARKER_DIR (default /tmp/deploy-marker), so that a step with `when: on_fail` can call `update NAME FAILED`
# without knowing whether `plan` ran: an update with no plan, or after the final status, does nothing (CircleCI refuses a
# second final status). Plan and update belong in ONE job: the docs say a rerun from failed breaks them across two jobs.
#
# Outside CircleCI (no CIRCLECI=true, or no circleci command) it does nothing.
set -euo pipefail

state_dir="${DEPLOY_MARKER_DIR:-${TMPDIR:-/tmp}/deploy-marker}"

usage() {
  echo "usage: ci/deploy-marker.sh plan NAME COMPONENT ENVIRONMENT VERSION" >&2
  echo "       ci/deploy-marker.sh update NAME RUNNING|SUCCESS|FAILED|CANCELED [REASON]" >&2
  echo "       ci/deploy-marker.sh guard NAME COMMAND..." >&2
  exit 2
}
say() { printf 'deploy-marker: %s\n' "$*"; }

[ $# -ge 2 ] || usage
cmd=$1
name=$2
[[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "deploy-marker: bad deploy name '${name}'" >&2; exit 2; }
state="${state_dir}/${name}"

# The marker is an extra: a failure of the call is reported, never passed on.
cli() {
  if circleci run release "$@"; then return 0; fi
  say "warning: circleci run release $1 failed: the deploy is not recorded (the job is not affected)"
  return 1
}
in_circleci() { [ "${CIRCLECI:-}" = true ] && command -v circleci > /dev/null 2>&1; }

case "${cmd}" in
  plan)
    [ $# -eq 5 ] || usage
    component=$3 environment=$4 version=$5
    in_circleci || { say "not in a CircleCI job: no deploy is recorded"; exit 0; }
    mkdir -p "${state_dir}"
    rm -f "${state}"
    if cli plan "${name}" --environment-name="${environment}" --component-name="${component}" --target-version="${version}"; then
      echo planned > "${state}"
      say "planned ${component} ${version} in ${environment} (deploy ${name})"
    fi
    ;;
  update)
    [ $# -eq 3 ] || [ $# -eq 4 ] || usage
    status=$3
    reason=${4:-}
    case "${status}" in RUNNING | SUCCESS | FAILED | CANCELED) ;; *) usage ;; esac
    in_circleci || exit 0
    # No plan (a run that publishes nothing), or the deploy has its final status already: nothing to update.
    [ -f "${state}" ] && [ "$(cat "${state}")" != "done" ] || exit 0
    args=("${name}" --status="${status}")
    if [ "${status}" = FAILED ] && [ -n "${reason}" ]; then
      reason=$(printf '%s' "${reason}" | tr '\n' ' ' | cut -c1-200)
      args+=(--failure-reason="${reason}")
    fi
    if cli update "${args[@]}"; then
      case "${status}" in RUNNING) echo running > "${state}" ;; *) echo "done" > "${state}" ;; esac
      say "deploy ${name} is ${status}"
    fi
    ;;
  guard)
    [ $# -ge 3 ] || usage
    shift 2
    "$@" &
    child=$!
    # A signal makes `wait` return at once, and the trap then runs: stop the command, record the cancel, and leave.
    trap 'kill -TERM "${child}" 2> /dev/null || true; wait "${child}" 2> /dev/null || true; "$0" update "${name}" CANCELED; exit 143' TERM INT
    rc=0
    wait "${child}" || rc=$?
    trap - TERM INT
    exit "${rc}"
    ;;
  *) usage ;;
esac
