#!/usr/bin/env bash
# Shared helpers for the Swarm tests in linux/tests/. Source it; do not run it.
#
# The tests never switch this host's Docker engine into Swarm mode: a single-node Swarm (or, for the
# placement test, a manager plus a worker) runs inside privileged docker:dind containers, and every
# `docker` command below runs in them through `docker exec`. CI machine executors could run
# `docker swarm init` directly, but the same scripts work there too.
#
# Sessions: a test script run on its own starts and removes its own DinD containers. run-all.sh
# starts them once (images are large), exports SWARM_TEST_SESSION_ACTIVE=1 and the container names, and
# every test then only resets the inner Swarm (stack, secrets, containers) before it starts.
#
# Environment: SWARM_TEST_DIND_IMAGE (default docker:29-dind), SWARM_TEST_CIMG_IMAGE (default cimg/base:2026.10, the
# image of the stack's classes), SWARM_TEST_CACHE (default ~/.cache/swarm-tests: the real runner binary),
# SWARM_TEST_KEEP=1 (keep DinD containers for debugging).
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$tests_dir/../.." && pwd)
stack_dir=$repo_dir/linux/stack
DIND_IMAGE=${SWARM_TEST_DIND_IMAGE:-docker:29-dind}
CIMG_IMAGE=${SWARM_TEST_CIMG_IMAGE:-cimg/base:2026.10}
cache_dir=${SWARM_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/swarm-tests}
BASE_SERVICES=(linux-default linux-java linux-hardened)   # the services of runners.yaml
STACK=runners
SENTINEL_TOKEN=SENTINEL-TOKEN-0123456789abcdef

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# ---------------------------------------------------------------------------------------------
# Outcome helpers
# ---------------------------------------------------------------------------------------------
test_name=${test_name:-test}
pass() {
  echo "PASS ($*)"
  exit 0
}
fail() {
  echo "FAIL: $*"
  if declare -F diagnostics >/dev/null; then diagnostics || true; fi
  exit 1
}
# Wait up to $1 seconds for the command in the remaining arguments to succeed.
wait_for() {
  local timeout=$1 i
  shift
  for ((i = 0; i < timeout; i++)); do
    if "$@"; then return 0; fi
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------------------------------------
# DinD containers
# ---------------------------------------------------------------------------------------------
dind_containers=()
dind_networks=()

# docker command inside the inner engine of DinD container $1.
idocker() {
  local n=$1
  shift
  docker exec -i "$n" docker "$@"
}

# Start a privileged DinD container $1 (optionally on network $2) and wait for its engine.
dind_start() {
  local name=$1 net=${2:-} args=()
  [[ -z $net ]] || args+=(--network "$net")
  docker rm -f -v "$name" >/dev/null 2>&1 || true
  docker run -d --privileged --name "$name" --hostname "$name" -e DOCKER_TLS_CERTDIR= "${args[@]}" "$DIND_IMAGE" >/dev/null
  dind_containers+=("$name")
  wait_for 90 idocker "$name" info >/dev/null 2>&1 || fail "the engine in $name did not start"
}

# Make image $2 available in the inner engine of $1: the host's copy if there is one, else pull.
dind_load() {
  local name=$1 image=$2
  if idocker "$name" image inspect "$image" >/dev/null 2>&1; then return 0; fi
  if docker image inspect "$image" >/dev/null 2>&1; then
    log "loading $image into $name"
    docker save "$image" | idocker "$name" load -q >/dev/null
  else
    log "pulling $image in $name"
    idocker "$name" pull -q "$image" >/dev/null
  fi
}

dind_stop_all() {
  local c
  if [[ ${SWARM_TEST_KEEP:-} == 1 ]]; then return 0; fi
  for c in "${dind_containers[@]}"; do docker rm -f -v "$c" >/dev/null 2>&1 || true; done
  for c in "${dind_networks[@]}"; do docker network rm "$c" >/dev/null 2>&1 || true; done
}

# Remove everything a previous test left in the inner Swarm of $1.
inner_reset() {
  local n=$1 i
  idocker "$n" stack rm "$STACK" >/dev/null 2>&1 || true
  idocker "$n" service ls -q | xargs -r docker exec -i "$n" docker service rm >/dev/null 2>&1 || true   # jobs created by a test
  idocker "$n" config ls -q | xargs -r docker exec -i "$n" docker config rm >/dev/null 2>&1 || true
  for i in $(seq 1 60); do
    if [[ -z $(idocker "$n" network ls --format '{{.Name}}' | grep "^${STACK}_" || true) ]] &&
      [[ -z $(idocker "$n" ps -aq --filter "label=com.docker.swarm.service.name" || true) ]]; then break; fi
    sleep 1
  done
  idocker "$n" ps -aq | xargs -r docker exec -i "$n" docker rm -f >/dev/null 2>&1 || true
  idocker "$n" secret ls -q | xargs -r docker exec -i "$n" docker secret rm >/dev/null 2>&1 || true
  idocker "$n" volume ls -q | xargs -r docker exec -i "$n" docker volume rm >/dev/null 2>&1 || true
}

# session_begin [--worker]: one Swarm manager (and optionally a worker) with the CIMG image loaded.
# Sets SWARM_TEST_MGR (and SWARM_TEST_WRK). Registers cleanup.
session_begin() {
  local want_worker=false
  [[ ${1:-} == --worker ]] && want_worker=true
  work=$(mktemp -d)
  trap 'dind_stop_all; rm -rf "$work"' EXIT
  if [[ ${SWARM_TEST_SESSION_ACTIVE:-} == 1 ]] && { [[ $want_worker == false ]] || [[ -n ${SWARM_TEST_WRK:-} ]]; }; then
    inner_reset "$SWARM_TEST_MGR"
    if [[ -n ${SWARM_TEST_WRK:-} ]]; then
      # a worker cannot see the Swarm: only remove what ran on it
      idocker "$SWARM_TEST_WRK" ps -aq | xargs -r docker exec -i "$SWARM_TEST_WRK" docker rm -f >/dev/null 2>&1 || true
      idocker "$SWARM_TEST_WRK" volume ls -q | xargs -r docker exec -i "$SWARM_TEST_WRK" docker volume rm >/dev/null 2>&1 || true
      # only the placement test wants the worker; the others must not schedule tasks onto it
      idocker "$SWARM_TEST_MGR" node update --availability "$([[ $want_worker == true ]] && echo active || echo drain)" "$SWARM_TEST_WRK" >/dev/null
      idocker "$SWARM_TEST_MGR" node update --label-rm machine-runner-swarm.docker-build "$SWARM_TEST_WRK" >/dev/null 2>&1 || true
    fi
    idocker "$SWARM_TEST_MGR" node update --label-rm machine-runner-swarm.docker-build "$SWARM_TEST_MGR" >/dev/null 2>&1 || true
    return 0
  fi
  local id=$$ net
  SWARM_TEST_MGR=swarm-test-mgr-$id
  if [[ $want_worker == true ]]; then
    net=swarm-test-net-$id
    docker network create "$net" >/dev/null
    dind_networks+=("$net")
    SWARM_TEST_WRK=swarm-test-wrk-$id
    dind_start "$SWARM_TEST_MGR" "$net"
    dind_start "$SWARM_TEST_WRK" "$net"
    local ip token
    ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$SWARM_TEST_MGR")
    idocker "$SWARM_TEST_MGR" swarm init --advertise-addr "$ip" >/dev/null
    token=$(idocker "$SWARM_TEST_MGR" swarm join-token -q worker)
    idocker "$SWARM_TEST_WRK" swarm join --token "$token" "$ip:2377" >/dev/null
    dind_load "$SWARM_TEST_WRK" "$CIMG_IMAGE"
  else
    dind_start "$SWARM_TEST_MGR"
    idocker "$SWARM_TEST_MGR" swarm init --advertise-addr 127.0.0.1 >/dev/null
  fi
  dind_load "$SWARM_TEST_MGR" "$CIMG_IMAGE"
  idocker "$SWARM_TEST_MGR" swarm update --task-history-limit 20 >/dev/null
}

# ---------------------------------------------------------------------------------------------
# The real runner binary (installed by the real setup.sh in a throw-away root container)
# ---------------------------------------------------------------------------------------------
real_runner() {
  local bin=$cache_dir/circleci-runner cid
  if [[ -x $bin ]]; then
    echo "$bin"
    return
  fi
  log "installing the real runner with linux/setup.sh (cached in $cache_dir)"
  mkdir -p "$cache_dir"
  cid=$(docker create --user 0 -v "$repo_dir:/src:ro" "$CIMG_IMAGE" bash /src/linux/setup.sh --install)
  docker start -a "$cid" > "$cache_dir/install.log" 2>&1 || {
    cat "$cache_dir/install.log" >&2
    docker rm -f "$cid" >/dev/null
    fail "setup.sh --install failed"
  }
  docker cp "$cid:/opt/machine-runner-swarm/current/bin/circleci-runner" "$bin"
  docker rm -f "$cid" >/dev/null
  echo "$bin"
}

# install_swarm NODE real|fake [VERSION]: lay out /opt/machine-runner-swarm/<VERSION> in the DinD container NODE
# like linux/setup.sh does, and point /opt/machine-runner-swarm/current at it (the stack mounts that link).
# "fake" puts tests/fake-runner.sh where the runner goes; both modes add fake-job. VERSION (default 1.0.0) is
# what the version directory is called and what its VERSION file says; another call with another VERSION
# installs side by side and flips the link.
install_swarm() {
  local node=$1 kind=$2 version=${3:-1.0.0} stage
  stage=$(mktemp -d)
  mkdir -p "$stage/bin"
  cp "$repo_dir/linux/entrypoint/circleci-runner-entrypoint" "$stage/bin/circleci-runner-entrypoint"
  cp "$tests_dir/fake-job.sh" "$stage/bin/fake-job"
  echo "$version" > "$stage/VERSION"
  case $kind in
    real) cp "$(real_runner)" "$stage/bin/circleci-runner" ;;
    fake) cp "$tests_dir/fake-runner.sh" "$stage/bin/circleci-runner" ;;
    *) fail "install_swarm: unknown kind $kind" ;;
  esac
  docker exec "$node" sh -c "rm -rf /opt/machine-runner-swarm/$version && mkdir -p /opt/machine-runner-swarm/$version" >/dev/null
  tar -C "$stage" --owner=0 --group=0 --mode='u=rwx,go=rx' -cf - . | docker exec -i "$node" tar -C "/opt/machine-runner-swarm/$version" -xf -
  docker exec "$node" chmod 0755 /opt/machine-runner-swarm "/opt/machine-runner-swarm/$version" "/opt/machine-runner-swarm/$version/bin"
  flip_current "$node" "$version"
  rm -rf "$stage"
}

# flip_current NODE VERSION: the atomic flip that linux/setup.sh does (a new link, then a rename over the old one).
flip_current() {
  docker exec "$1" sh -c "cd /opt/machine-runner-swarm && ln -s $2 .current.new && mv -T .current.new current"
}

# ---------------------------------------------------------------------------------------------
# Stack deployment
# ---------------------------------------------------------------------------------------------
# The secret a service gets: a runner config holding only the token (the real format).
config_yaml() { printf 'api:\n  auth_token: %s\n' "$1"; }

# create_secrets NODE TOKEN SERVICE...: one <service>-token secret per service. TOKEN is a fake token
# (an empty one makes the runner exit 80).
create_secrets() {
  local node=$1 token=$2 s
  shift 2
  for s in "$@"; do
    config_yaml "$token" | idocker "$node" secret create "$s-token" - >/dev/null
  done
}

# make_override FILE SPEC...: write a compose override. SPEC = "service replicas [ENV=value ...]".
# Services of runners.yaml without a SPEC are scaled to 0; others (add-on stack files) only appear when given.
make_override() {
  local file=$1 spec s name replicas rest found kv
  local -a svcs=("${BASE_SERVICES[@]}")
  shift
  for spec in "$@"; do
    read -r name _ <<< "$spec"
    [[ " ${svcs[*]} " == *" $name "* ]] || svcs+=("$name")
  done
  {
    echo "services:"
    for s in "${svcs[@]}"; do
      found=
      rest=
      for spec in "$@"; do
        read -r name replicas rest <<< "$spec"
        [[ $name == "$s" ]] && found=1 && break
        rest=
      done
      echo "  $s:"
      echo "    deploy:"
      if [[ -n $found ]]; then echo "      replicas: $replicas"; else echo "      replicas: 0"; fi
      if [[ -n $found && -n ${rest:-} ]]; then
        echo "    environment:"
        for kv in $rest; do echo "      ${kv%%=*}: \"${kv#*=}\""; done
      fi
    done
  } > "$file"
}

# deploy_stack NODE OVERRIDE_FILE [STACK_FILE...]: copy the real stack file(s) (default runners.yaml) and
# OVERRIDE_FILE into NODE and deploy them. $SWARM_TEST_HOST replaces CHANGE-ME in persistent.yaml, the way
# its comment tells a user to edit it.
deploy_stack() {
  local node=$1 override=$2 f tmp
  local -a args=()
  shift 2
  [[ $# -gt 0 ]] || set -- runners.yaml
  tmp=$(mktemp -d)
  docker exec "$node" mkdir -p /stack
  for f in "$@"; do
    sed "s/CHANGE-ME/${SWARM_TEST_HOST:-CHANGE-ME}/" "$stack_dir/$f" > "$tmp/$f"
    docker cp "$tmp/$f" "$node:/stack/$f"
    args+=(-c "/stack/$f")
  done
  cp "$override" "$tmp/override.yaml"
  docker cp "$tmp/override.yaml" "$node:/stack/override.yaml"
  rm -rf "$tmp"
  idocker "$node" stack deploy --resolve-image never "${args[@]}" -c /stack/override.yaml "$STACK" >/dev/null 2>&1 ||
    idocker "$node" stack deploy --resolve-image never "${args[@]}" -c /stack/override.yaml "$STACK" >&2
}

# service_logs NODE SERVICE
service_logs() { idocker "$1" service logs --raw "${STACK}_$2" 2>&1 || true; }
# running_container NODE SERVICE: id of the first running container of a service on NODE
running_container() { idocker "$1" ps -q --filter "label=com.docker.swarm.service.name=${STACK}_$2" | head -n 1; }

# Print what a human would look at first. Tests set DIAG_NODES.
diagnostics() {
  local n
  for n in ${DIAG_NODES:-${SWARM_TEST_MGR:-}}; do
    echo "--- diagnostics on $n"
    idocker "$n" service ls 2>&1 | head -n 20
    idocker "$n" service ps --no-trunc "$STACK" 2>&1 | head -n 40 || true
    idocker "$n" service ls --format '{{.Name}}' | while read -r s; do
      idocker "$n" service logs --tail 15 "$s" 2>&1 | head -n 40 || true
    done
  done
}
