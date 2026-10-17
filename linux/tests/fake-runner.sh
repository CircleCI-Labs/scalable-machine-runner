#!/bin/sh
# Stand-in for circleci-runner in the Swarm tests. The tests serve it from their local mirror as the tarball of a version
# (@VERSION@ is replaced by the version), the runner-distributor installs it as versions/<version>/bin/circleci-runner, and the
# real circleci-runner-entrypoint starts it. It runs the fake job through CIRCLECI_RUNNER_COMMAND_PREFIX exactly as the real
# runner runs the task agent, so the step-down (sudo or setpriv) is exercised for real. The fake job is this same file with --fake-job.
#   single-task: one job, then exit 0 (like the real runner), so Swarm starts a new container
#   continuous:  a job every FAKE_JOB_INTERVAL seconds (default 2) until SIGTERM
version=@VERSION@
[ "${1:-}" != --version ] || { echo "circleci-runner version $version"; exit 0; }

# The fake job (a stand-in for a CircleCI job). Reports the residue that earlier jobs left in this container, then leaves residue
# everywhere a real job could: $HOME, /tmp, the runner working directory and (through sudo, when the job has it) /etc.
# The container identity is a hash of the overlay upperdir, so a reused container is recognised even
# when hostname and runner name are slot-stable.
if [ "${1:-}" = --fake-job ]; then
  seen=""
  for f in "$HOME/.job-marker" /tmp/.job-marker /var/opt/circleci/workdir/.job-marker /etc/job-marker; do
    [ -e "$f" ] && seen="$seen $f"
  done
  layer=$(grep ' / / ' /proc/self/mountinfo | grep -oE 'upperdir=[^,]+' | md5sum | cut -c1-12)
  if sudo -n true 2>/dev/null; then sudo=yes; else sudo=no; fi
  echo "FAKEJOB layer=$layer name=${CIRCLECI_RUNNER_NAME:-none} uid=$(id -u) user=$(id -un) sudo=$sudo version=$version residue=[${seen# }]"
  touch "$HOME/.job-marker" /tmp/.job-marker /var/opt/circleci/workdir/.job-marker 2>/dev/null
  sudo -n touch /etc/job-marker 2>/dev/null || true
  # A long job, to see that SIGTERM lets it finish (FAKE_JOB_SLEEP seconds).
  if [ -n "${FAKE_JOB_SLEEP:-}" ]; then
    sleep "$FAKE_JOB_SLEEP"
    echo "JOBEND layer=$layer version=$version"
  fi
  exit 0
fi

echo "FAKERUNNER start uid=$(id -u) user=$(id -un) mode=${CIRCLECI_RUNNER_MODE:-} name=${CIRCLECI_RUNNER_NAME:-} args=$*"
# FAKE_RUNNER_SERVE=1: just listen on port 8000 (network.sh), as the runner process.
[ -z "${FAKE_RUNNER_SERVE:-}" ] || exec python3 -m http.server 8000

self=$0
run_job() {
  (
    IFS='
'
    set -f
    # shellcheck disable=SC2046
    set -- $(printf '%s' "${CIRCLECI_RUNNER_COMMAND_PREFIX:-}" | sed -e 's/^\["//' -e 's/"\]$//' -e 's/","/\n/g')
    exec "$@" "$self" --fake-job
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
