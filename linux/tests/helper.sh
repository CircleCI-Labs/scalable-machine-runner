#!/usr/bin/env bash
# helper.sh: the Docker-facing steps of linux/setup.sh (--check, --swarm-init, --secret, --deploy)
# against a fresh Docker daemon inside a DinD container. The helper itself runs in a cimg container
# that shares the DinD container's network namespace, so the host's engine is never touched.
#
# Usage: helper.sh
set -euo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

node=swarm-test-helper-$$
dind_start "$node"
work=$(mktemp -d)
trap 'docker rm -f -v "$node" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
# a copy of the stack with no replicas: only the helper's steps are under test, not the tasks
sed -E 's/^( +replicas: )[0-9]+/\10/' "$stack_dir/runners.yaml" > "$work/runners.yaml"
dind_load "$node" "$CIMG_IMAGE"
dind_load "$node" alpine:3

setup() { # args... ; stdin is passed through
  docker run --rm -i --network "container:$node" -e DOCKER_HOST=tcp://127.0.0.1:2375 \
    -v "$repo_dir:/src:ro" -v "$work:/work:ro" "$CIMG_IMAGE" bash /src/linux/setup.sh "$@" 2>&1
}

out=$(setup --check </dev/null)
grep -q 'Swarm: inactive' <<< "$out" || fail "--check: $out"
echo "RESULT test=helper step=check swarm=inactive"

out=$(setup --swarm-init </dev/null)
grep -q 'Swarm initialised' <<< "$out" || fail "--swarm-init: $out"
out=$(setup --swarm-init </dev/null)
grep -q 'already active' <<< "$out" || fail "--swarm-init is not idempotent: $out"
addr=$(idocker "$node" info --format '{{.Swarm.NodeAddr}}')
echo "RESULT test=helper step=swarm-init state=active idempotent=yes node_addr=$addr"
[[ $addr == 127.0.0.1 ]] || fail "the single node should advertise 127.0.0.1, got $addr"

out=$(printf '%s\n' "$SENTINEL_TOKEN" | setup --secret linux-default)
grep -q 'created secret linux-default-token' <<< "$out" || fail "--secret: $out"
if grep -q "$SENTINEL_TOKEN" <<< "$out"; then fail "the token was echoed"; fi
out=$(printf '%s\n' "$SENTINEL_TOKEN" | setup --secret linux-default)
grep -q 'exists' <<< "$out" || fail "--secret is not idempotent: $out"
if printf '' | setup --secret linux-java >/dev/null; then fail "an empty token was accepted"; fi
if idocker "$node" secret inspect linux-java-token >/dev/null 2>&1; then fail "an empty secret was created"; fi
# the secret is a runner config holding the token
idocker "$node" service create -d --name sec-check --restart-condition none --secret linux-default-token alpine:3 cat /run/secrets/linux-default-token >/dev/null
wait_for 30 bash -c "docker exec $node docker service logs --raw sec-check 2>&1 | grep -q auth_token"
content=$(idocker "$node" service logs --raw sec-check 2>&1)
idocker "$node" service rm sec-check >/dev/null 2>&1 || true
[[ $content == $'api:\n  auth_token: '"$SENTINEL_TOKEN" ]] || fail "the secret is not a runner config: $content"
echo "RESULT test=helper step=secret created=yes content=runner-config token_echoed=no idempotent=yes empty_refused=yes"

out=$(setup --deploy --stack-file /work/runners.yaml </dev/null || true)
grep -q 'secret not found' <<< "$out" || fail "--deploy without the other secrets should fail with Docker's message: $out"
echo "RESULT test=helper step=deploy_without_secrets refused=yes"

for s in linux-java linux-hardened; do printf '%s' "$SENTINEL_TOKEN" | setup --secret "$s" >/dev/null; done
setup --deploy --stack-file /work/runners.yaml </dev/null >/dev/null
services=$(idocker "$node" stack services runners --format '{{.Name}}' | sort | paste -sd, -)
echo "RESULT test=helper step=deploy services=$services"
[[ $services == runners_linux-default,runners_linux-hardened,runners_linux-java ]] || fail "unexpected services: $services"

pass "setup.sh: preflight, single-node swarm init, secrets from stdin (a runner config, never echoed), deploy; all idempotent"
