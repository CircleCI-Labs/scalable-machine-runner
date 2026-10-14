#!/usr/bin/env bash
# container-mode.sh: the swarm container agent runs a Docker-executor job end to end. Token-free.
#
# On the worker of the DinD Swarm (labelled for container mode) the real container-mode.yaml deploys the real agent: a
# stock Go image that compiles the sources of linux/stack/container-agent from their Swarm configs. A fake runner API (fake-container-api.py) hands it two tasks, each with
# a primary container and a service that listens on port 5432, as a database would. A fake init image stands
# in for circleci/runner-init: its "orchestrator" copies itself into the per-task volume and, as the primary
# container's PID 1, looks around like a job and reports to the API. The test checks that
#   - the primary reaches the service on localhost (one shared network namespace), with its environment
#     expanded, the limits applied, and no socket, no secrets directory and no class token inside
#   - the agent claims only with a free slot (CCA_MAX_TASKS=1, so the two tasks never overlap)
#   - a successful job ends with the cleanup event, a failing primary (exit code 3) with fail and then cleanup
#   - every container, network and volume of the tasks is gone afterwards, and the agent removed the orphans
#     of an earlier crash at start-up but left a container that is not ours
#   - no token reaches the agent's log
#
# Usage: container-mode.sh        Env: TIMEOUT=240
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
test_name=container-mode
TIMEOUT=${TIMEOUT:-240}
PAUSE_IMAGE=registry.k8s.io/pause:3.10
GO_IMAGE=$(sed -n 's/^    image: \(golang:[0-9.]*-alpine\)@sha256:.*/\1/p' "$stack_dir/container-mode.yaml")   # the stack file's tag; the test uses the loaded tag
LABEL=io.circleci.swarm.container-mode=1

session_begin --worker
M=$SWARM_TEST_MGR
W=$SWARM_TEST_WRK
DIAG_NODES="$M $W"

# Images: the Go image that builds the agent, the pause image, and a fake init image on top of the job image.
[[ -n $GO_IMAGE ]] || fail "no golang image in container-mode.yaml"
for i in "$GO_IMAGE" "$PAUSE_IMAGE"; do docker image inspect "$i" > /dev/null 2>&1 || docker pull -q "$i" > /dev/null; done
dind_load "$W" "$GO_IMAGE"
dind_load "$W" "$PAUSE_IMAGE"
ctx=$work/init
mkdir -p "$ctx"
cp "$tests_dir/fake-goat.py" "$ctx/orchestrator"
cp "$tests_dir/fake-goat.py" "$ctx/circleci-agent"
printf 'FROM %s\nUSER root\nCOPY --chmod=0755 orchestrator circleci-agent /\nENTRYPOINT ["/orchestrator", "init"]\n' "$CIMG_IMAGE" > "$ctx/Dockerfile"
tar -C "$ctx" -cf - . | idocker "$W" build -q -t fake-runner-init:test - > /dev/null

# What an earlier crash left (ours: labelled), and a container that is not ours.
idocker "$W" network create --label "$LABEL" cci-orphan-net > /dev/null
idocker "$W" volume create --label "$LABEL" cci-orphan-vol > /dev/null
idocker "$W" run -d --name cci-orphan --label "$LABEL" "$CIMG_IMAGE" sleep 600 > /dev/null
idocker "$W" run -d --name bystander "$CIMG_IMAGE" sleep 600 > /dev/null

# The fake API, beside the agent on the worker.
docker cp "$tests_dir/fake-container-api.py" "$W:/fake-container-api.py"
api_ip=$(docker exec "$W" hostname -i | awk '{ print $1 }')
idocker "$W" run -d --name fake-api --network host -v /fake-container-api.py:/f.py:ro "$CIMG_IMAGE" python3 /f.py 8099 "$SENTINEL_TOKEN" "$CIMG_IMAGE" > /dev/null
state() { docker exec "$W" wget -qO- http://127.0.0.1:8099/test/state; }
wait_for 20 state > /dev/null || fail "the fake API did not start"

# Deploy: the class token in a secret, the worker labelled, the real stack file (with the sources and the entrypoint that its
# configs name, next to it) and a small override.
docker exec "$M" mkdir -p /stack
docker cp "$stack_dir/container-agent" "$M:/stack/container-agent"
printf '%s' "$SENTINEL_TOKEN" | idocker "$M" secret create docker-default-token - > /dev/null
idocker "$M" node update --label-add machine-runner-swarm.container-mode=true "$W" > /dev/null
cat > "$work/ov.yaml" <<YAML
services:
  container-agent:
    image: $GO_IMAGE
    environment:
      CCA_RUNNER_API: http://$api_ip:8099
      CCA_INIT_IMAGE: fake-runner-init:test
      CCA_PAUSE_IMAGE: $PAUSE_IMAGE
      CCA_PULL: missing
      CCA_MAX_TASKS: "1"
      CCA_POLL_INTERVAL: 1s
      CCA_CLASSES: '[{"name":"ns/docker-default","token_file":"/run/secrets/docker-default-token","primary":{"cpus":1,"memory_mb":512},"service":{"cpus":0.5,"memory_mb":256}}]'
YAML
deploy_stack "$M" "$work/ov.yaml" container-mode.yaml

# Watch the job containers while a primary runs: none may hold the socket, and the service must share the pause container's network.
seen=
tasks_done() { [[ $(state | python3 -c 'import json,sys; print(sum(e["event"] == "cleanup" for e in json.load(sys.stdin)["events"]))') -ge 2 ]]; }
for ((i = 0; i < TIMEOUT; i++)); do
  if tasks_done; then break; fi
  if [[ -z $seen && -n $(idocker "$W" ps -q --filter label=io.circleci.swarm.role=primary) ]]; then
    mapfile -t ids < <(idocker "$W" ps -q --filter "label=$LABEL")
    seen=$(idocker "$W" inspect --format '{{index .Config.Labels "io.circleci.swarm.role"}} net={{.HostConfig.NetworkMode}} mounts={{range .Mounts}}{{.Destination}},{{end}}' "${ids[@]}")
  fi
  sleep 1
done
tasks_done || fail "the two tasks did not finish within ${TIMEOUT}s"
echo "RESULT test=container-mode step=job-containers $(tr '\n' ';' <<< "$seen")"
grep -q 'docker.sock' <<< "$seen" && fail "a job container mounts the Docker socket"
grep -q '^service net=container:' <<< "$seen" || fail "the service does not share the pause container's network: $seen"
grep -q '^primary net=container:.* mounts=/opt/circleci/bin,$' <<< "$seen" || fail "the primary has the wrong network or mounts: $seen"

# What the job saw, and what the API got.
state > "$work/state.json"
python3 - "$work/state.json" <<'PY' || fail "the API saw something wrong (above)"
import json, sys
s = json.load(open(sys.argv[1]))
r0 = next(r for r in s["reports"] if r["task"] == 0)
print("RESULT test=container-mode step=report", {k: r0[k] for k in ("service_reply", "env_built", "memory_max", "cpu_max", "uid", "user", "bin_files")})
bad = []
def need(ok, what):
    if not ok:
        bad.append(what)
need(len(s["reports"]) == 2, "two reports")
need(r0["service_reply"].startswith("HTTP/1.0 200"), "the service on localhost:5432 answered: %r" % r0["service_reply"])
need(r0["token_ok"] and r0["task_agent_path"] == "/opt/circleci/bin/circleci-agent", "the GOAT config has the task token, allocation and agent path")
need(r0["user"] == "" and r0["uid"] != 0, "the job user is the container user (uid %d), not a GOAT switch" % r0["uid"])
need(r0["env_foo"] == "bar" and r0["env_built"] == "build", "environment and ${CIRCLE_JOB} expansion")
need(r0["bin_files"] == ["circleci-agent", "orchestrator"], "the init step copied both binaries: %r" % r0["bin_files"])
need(not r0["goat_config_in_env"], "GOAT removed its config from the environment")
need(not r0["socket_present"], "no Docker socket in the job")
need(not r0["secrets_dir"], "no /run/secrets in the job")
need(not r0["class_token_visible"], "the class token is not in the job environment")
need(r0["memory_max"] == str(512 << 20), "memory limit 512 MiB: %r" % r0["memory_max"])
need(r0["cpu_max"] == "100000 100000", "cpu limit 1: %r" % r0["cpu_max"])
need(r0["hostname"].startswith("cci-"), "hostname of the shared namespace")
ev = [(e["task"], e["event"]) for e in s["events"]]
need(ev == [(0, "cleanup"), (1, "fail"), (1, "cleanup")], "events (success: cleanup; failure: fail, then cleanup): %r" % ev)
fail_msg = next(e["message"] for e in s["events"] if e["event"] == "fail")
need("exited with code 3" in fail_msg, "the fail message names the exit code: %r" % fail_msg)
need(s["max_inflight"] == 1, "the agent claimed only with a free slot (max in flight %d)" % s["max_inflight"])
for b in bad:
    print("  FAIL:", b)
sys.exit(1 if bad else 0)
PY

# Cleanup: nothing of the tasks is left; the orphans are gone; the bystander and the agent are not.
left=$(idocker "$W" ps -aq --filter "label=$LABEL"; idocker "$W" network ls -q --filter "label=$LABEL"; idocker "$W" volume ls -q --filter "label=$LABEL")
[[ -z $left ]] || fail "containers, networks or volumes of container mode are left: $left"
[[ -z $(idocker "$W" ps -aq --filter name=cci-) ]] || fail "a container named cci-* is left"
[[ -n $(idocker "$W" ps -q --filter name=bystander) ]] || fail "the agent removed a container that is not its own"
[[ -n $(running_container "$W" container-agent) ]] || fail "the agent is not running"
echo "RESULT test=container-mode step=cleanup left=none orphans=removed bystander=kept"
logs=$(service_logs "$M" container-agent)
grep -q 'startup cleanup: removed 3 ' <<< "$logs" || fail "the agent did not report removing the 3 orphans: $(grep -a 'startup cleanup' <<< "$logs")"
if grep -aq "$SENTINEL_TOKEN\|task-token" <<< "$logs"; then fail "a token is in the agent's log"; fi

idocker "$M" node update --label-rm machine-runner-swarm.container-mode "$W" > /dev/null
pass "the agent ran a docker job with a service on localhost, applied the limits, kept the socket and tokens out of the job, claimed only with a free slot, reported success and failure, and removed every container, network and volume, orphans included"
