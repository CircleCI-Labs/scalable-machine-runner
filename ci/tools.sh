#!/usr/bin/env bash
# tools.sh: the tools that more than one CI script installs, each with its version and the SHA-256 value of its download. Source it, do not
# run it:
#
#   . ci/tools.sh
#   install_cosign     # cosign, which signs the release and the token proxy image
#   install_crane      # crane, which reads, tags and joins registry manifests without a Docker daemon
#
# They go to ${CI_TOOLS_BIN} (default ${RELEASE_BIN}, else ~/.local/bin), which the caller puts on PATH. A Renovate pull request changes
# a version only: put the new SHA-256 value next to it (docs/ci.md, "Pinned versions"). x86_64 Linux only, which every job that publishes is.

tools_bin="${CI_TOOLS_BIN:-${RELEASE_BIN:-${HOME}/.local/bin}}"

# fetch URL SHA256 FILE: download, and check the SHA-256 value
fetch() {
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet -
}

tools_check_platform() {
  [ "$(uname -m)" = x86_64 ] || { printf 'error: the tools install on x86_64 Linux only\n' >&2; return 1; }
  mkdir -p "${tools_bin}"
}

install_cosign() {
  tools_check_platform || return 1
  # renovate: datasource=github-releases depName=sigstore/cosign extractVersion=^v(?<version>.*)$
  local cosign_version=3.1.3
  local cosign_sha256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
  local tmp; tmp="$(mktemp -d)"
  fetch "https://github.com/sigstore/cosign/releases/download/v${cosign_version}/cosign-linux-amd64" "${cosign_sha256}" "${tmp}/cosign"
  install -m 0755 "${tmp}/cosign" "${tools_bin}/cosign"
  rm -rf "${tmp}"
}

install_crane() {
  tools_check_platform || return 1
  # renovate: datasource=github-releases depName=google/go-containerregistry extractVersion=^v(?<version>.*)$
  local crane_version=0.22.1
  local crane_sha256=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
  local tmp; tmp="$(mktemp -d)"
  fetch "https://github.com/google/go-containerregistry/releases/download/v${crane_version}/go-containerregistry_Linux_x86_64.tar.gz" \
    "${crane_sha256}" "${tmp}/crane.tar.gz"
  tar -xzf "${tmp}/crane.tar.gz" -C "${tmp}" crane
  install -m 0755 "${tmp}/crane" "${tools_bin}/crane"
  rm -rf "${tmp}"
}
