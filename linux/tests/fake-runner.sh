#!/bin/sh
# Stand-in for circleci-runner in the Swarm tests (installed as /opt/smr/bin/circleci-runner next to
# the real smr-entrypoint). It runs the fake job through CIRCLECI_RUNNER_COMMAND_PREFIX exactly as
# the real runner runs the task agent, so the step-down (sudo or setpriv) is exercised for real.
#   single-task: one job, then exit 0 (like the real runner), so Swarm starts a new container
#   continuous:  a job every FAKE_JOB_INTERVAL seconds (default 2) until SIGTERM
echo "FAKERUNNER start uid=$(id -u) user=$(id -un) mode=${CIRCLECI_RUNNER_MODE:-} name=${CIRCLECI_RUNNER_NAME:-} args=$*"
# FAKE_RUNNER_SERVE=1: just listen on port 8000 (network.sh), as the runner process.
[ -z "${FAKE_RUNNER_SERVE:-}" ] || exec python3 -m http.server 8000

run_job() {
  (
    IFS='
'
    set -f
    # shellcheck disable=SC2046
    set -- $(printf '%s' "${CIRCLECI_RUNNER_COMMAND_PREFIX:-}" | sed -e 's/^\["//' -e 's/"\]$//' -e 's/","/\n/g')
    exec "$@" /opt/smr/bin/fake-job
  )
}

case ${CIRCLECI_RUNNER_MODE:-single-task} in
  single-task)
    run_job
    echo "FAKERUNNER done rc=$?"
    exit 0
    ;;
  continuous)
    trap 'echo "FAKERUNNER draining"; exit 0' TERM
    while :; do
      run_job
      sleep "${FAKE_JOB_INTERVAL:-2}" &
      wait $!
    done
    ;;
esac
