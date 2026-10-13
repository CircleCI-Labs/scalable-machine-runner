#!/usr/bin/env bash
# Smoke test of the Linux install path on a fresh machine VM, with no real runner token.
# Used by the linux-setup (x86_64) and linux-arm64 jobs.
#
#   ci/linux-smoke.sh
#
# 1. linux/setup.sh --check, then --swarm-init --install (and --install again: idempotent).
# 2. The installed layout is root-owned and the runner runs, unmodified, inside a stock cimg image
#    through the read-only mount; the entrypoint refuses to start without a runner name (exit 80).
# 3. The shipped stack, deployed with linux/setup.sh --deploy and a made-up token: the services
#    linux-default and linux-hardened start a container each, and inside them
#      - the runner runs as circleci-runner and the job user is circleci;
#      - the job user cannot read the token file, nor other users' process environments;
#      - linux-default keeps sudo (so sudo can read the token: the documented outcome);
#      - linux-hardened has no sudo at all.
#    The runner gets 401 from CircleCI for the made-up token, which does not matter here.
#
# Prints RESULT lines; exits 0 only if every check passed.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "${here}/.." && pwd)
setup="${repo}/linux/setup.sh"
image=${E2E_IMAGE:-cimg/base:2026.10@sha256:64becfab2860932391d834a770033665874e287a655dbef26e38df060414a79a}
stack=runners
work=$(mktemp -d)
failed=0

log() { printf '[linux-smoke %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
check() {  # check NAME COMMAND...: record PASS or FAIL
  local name=$1; shift
  if "$@" > "${work}/check.out" 2>&1; then
    printf 'CHECK %s PASS\n' "${name}"
  else
    printf 'CHECK %s FAIL\n' "${name}"
    sed 's/^/    /' "${work}/check.out" | tail -n 15
    failed=$((failed + 1))
  fi
}
cleanup() {
  docker stack rm "${stack}" > /dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    [ -z "$(docker ps -aq --filter "label=com.docker.stack.namespace=${stack}")" ] && break
    sleep 1
  done
  docker secret ls -q 2> /dev/null | xargs -r docker secret rm > /dev/null 2>&1 || true
  docker swarm leave --force > /dev/null 2>&1 || true
  rm -rf "${work}"
}
trap cleanup EXIT

arch=$(uname -m)
log "host: $(. /etc/os-release && echo "${PRETTY_NAME}") ${arch}, docker $(docker version --format '{{.Server.Version}}')"

# --- 1. the helper ----------------------------------------------------------------------------
check setup-check sudo "${setup}" --check
check setup-install sudo "${setup}" --swarm-init --install
check setup-idempotent sudo "${setup}" --swarm-init --install
check swarm-active test "$(docker info --format '{{.Swarm.LocalNodeState}}')" = active

# --- 2. the layout, in a stock image ----------------------------------------------------------
layout() {
  [ -x /opt/machine-runner-swarm/bin/circleci-runner ] && [ -x /opt/machine-runner-swarm/bin/circleci-runner-entrypoint ] && [ -s /opt/machine-runner-swarm/VERSION ] &&
    [ -z "$(find /opt/machine-runner-swarm ! -user root -o -perm /022)" ]
}
check layout-root-owned layout
mounted() { docker run --rm -v /opt/machine-runner-swarm:/opt/machine-runner-swarm:ro "${image}" "$@"; }
runner_version() {
  local v
  v=$(mounted /opt/machine-runner-swarm/bin/circleci-runner --version) && echo "${v}" && grep -q "version $(cat /opt/machine-runner-swarm/VERSION)" <<< "${v}"
}
check runner-in-stock-image runner_version
container_arch() {
  local a
  a=$(mounted uname -m) && echo "container arch ${a}, host ${arch}" && [ "${a}" = "${arch}" ]
}
check container-arch-matches-host container_arch
runner_is_native() {
  local info
  info=$(file -L /opt/machine-runner-swarm/bin/circleci-runner 2> /dev/null || true)
  echo "${info}"
  case ${arch} in
    x86_64) grep -q 'x86-64' <<< "${info}" ;;
    aarch64) grep -q 'ARM aarch64' <<< "${info}" ;;
    *) return 1 ;;
  esac
}
check runner-binary-architecture runner_is_native
exit80_without_name() {
  # A config file with a made-up token and no runner name: the runner itself rejects it with 80,
  # and the entrypoint passes the code through. (Without a config file the runner exits 1.)
  local rc=0
  printf 'api:\n  auth_token: not-a-real-token\n' > "${work}/config.yaml"
  docker run --rm --user 0 -v /opt/machine-runner-swarm:/opt/machine-runner-swarm:ro \
    -v "${work}/config.yaml:/run/secrets/circleci_runner_config.yaml:ro" "${image}" /opt/machine-runner-swarm/bin/circleci-runner-entrypoint || rc=$?
  echo "exit ${rc}"
  [ "${rc}" -eq 80 ]
}
check entrypoint-exit-80-without-a-runner-name exit80_without_name

# --- 3. the shipped stack with a made-up token -----------------------------------------------
for svc in linux-default linux-hardened; do
  printf '%s' "ci-smoke-not-a-real-token" | sudo "${setup}" --secret "${svc}" > /dev/null 2>&1 || log "secret ${svc} failed"
done
for svc in linux-java linux-persistent linux-docker-build; do
  printf 'unused' | docker secret create "${svc}-token" - > /dev/null 2>&1 || true
done
check setup-deploy sudo "${setup}" --deploy
# The shipped sizes (2 CPUs and 4 GB each) do not fit one CI VM: shrink what the test needs, as an
# operator would on a small host, and stop what it does not.
docker service update --detach --replicas 1 --reserve-cpu 0.1 --reserve-memory 64m "${stack}_linux-default" > /dev/null
docker service update --detach --reserve-cpu 0.1 --reserve-memory 64m "${stack}_linux-hardened" > /dev/null
docker service scale --detach "${stack}_linux-java=0" > /dev/null

container_of() {  # container_of SERVICE: wait for a running container, print its ID
  local id
  for _ in $(seq 1 90); do
    id=$(docker ps -q --filter "label=com.docker.swarm.service.name=${stack}_$1" | head -n 1)
    if [ -n "${id}" ]; then echo "${id}"; return 0; fi
    sleep 2
  done
  return 1
}
# Wait until the entrypoint has finished its set-up and started the runner.
ready() {  # ready CONTAINER
  for _ in $(seq 1 60); do
    docker logs "$1" 2>&1 | grep -q 'circleci-runner-entrypoint: runner=' && return 0
    sleep 2
  done
  docker logs "$1" 2>&1 | tail -n 20
  return 1
}

for svc in linux-default linux-hardened; do
  cid=$(container_of "${svc}") || { printf 'CHECK %s-container FAIL (no running container)\n' "${svc}"; docker service ps "${stack}_${svc}" --no-trunc | head; failed=$((failed + 1)); continue; }
  check "${svc}-entrypoint-ready" ready "${cid}"
  docker logs "${cid}" 2>&1 | grep 'circleci-runner-entrypoint:' | cut -c1-200 | sed "s/^/    ${svc}: /"
  runner_user() { docker exec "${cid}" ps -o user= -C circleci-runner | head -n 1 | tr -d ' '; }
  check "${svc}-runner-user" test "$(runner_user)" = circleci-runner
  token_denied() { ! docker exec -u circleci "${cid}" sh -c 'cat /run/secrets/circleci_runner_config.yaml' > /dev/null 2>&1; }
  check "${svc}-token-unreadable-by-job-user" token_denied
  environ_foreign() {
    docker exec -u circleci "${cid}" sh -c 'n=0; me=$(id -u); for f in /proc/[0-9]*/environ; do [ "$(stat -c %u "$f" 2>/dev/null || echo "$me")" = "$me" ] && continue; head -c 1 "$f" >/dev/null 2>&1 && n=$((n+1)); done; echo $n'
  }
  check "${svc}-other-environments-unreadable" test "$(environ_foreign)" = 0
  if [ "${svc}" = linux-default ]; then
    check "${svc}-job-user-has-sudo" docker exec -u circleci "${cid}" sudo -n true
    sudo_reads() { docker exec -u circleci "${cid}" sudo -n sh -c 'test -s /run/secrets/circleci_runner_config.yaml'; }
    check "${svc}-sudo-can-read-token-documented" sudo_reads
  else
    no_sudo() { ! docker exec -u circleci "${cid}" sudo -n true > /dev/null 2>&1; }
    check "${svc}-job-user-has-no-sudo" no_sudo
  fi
done

echo "RESULT smoke arch=${arch} failed=${failed} verdict=$([ "${failed}" -eq 0 ] && echo PASS || echo FAIL)"
[ "${failed}" -eq 0 ]
