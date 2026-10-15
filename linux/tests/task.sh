#!/usr/bin/env bash
# task.sh: the REAL runner runs a task through the real entrypoint's step-down. Token-free.
#
# A small fake API (fake-api.py, in a cimg container beside the Swarm) hands the real circleci-runner a
# task with an empty job; the runner then does what it does for a real job: clean (or not) the working
# directory, start the task agent through CIRCLECI_RUNNER_COMMAND_PREFIX ("sudo -niHu circleci --", or setpriv with
# --no-new-privs for the hardened class), and
# clean up. The "agent" is a shell script that prints what the job user can see and leaves files in the
# working directory the way a checkout would.
#
#   default      linux-default: the agent runs as circleci, has sudo, cannot read the config secret
#   hardened     linux-hardened (classes-extra.yaml): the same without sudo, and with the no-new-privs flag set (setpriv step-down)
#   cleanup      CIRCLECI_RUNNER_CLEANUP_WORK_DIR=true fails: the runner (uid 2000) cannot remove the
#                working directory the job user owns. This is why the stack and the entrypoint default it to false
#   persistent   persistent.yaml (continuous mode): two tasks in one runner; the second sees the first's files
#                and nothing fails
#
# Usage: task.sh        Env: TIMEOUT=120
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
TIMEOUT=${TIMEOUT:-120}

session_begin
publish_runner real
export SWARM_TEST_HOST=$SWARM_TEST_MGR   # the DinD container's hostname is its name; replaces CHANGE-ME
docker cp "$tests_dir/fake-api.py" "$SWARM_TEST_MGR:/fake-api.py"
api_ip=$(docker exec "$SWARM_TEST_MGR" hostname -i | awk '{ print $1 }')
api="CIRCLECI_RUNNER_API_URL=http://$api_ip:8099"

# phase NAME TASKS "SERVICE REPLICAS [ENV...]" [STACK_FILE...]: deploy, wait for the service's logs
phase() {
  local name=$1 tasks=$2 spec=$3
  shift 3
  inner_reset "$SWARM_TEST_MGR"
  create_secrets "$SWARM_TEST_MGR" "$SENTINEL_TOKEN" "${BASE_SERVICES[@]}" "${EXTRA_SERVICES[@]}" linux-persistent
  idocker "$SWARM_TEST_MGR" run -d --name fake-api --network host -v /fake-api.py:/fake-api.py:ro "$CIMG_IMAGE" python3 /fake-api.py 8099 "$tasks" >/dev/null
  make_override "$work/ov.yaml" "$spec $api"
  deploy_stack "$SWARM_TEST_MGR" "$work/ov.yaml" "${@:-runners.yaml}"
  svc=${spec%% *}
}
task_lines() { service_logs "$SWARM_TEST_MGR" "$svc" | grep -a '^TASK ' || true; }
wait_tasks() { # N
  local i
  for ((i = 0; i < TIMEOUT; i++)); do
    if [[ $(task_lines | wc -l) -ge $1 ]]; then return 0; fi
    sleep 1
  done
  fail "$svc: fewer than $1 task(s) ran within ${TIMEOUT}s"
}

for class in default hardened; do
  files=(runners.yaml)
  [[ $class == default ]] || files+=(classes-extra.yaml)   # linux-hardened is in classes-extra.yaml
  phase "$class" 1 "linux-$class 1" "${files[@]}"
  wait_tasks 1
  line=$(task_lines | head -n 1)
  echo "RESULT test=task class=linux-$class $line"
  [[ $line == *"user=circleci home=/home/circleci workdir=/var/opt/circleci/workdir residue=0"* ]] || fail "linux-$class: the agent did not run as circleci in the working directory"
  [[ $line == *"config=denied token_env=0"* ]] || fail "linux-$class: the agent can reach the token"
  if [[ $class == default ]]; then
    [[ $line == *"sudo=yes"* && $line == *"no_new_privs=0"* ]] || fail "linux-default: the job lost sudo, or runs with no-new-privs (the default class is unchanged)"
  else
    [[ $line == *"sudo=no"* && $line == *"no_new_privs=1"* ]] || fail "linux-hardened: the job has sudo, or runs without no-new-privs (a setuid binary could elevate)"
  fi
  service_logs "$SWARM_TEST_MGR" "$svc" | grep -aq 'result=success' || fail "linux-$class: the runner did not finish the task successfully"
done

phase cleanup 1 "linux-default 1 CIRCLECI_RUNNER_CLEANUP_WORK_DIR=true"
for ((i = 0; i < TIMEOUT; i++)); do
  if service_logs "$SWARM_TEST_MGR" "$svc" | grep -aq 'failed to remove working directory'; then break; fi
  sleep 1
done
service_logs "$SWARM_TEST_MGR" "$svc" | grep -aq 'failed to remove working directory' || fail "cleanup=true did not fail the way CI saw it"
msg=$(service_logs "$SWARM_TEST_MGR" "$svc" | grep -a 'failed to remove working directory' | head -n 1 | grep -ao 'failed to remove working directory[^"]*' | cut -c1-150)
tasks=$(task_lines | wc -l)
echo "RESULT test=task step=cleanup=true tasks_run=$tasks error=\"$msg\""
[[ $tasks -eq 0 ]] || fail "a task ran although the working directory could not be cleaned"

phase persistent 2 "linux-persistent 1" runners.yaml persistent.yaml
wait_tasks 2
mapfile -t lines < <(task_lines | head -n 2)
printf 'RESULT test=task step=persistent %s\n' "${lines[@]}"
[[ ${lines[0]} == *"residue=0"* && ${lines[1]} != *"residue=0"* ]] || fail "the second task of a persistent runner should see the first one's files"
if service_logs "$SWARM_TEST_MGR" "$svc" | grep -aq 'failed to remove'; then fail "a persistent runner failed to clean up"; fi

pass "the real runner runs tasks as the job user through sudo -niHu (default) or setpriv --no-new-privs (hardened); cleanup=true cannot work with a stepped-down job, so it defaults to false; a persistent runner keeps files between tasks and does not fail"
