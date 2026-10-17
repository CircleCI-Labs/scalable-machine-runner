#!/usr/bin/env bash
# setup.sh: OPTIONAL helper for machine-runner-swarm on a Linux Docker Swarm host. Every step is an ordinary docker command
# that docs/install-linux.md shows by hand. The runner is not installed here: the runner-distributor service of the stack does that
# on every node (docs/operations.md).
set -euo pipefail

swarm_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

info() { printf '%s\n' "$*" >&2; }
die() { printf 'setup.sh: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: setup.sh [STEPS] [OPTIONS]    (no steps: --check; every step is idempotent)
Steps, run in this order:
  --check            preflight only: Linux, amd64/arm64/ppc64le/s390x, Docker running and 24+, Swarm state, clock
  --swarm-init       docker swarm init for one node (listens on 127.0.0.1 only) unless Swarm is active
  --secret SERVICE   create the Swarm secret SERVICE-token (a runner config holding the token); the token
                     comes from stdin (hidden prompt, or one line from a pipe), never printed
  --deploy           docker stack deploy of the --stack-file files (the runner-distributor service installs the runner)
Options:
  --stack-file FILE  stack file for --deploy, repeatable (default: stack/runners.yaml)
  --stack-name NAME  default: runners
The distributor reads MACHINE_RUNNER_SWARM_RUNNER_VERSION (an exact pin by default, or 3.1, 3, current), _RUNNER_MAJOR, _CHECK_INTERVAL,
_DOWNLOAD_BASE_URL and _RUNNER_SHA256 from the environment of --deploy (docs/operations.md). The token proxy is an image:
MACHINE_RUNNER_SWARM_PROXY_IMAGE names another one than the published default (docs/install-linux.md). It runs on a manager;
MACHINE_RUNNER_SWARM_PROXY_PLACEMENT pins it (docs/multi-node.md). --deploy prints a warning when the proxy image is not named by digest
(@sha256:...): a checkout names the tag latest, a release bundle names the digest of its release.
Every runner reads the placeholder secret: printf %s machine-runner-swarm-placeholder | setup.sh --secret runner-placeholder
EOF
}

preflight() { # NEEDS_DOCKER
  local bad=0 arch v
  chk() { printf '[%s] %s\n' "$1" "$2" >&2; [[ $1 != FAIL ]] || bad=1; }
  if [[ $(uname -s) == Linux ]]; then chk ' ok ' "Linux"; else chk FAIL "this helper is for Linux (Windows: windows/Setup.ps1)"; fi
  case $(uname -m) in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    ppc64le) arch=ppc64le ;;
    s390x) arch=s390x ;;
    *) arch= ;;
  esac
  if [[ -n $arch ]]; then chk ' ok ' "architecture $arch"; else chk FAIL "unsupported architecture $(uname -m): amd64, arm64, ppc64le and s390x only"; fi
  if v=$(docker version --format '{{.Server.Version}}' 2>/dev/null) && [[ -n $v ]]; then
    if [[ ${v%%.*} -ge 24 ]]; then chk ' ok ' "Docker Engine $v"; else chk FAIL "Docker Engine $v is too old: 24 or newer"; fi
    chk ' ok ' "Swarm: $(docker info --format '{{.Swarm.LocalNodeState}}')"
  elif [[ $1 == true ]]; then
    chk FAIL "cannot talk to the Docker daemon (installed, running, and are you root or in the docker group?)"
  else
    chk WARN "cannot talk to the Docker daemon"
  fi
  if command -v timedatectl >/dev/null && [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) != yes ]]; then
    chk WARN "the clock is not NTP-synchronised; TLS to CircleCI fails silently when it drifts"
  fi
  [[ $bad -eq 0 ]] || die "preflight failed"
}

swarm_init() {
  if [[ $(docker info --format '{{.Swarm.LocalNodeState}}') == active ]]; then info "[ ok ] Swarm is already active"; return; fi
  docker swarm init --advertise-addr 127.0.0.1 --listen-addr 127.0.0.1:2377 >/dev/null
  docker swarm update --task-history-limit 2 >/dev/null   # keep few stopped containers around
  info "[ ok ] Swarm initialised (single node, 127.0.0.1): a manager, so it also runs the token proxy"
}

# swarm_create_secret SERVICE: the secret is the runner config the runner reads with --config.
swarm_create_secret() {
  local name=$1-token token
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "service name must be lower case letters, digits and '-', got '$1'"
  if docker secret inspect "$name" >/dev/null 2>&1; then info "[ ok ] secret $name exists (unchanged; to rotate see the docs)"; return; fi
  if [[ -t 0 ]]; then read -r -s -p "Runner token for $1 (hidden): " token; echo >&2; else IFS= read -r token || true; fi
  [[ $token =~ ^[A-Za-z0-9._-]+$ ]] || die "no token on stdin, or it has unexpected characters"
  printf 'api:\n  auth_token: %s\n' "$token" | docker secret create "$name" - >/dev/null
  info "[ ok ] created secret $name"
}

# warn_unpinned_proxy_image FILE...: warn when the token proxy image that --deploy is about to use is not named by digest. The proxy holds
# every class token, and a tag can be moved to another image. The image is MACHINE_RUNNER_SWARM_PROXY_IMAGE or, when that is unset or
# empty, the default that the stack files name (a checkout: the tag latest; a release bundle: a version and a digest, so no warning). The
# warning does not stop the deploy. A stack file that does not read the variable is the operator's own, and is not judged.
warn_unpinned_proxy_image() {
  local image=${MACHINE_RUNNER_SWARM_PROXY_IMAGE:-} f
  if [[ -z $image ]]; then
    for f in "$@"; do
      image=$(sed -n 's/^[[:space:]]*image:[[:space:]]*\${MACHINE_RUNNER_SWARM_PROXY_IMAGE:-\([^}]*\)}.*$/\1/p' "$f" 2>/dev/null | head -n 1)
      [[ -z $image ]] || break
    done
    [[ -n $image ]] || return 0
  fi
  [[ $image =~ @sha256:[0-9a-f]{64}$ ]] && return 0
  info "[WARN] the token proxy image is not pinned by digest: $image"
  info "       The proxy holds every class token, and a tag can be moved to another image. Name the image you have checked, with its digest:"
  info "       MACHINE_RUNNER_SWARM_PROXY_IMAGE=ccilabs/machine-runner-swarm-proxy:<version>@sha256:<digest> $0 --deploy (docs/install-linux.md)."
  info "       A release bundle names the digest of its release in its stack file."
}

# next_steps STACK: the hint after every run names only what is still to do, from what Docker says now (swarm, secrets, stack)
next_steps() {
  local stack=$1 state todo=()
  state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)
  if [[ $state != active ]]; then
    todo+=("$0 --swarm-init")
  fi
  if [[ $state != active ]] || ! docker secret inspect linux-default-token >/dev/null 2>&1; then
    todo+=("printf %s \"\$TOKEN\" | $0 --secret linux-default")
  fi
  if [[ $state != active ]] || ! docker secret inspect runner-placeholder-token >/dev/null 2>&1; then
    todo+=("printf %s machine-runner-swarm-placeholder | $0 --secret runner-placeholder")
  fi
  if [[ $state != active ]] || ! docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$stack"; then
    todo+=("$0 --deploy")
  fi
  if [[ ${#todo[@]} -gt 0 ]]; then
    local out=${todo[0]} t
    for t in "${todo[@]:1}"; do out="$out; $t"; done
    info "Next: $out"
  else
    info "Check: docker service logs ${stack}_runner-distributor; docker stack ps ${stack} --no-trunc"
  fi
}

main() {
  local stack=runners check=false swarm=false deploy=false
  local -a secrets=() files=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --check) check=true ;;
      --swarm-init) swarm=true ;;
      --deploy) deploy=true ;;
      --secret | --stack-file | --stack-name)
        [[ $# -ge 2 ]] || die "$1 needs a value"
        case $1 in --secret) secrets+=("$2") ;; --stack-file) files+=("$2") ;; --stack-name) stack=$2 ;; esac
        shift
        ;;
      -h | --help) usage; return 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done
  [[ $check == true || $swarm == true || $deploy == true || ${#secrets[@]} -gt 0 ]] || check=true
  [[ ${#files[@]} -gt 0 ]] || files=("$swarm_dir/stack/runners.yaml")
  [[ ${#secrets[@]} -le 1 || -t 0 ]] || die "several --secret values need a terminal: stdin carries one token"

  preflight "$([[ $swarm == true || $deploy == true || ${#secrets[@]} -gt 0 ]] && echo true || echo false)"
  if [[ $swarm == true ]]; then swarm_init; fi
  for s in "${secrets[@]}"; do swarm_create_secret "$s"; done
  if [[ $deploy == true ]]; then
    local -a args=()
    for f in "${files[@]}"; do args+=(-c "$f"); done
    warn_unpinned_proxy_image "${files[@]}"
    docker stack deploy "${args[@]}" "$stack"
  fi
  next_steps "$stack"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
