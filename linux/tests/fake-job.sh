#!/bin/sh
# Stand-in for a CircleCI job (installed as /opt/smr/bin/fake-job). Reports the residue that earlier
# jobs left in this container, then leaves residue everywhere a real job could: $HOME, /tmp, the
# runner working directory and (through sudo, when the job has it) /etc.
# The container identity is a hash of the overlay upperdir, so a reused container is recognised even
# when hostname and runner name are slot-stable.
seen=""
for f in "$HOME/.job-marker" /tmp/.job-marker /var/opt/circleci/workdir/.job-marker /etc/job-marker; do
  [ -e "$f" ] && seen="$seen $f"
done
layer=$(grep ' / / ' /proc/self/mountinfo | grep -oE 'upperdir=[^,]+' | md5sum | cut -c1-12)
if sudo -n true 2>/dev/null; then sudo=yes; else sudo=no; fi
echo "FAKEJOB layer=$layer name=${CIRCLECI_RUNNER_NAME:-none} uid=$(id -u) user=$(id -un) sudo=$sudo residue=[${seen# }]"
touch "$HOME/.job-marker" /tmp/.job-marker /var/opt/circleci/workdir/.job-marker 2>/dev/null
sudo -n touch /etc/job-marker 2>/dev/null || true
# A long job, to see that SIGTERM lets it finish (FAKE_JOB_SLEEP seconds).
if [ -n "${FAKE_JOB_SLEEP:-}" ]; then
  sleep "$FAKE_JOB_SLEEP"
  echo "JOBEND layer=$layer"
fi
exit 0
