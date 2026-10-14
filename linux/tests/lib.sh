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
# The runner reaches the nodes the way it does in production: the runner-distributor service of the stack downloads it. The tests
# point the distributor at a tiny HTTP mirror in the manager's DinD container (publish_runner: a manifest.json and the tarballs of
# the versions a test publishes, a fake runner or the real one), so no test depends on CircleCI's bucket except the ones that say so.
#
# Environment: SWARM_TEST_DIND_IMAGE (default docker:29-dind), SWARM_TEST_CIMG_IMAGE (default cimg/base:2026.10, the
# image of the stack's classes), SWARM_TEST_CACHE (default ~/.cache/swarm-tests: the real runner tarballs),
# SWARM_TEST_RUNNER_VERSION (default: the exact pin that runners.yaml ships, so that the version the stack installs by default is the
# one that CI tests; the real runner of the tests), SWARM_TEST_KEEP=1 (keep DinD containers for debugging).
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$tests_dir/../.." && pwd)
stack_dir=$repo_dir/linux/stack
DIND_IMAGE=${SWARM_TEST_DIND_IMAGE:-docker:29-dind}
CIMG_IMAGE=${SWARM_TEST_CIMG_IMAGE:-cimg/base:2026.10}
cache_dir=${SWARM_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/swarm-tests}
BASE_SERVICES=(linux-default linux-java linux-hardened)   # the runner classes of runners.yaml (runner-distributor is the other service)
# shellcheck disable=SC2016  # the pattern holds a literal ${...}
STACK_RUNNER_PIN=$(sed -n 's/^  MACHINE_RUNNER_SWARM_RUNNER_VERSION: \${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-\([0-9][0-9.]*\)}.*/\1/p' "$stack_dir/runners.yaml")
TEST_RUNNER_VERSION=${SWARM_TEST_RUNNER_VERSION:-$STACK_RUNNER_PIN}
REAL_BASE_URL=https://circleci-binary-releases.s3.amazonaws.com/circleci-runner
case $(uname -m) in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; *) ARCH=unsupported ;; esac
MIRROR_PORT=8098
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

# stack_down NODE: remove the stack and wait until its containers and networks are gone (its volumes stay)
stack_down() {
  local n=$1 i
  idocker "$n" stack rm "$STACK" >/dev/null 2>&1 || true
  idocker "$n" service ls -q | xargs -r docker exec -i "$n" docker service rm >/dev/null 2>&1 || true   # jobs created by a test
  for i in $(seq 1 60); do
    if [[ -z $(idocker "$n" network ls --format '{{.Name}}' | grep "^${STACK}_" || true) ]] &&
      [[ -z $(idocker "$n" ps -aq --filter "label=com.docker.swarm.service.name" || true) ]]; then break; fi
    sleep 1
  done
}

# Remove everything a previous test left in the inner Swarm of $1.
inner_reset() {
  local n=$1
  stack_down "$n"
  idocker "$n" config ls -q | xargs -r docker exec -i "$n" docker config rm >/dev/null 2>&1 || true
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
# The runner: real tarballs (cached), fake ones, and the mirror that serves them to the distributor
# ---------------------------------------------------------------------------------------------
# real_tarball VERSION: the path of the real circleci-runner_linux_<arch>.tar.gz of that release, downloaded once and checked against
# the SHA-256 of CircleCI's own manifest (the same trust as the distributor's).
real_tarball() {
  local v=$1 tgz=$cache_dir/circleci-runner-$1-$ARCH.tar.gz want
  if [[ -f $tgz ]]; then
    echo "$tgz"
    return
  fi
  log "downloading the real runner $v ($ARCH, cached in $cache_dir)"
  mkdir -p "$cache_dir"
  want=$(curl -fsSL "$REAL_BASE_URL/manifest.json" | python3 -c "import json,sys; print(json.load(sys.stdin)['releases']['$v']['linux']['$ARCH']['sha256'])") ||
    fail "the manifest of $REAL_BASE_URL has no runner $v for $ARCH"
  curl -fsSL -o "$tgz.part" "$REAL_BASE_URL/$v/circleci-runner_linux_$ARCH.tar.gz" || fail "cannot download the real runner $v"
  [[ $(sha256sum "$tgz.part" | cut -d' ' -f1) == "$want" ]] || { rm -f "$tgz.part"; fail "the real runner $v does not match the SHA-256 of the manifest"; }
  mv "$tgz.part" "$tgz"
  echo "$tgz"
}

# real_runner [VERSION]: the real runner binary, extracted from its tarball
real_runner() {
  local v=${1:-$TEST_RUNNER_VERSION} bin tgz
  bin=$cache_dir/circleci-runner-$v-$ARCH
  if [[ ! -x $bin ]]; then
    tgz=$(real_tarball "$v")
    tar -xzOf "$tgz" circleci-runner > "$bin.part"
    chmod 0755 "$bin.part"
    mv "$bin.part" "$bin"
  fi
  echo "$bin"
}

mirror_versions=()   # the versions published so far (the manifest lists them all)
MIRROR_CURRENT=      # the version that the manifest's "current" entry names

# mirror_start: the HTTP mirror, a python server in a stock image in the manager's inner engine, serving /mirror of that container
mirror_start() {
  local mgr=${SWARM_TEST_MGR:?}
  if [[ -n $(idocker "$mgr" ps -q --filter name=^mirror\$) ]]; then return 0; fi
  docker exec "$mgr" mkdir -p /mirror
  idocker "$mgr" rm -f mirror >/dev/null 2>&1 || true
  idocker "$mgr" run -d --name mirror --network host -v /mirror:/mirror:ro "$CIMG_IMAGE" python3 -m http.server "$MIRROR_PORT" --directory /mirror >/dev/null
  MIRROR_URL=http://$(docker exec "$mgr" hostname -i | awk '{ print $1 }'):$MIRROR_PORT
  wait_for 30 docker exec "$mgr" docker run --rm --network host "$CIMG_IMAGE" curl -fsS "http://127.0.0.1:$MIRROR_PORT/" >/dev/null 2>&1 || fail "the mirror did not start"
}

# mirror_manifest [CURRENT]: write manifest.json for the published versions into /mirror: a version entry for each, current (default:
# the newest published) and edge, with the SHA-256 of the tarballs, in the layout of CircleCI's manifest.
mirror_manifest() {
  local cur=${1:-${MIRROR_CURRENT:-}}
  [[ -n $cur ]] || cur=${mirror_versions[-1]}
  MIRROR_CURRENT=$cur
  python3 - "$work/mirror" "$ARCH" "$MIRROR_URL" "$cur" "${mirror_versions[@]}" <<'PY'
import hashlib, json, sys
root, arch, url, cur, *versions = sys.argv[1:]
def entry(d):
    name = "circleci-runner_linux_%s.tar.gz" % arch
    with open("%s/%s/%s" % (root, d, name), "rb") as f:
        return {"linux": {arch: {"sha256": hashlib.sha256(f.read()).hexdigest(), "url": "%s/%s/%s" % (url, d, name)}}}
releases = {v: entry(v) for v in versions}
releases["current"] = entry(cur)
releases["edge"] = entry(cur)
with open(root + "/manifest.json", "w") as f:
    json.dump({"releases": releases}, f, indent=2)
PY
  docker cp "$work/mirror/." "${SWARM_TEST_MGR}:/mirror/" >/dev/null
}

# publish_runner KIND [VERSION [CURRENT]]: put the runner of that VERSION on the mirror (KIND real: the real release of that version, fake:
# tests/fake-runner.sh as that version; default VERSION: the real runner of the tests for real, 1.0.0 for fake), make the distributor of the
# stack pin it (or, with a third argument, set the manifest's current to CURRENT and leave the distributor on "current"), and write the manifest.
# A second call adds another version next to the first. Sets DIST_VERSION for make_override.
publish_runner() {
  local kind=$1 v=${2:-} cur=${3:-} dir stage
  case $kind in real) v=${v:-$TEST_RUNNER_VERSION} ;; fake) v=${v:-1.0.0} ;; *) fail "publish_runner: unknown kind $kind" ;; esac
  [[ $ARCH != unsupported ]] || fail "unsupported host architecture $(uname -m)"
  mkdir -p "$work/mirror"
  mirror_start
  dir=$work/mirror/$v
  mkdir -p "$dir"
  if [[ $kind == real ]]; then
    cp "$(real_tarball "$v")" "$dir/circleci-runner_linux_$ARCH.tar.gz"
  else
    stage=$(mktemp -d)
    sed "s/@VERSION@/$v/" "$tests_dir/fake-runner.sh" > "$stage/circleci-runner"
    chmod 0755 "$stage/circleci-runner"
    tar -C "$stage" -czf "$dir/circleci-runner_linux_$ARCH.tar.gz" circleci-runner
    rm -rf "$stage"
  fi
  [[ " ${mirror_versions[*]:-} " == *" $v "* ]] || mirror_versions+=("$v")
  DIST_VERSION=$v
  [[ -z $cur ]] || DIST_VERSION=current
  mirror_manifest "${cur:-$v}"
  PUBLISHED_SHA[$v]=$(sha256sum "$dir/circleci-runner_linux_$ARCH.tar.gz" | cut -d' ' -f1)
}
# publish_proxy [VERSION]: build the token proxy from proxy/ (ci/build-proxy.sh, reporting VERSION, default 0.0.1-test) and put it on the mirror
# as a GitHub release would have it: proxy/v<VERSION>/machine-runner-swarm-proxy_linux_<arch> and proxy/v<VERSION>/SHA256SUMS, and proxy/latest.json,
# what the latest-release URL of GitHub answers (the tag of the release that "unreleased" means). The distributor of the stack installs it from
# there (make_override sets PROXY_VERSION). Sets PROXY_VERSION and PROXY_SHA.
publish_proxy() {
  local v=${1:-0.0.1-test} dir
  [[ $ARCH != unsupported ]] || fail "unsupported host architecture $(uname -m)"
  mkdir -p "$work/mirror"
  mirror_start
  dir=$work/mirror/proxy/v$v
  mkdir -p "$dir"
  "$repo_dir/ci/build-proxy.sh" "$dir" "$v" "linux/$ARCH" >&2
  PROXY_SHA=$(sha256sum "$dir/machine-runner-swarm-proxy_linux_$ARCH" | cut -d' ' -f1)
  {
    echo "0000000000000000000000000000000000000000000000000000000000000000  machine-runner-swarm-proxy_windows_amd64"
    echo "$PROXY_SHA  machine-runner-swarm-proxy_linux_$ARCH"
    echo "1111111111111111111111111111111111111111111111111111111111111111  machine-runner-swarm-proxy_linux_other"
  } > "$dir/SHA256SUMS"
  printf '{\n  "url": "https://api.github.com/repos/example/example/releases/1",\n  "tag_name": "v%s",\n  "name": "v%s",\n  "draft": false,\n  "prerelease": false\n}\n' "$v" "$v" > "$work/mirror/proxy/latest.json"
  PROXY_VERSION=$v
  docker cp "$work/mirror/." "${SWARM_TEST_MGR}:/mirror/" >/dev/null
}
PROXY_VERSION=
PROXY_SHA=
declare -gA PUBLISHED_SHA=()   # version -> SHA-256 of the tarball that the mirror serves

# ---------------------------------------------------------------------------------------------
# Stack deployment
# ---------------------------------------------------------------------------------------------
# The secret a service gets: a runner config holding only the token (the real format).
config_yaml() { printf 'api:\n  auth_token: %s\n' "$1"; }

# create_secrets NODE TOKEN SERVICE...: one <service>-token secret per service (the class tokens, which the token proxy mounts) and
# runner-placeholder-token (the config of every proxied runner). TOKEN is a fake token for all of them (an empty one makes the runner
# exit 80). A test that runs runners without the proxy reads the runner's config file, so the placeholder holds TOKEN.
create_secrets() {
  local node=$1 token=$2 s
  shift 2
  for s in "$@"; do
    config_yaml "$token" | idocker "$node" secret create "$s-token" - >/dev/null
  done
  config_yaml "$token" | idocker "$node" secret create runner-placeholder-token - >/dev/null
}

# make_override FILE SPEC...: write a compose override. SPEC = "service replicas [ENV=value ...]".
# Services of runners.yaml without a SPEC are scaled to 0, token-proxy among them; others (add-on stack files) only appear when given. The
# runner-distributor service always gets the settings of the last publish_runner (the mirror and the version to install), and
# the variables of the array DIST_ENV (KEY=value) on top, e.g. MACHINE_RUNNER_SWARM_CHECK_INTERVAL.
make_override() {
  local file=$1 spec s name replicas rest found kv
  local -a svcs=("${BASE_SERVICES[@]}" token-proxy)
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
    if [[ -n ${DIST_VERSION:-} ]]; then
      echo "  runner-distributor:"
      echo "    environment:"
      echo "      MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL: \"$MIRROR_URL\""
      echo "      MACHINE_RUNNER_SWARM_RUNNER_VERSION: \"$DIST_VERSION\""
      if [[ -n ${PROXY_VERSION:-} ]]; then   # publish_proxy: the proxy the distributor installs, from the mirror
        echo "      MACHINE_RUNNER_SWARM_PROXY_VERSION: \"$PROXY_VERSION\""
        echo "      MACHINE_RUNNER_SWARM_PROXY_BASE_URL: \"$MIRROR_URL/proxy\""
      fi
      for kv in "${DIST_ENV[@]:-}"; do [[ -z $kv ]] || echo "      ${kv%%=*}: \"${kv#*=}\""; done
      # DIST_HOLD=1: no node matches, so the distributor does not run (a first deployment before the runner is there)
      [[ -z ${DIST_HOLD:-} ]] || printf '    deploy:\n      placement:\n        constraints: ["node.labels.hold == yes"]\n'
    fi
  } > "$file"
}
DIST_ENV=()

# deploy_stack NODE OVERRIDE_FILE [STACK_FILE...]: copy the real stack file(s) (default runners.yaml) and
# OVERRIDE_FILE into NODE and deploy them, then the files of EXTRA_OVERRIDES (absolute paths) after the override. $SWARM_TEST_HOST replaces CHANGE-ME in persistent.yaml, the way
# its comment tells a user to edit it.
deploy_stack() {
  local node=$1 override=$2 f tmp
  local -a args=() extra=()
  shift 2
  [[ $# -gt 0 ]] || set -- runners.yaml
  tmp=$(mktemp -d)
  [[ -z ${DIST_VERSION:-} ]] || mirror_start   # a reset of the Swarm removes it
  docker exec "$node" mkdir -p /stack
  # the stack files name the entrypoint and the distributor script relative to themselves: they sit next to the stack files
  docker cp "$stack_dir/circleci-runner-entrypoint" "$node:/stack/circleci-runner-entrypoint"
  docker cp "$stack_dir/runner-distributor.sh" "$node:/stack/runner-distributor.sh"
  docker cp "$stack_dir/proxy-entrypoint.sh" "$node:/stack/proxy-entrypoint.sh"
  for f in "$@"; do
    sed "s/CHANGE-ME/${SWARM_TEST_HOST:-CHANGE-ME}/" "$stack_dir/$f" > "$tmp/$f"
    docker cp "$tmp/$f" "$node:/stack/$f"
    args+=(-c "/stack/$f")
  done
  cp "$override" "$tmp/override.yaml"
  docker cp "$tmp/override.yaml" "$node:/stack/override.yaml"
  rm -rf "$tmp"
  for f in ${EXTRA_OVERRIDES:-}; do
    docker cp "$f" "$node:/stack/${f##*/}"
    extra+=(-c "/stack/${f##*/}")
  done
  idocker "$node" stack deploy --resolve-image never "${args[@]}" -c /stack/override.yaml "${extra[@]}" "$STACK" >/dev/null 2>&1 ||
    idocker "$node" stack deploy --resolve-image never "${args[@]}" -c /stack/override.yaml "${extra[@]}" "$STACK" >&2
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
