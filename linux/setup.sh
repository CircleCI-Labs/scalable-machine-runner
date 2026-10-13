#!/usr/bin/env bash
# setup.sh: OPTIONAL helper for scalable-machine-runner on a Linux Docker Swarm host. Every step is an
# ordinary command that the docs show by hand. It can also be sourced to call smr_install_runner alone:
#   . linux/setup.sh && smr_install_runner 3.1.12 /opt/smr
set -euo pipefail

SMR_VERSION=3.1.12
# SHA-256 of circleci-runner_linux_<arch>.tar.gz for SMR_VERSION, from the release's checksums.txt.
SMR_SHA256_AMD64=d97cb1cde2b596a57be0b62b59e22ed361e4c9a3178ea8a0473c733a38393c0c
SMR_SHA256_ARM64=429d3f996a64f561a58e9cabf6260318d13d9af2f214afbcb073365aef872edd
# An https mirror for an air-gapped host; layout: <base>/<version>/circleci-runner_linux_<arch>.tar.gz
SMR_DOWNLOAD_BASE_URL=${SMR_DOWNLOAD_BASE_URL:-https://circleci-binary-releases.s3.amazonaws.com/circleci-runner}
smr_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

info() { printf '%s\n' "$*" >&2; }
die() { printf 'setup.sh: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: setup.sh [STEPS] [OPTIONS]    (no steps: --check --install; every step is idempotent)
Steps, run in this order:
  --check            preflight only: Linux, amd64/arm64, Docker running and 24+, Swarm state, clock
  --swarm-init       docker swarm init for one node (listens on 127.0.0.1 only) unless Swarm is active
  --install          download, verify and install the runner and smr-entrypoint into --prefix (root)
  --secret SERVICE   create the Swarm secret SERVICE-token (a runner config holding the token); the token
                     comes from stdin (hidden prompt, or one line from a pipe), never printed
  --deploy           docker stack deploy of the --stack-file files
Options:
  --version X.Y.Z    runner version (default 3.1.12, SHA-256 pinned here; others need --sha256)
  --sha256 HEX       expected SHA-256 of the tarball, from that release's checksums.txt
  --prefix DIR       install directory (default /opt/smr)
  --stack-file FILE  stack file for --deploy, repeatable (default: stack/runners.yaml)
  --stack-name NAME  default: smr
EOF
}

smr_arch() {
  case $(uname -m) in x86_64 | amd64) echo amd64 ;; aarch64 | arm64) echo arm64 ;; *) return 1 ;; esac
}

preflight() { # NEEDS_DOCKER
  local bad=0 arch v t
  chk() { printf '[%s] %s\n' "$1" "$2" >&2; [[ $1 != FAIL ]] || bad=1; }
  if [[ $(uname -s) == Linux ]]; then chk ' ok ' "Linux"; else chk FAIL "this helper is for Linux (Windows: windows/Setup.ps1)"; fi
  if arch=$(smr_arch); then chk ' ok ' "architecture $arch"; else chk FAIL "unsupported architecture $(uname -m): amd64 and arm64 only"; fi
  for t in curl tar sha256sum install; do command -v "$t" >/dev/null || chk FAIL "$t is required"; done
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

# smr_install_runner [VERSION [PREFIX [SHA256]]]: download circleci-runner for this architecture, verify the
# SHA-256 and --version, and install it with smr-entrypoint into PREFIX/bin, root-owned and not writable by
# anyone else. Skips the download when PREFIX already holds that version. Runs in a subshell, so a failure
# returns non-zero instead of exiting a shell that sourced this file.
smr_install_runner() (
  set -euo pipefail
  local version=${1:-$SMR_VERSION} prefix=${2:-/opt/smr} sha=${3:-} arch tarball tmp
  put() { install -m 0755 -o root -g root "$1" "$2.new" && mv -f "$2.new" "$2"; }
  [[ $(id -u) -eq 0 ]] || die "installing into $prefix needs root: run with sudo"
  [[ -f $smr_dir/entrypoint/smr-entrypoint ]] || die "run setup.sh from a checkout: entrypoint/smr-entrypoint not found"
  arch=$(smr_arch) || die "unsupported architecture $(uname -m)"
  tarball=circleci-runner_linux_$arch.tar.gz
  install -d -m 0755 -o root -g root "$prefix" "$prefix/bin"
  if ! "$prefix/bin/circleci-runner" --version 2>&1 | grep -qF "version $version"; then
    if [[ -z $sha ]]; then
      [[ $version == "$SMR_VERSION" ]] || die "no pinned SHA-256 for $version: pass --sha256 (see $SMR_DOWNLOAD_BASE_URL/$version/checksums.txt)"
      if [[ $arch == amd64 ]]; then sha=$SMR_SHA256_AMD64; else sha=$SMR_SHA256_ARM64; fi
    fi
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    info "downloading circleci-runner $version linux/$arch"
    curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -o "$tmp/$tarball" "$SMR_DOWNLOAD_BASE_URL/$version/$tarball" || die "download failed"
    (cd "$tmp" && echo "$sha  $tarball" | sha256sum -c - >/dev/null 2>&1) || die "SHA-256 mismatch for $tarball: refusing to install"
    tar -xzf "$tmp/$tarball" -C "$tmp" --no-same-owner circleci-runner
    "$tmp/circleci-runner" --version 2>&1 | grep -qF "version $version" || die "the downloaded binary does not report version $version"
    put "$tmp/circleci-runner" "$prefix/bin/circleci-runner"
  fi
  put "$smr_dir/entrypoint/smr-entrypoint" "$prefix/bin/smr-entrypoint"
  echo "$version" > "$prefix/VERSION"
  [[ -z $(find "$prefix" ! -user root -o -perm /022) ]] || die "$prefix has files that are not root-owned or are group/world-writable"
  info "[ ok ] $prefix/bin: $("$prefix/bin/circleci-runner" --version | head -n 1), and smr-entrypoint"
)

smr_swarm_init() {
  if [[ $(docker info --format '{{.Swarm.LocalNodeState}}') == active ]]; then info "[ ok ] Swarm is already active"; return; fi
  docker swarm init --advertise-addr 127.0.0.1 --listen-addr 127.0.0.1:2377 >/dev/null
  docker swarm update --task-history-limit 2 >/dev/null   # keep few stopped containers around
  info "[ ok ] Swarm initialised (single node, 127.0.0.1)"
}

# smr_create_secret SERVICE: the secret is the runner config the runner reads with --config.
smr_create_secret() {
  local name=$1-token token
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "service name must be lower case letters, digits and '-', got '$1'"
  if docker secret inspect "$name" >/dev/null 2>&1; then info "[ ok ] secret $name exists (unchanged; to rotate see the docs)"; return; fi
  if [[ -t 0 ]]; then read -r -s -p "Runner token for $1 (hidden): " token; echo >&2; else IFS= read -r token || true; fi
  [[ $token =~ ^[A-Za-z0-9._-]+$ ]] || die "no token on stdin, or it has unexpected characters"
  printf 'api:\n  auth_token: %s\n' "$token" | docker secret create "$name" - >/dev/null
  info "[ ok ] created secret $name"
}

main() {
  local version=$SMR_VERSION sha='' prefix=/opt/smr stack=smr check=false install=false swarm=false deploy=false
  local -a secrets=() files=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --check) check=true ;;
      --install) install=true ;;
      --swarm-init) swarm=true ;;
      --deploy) deploy=true ;;
      --secret | --version | --sha256 | --prefix | --stack-file | --stack-name)
        [[ $# -ge 2 ]] || die "$1 needs a value"
        case $1 in
          --secret) secrets+=("$2") ;; --version) version=$2 ;; --sha256) sha=$2 ;;
          --prefix) prefix=$2 ;; --stack-file) files+=("$2") ;; --stack-name) stack=$2 ;;
        esac
        shift
        ;;
      -h | --help) usage; return 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done
  [[ $check == true || $install == true || $swarm == true || $deploy == true || ${#secrets[@]} -gt 0 ]] || { check=true; install=true; }
  [[ ${#files[@]} -gt 0 ]] || files=("$smr_dir/stack/runners.yaml")
  [[ ${#secrets[@]} -le 1 || -t 0 ]] || die "several --secret values need a terminal: stdin carries one token"

  preflight "$([[ $swarm == true || $deploy == true || ${#secrets[@]} -gt 0 ]] && echo true || echo false)"
  if [[ $swarm == true ]]; then smr_swarm_init; fi
  if [[ $install == true ]]; then smr_install_runner "$version" "$prefix" "$sha"; fi
  for s in "${secrets[@]}"; do smr_create_secret "$s"; done
  if [[ $deploy == true ]]; then
    local -a args=()
    for f in "${files[@]}"; do args+=(-c "$f"); done
    docker stack deploy "${args[@]}" "$stack"
  fi
  info "Next: sudo $0 --install (every runner node); $0 --swarm-init; printf %s \"\$TOKEN\" | $0 --secret linux-default; $0 --deploy"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
