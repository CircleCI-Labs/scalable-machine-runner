#!/usr/bin/env bash
# The release job of this repository (docs/releasing.md).
#
#   ci/release.sh install-tools   install git-cliff, cosign, gh and Go (pinned, SHA-256 checked)
#   ci/release.sh                 version, notes, bundle, proxy binaries, SHA256SUMS, signature, then publish
#
# From the Conventional Commits since the last tag it computes the next version (cliff.toml),
# checks that every Swarm config of the stack files is named after its content (ci/config-names.sh) and that the exact runner
# version that the stack files pin (MACHINE_RUNNER_SWARM_RUNNER_VERSION, the newest one that CI tests) is in CircleCI's manifest
# for every platform,
# builds the bundle from the tracked files, with the token proxy version of the stack files pinned to the
# release it cuts (MACHINE_RUNNER_SWARM_PROXY_VERSION: ${...:-unreleased} becomes ${...:-<version>}), and the token proxy
# binaries (ci/build-proxy.sh: every platform of CircleCI's runner manifest, linux amd64, arm64, ppc64le and s390x and windows amd64 and
# arm64, named machine-runner-swarm-proxy_<os>_<arch>),
# signs SHA256SUMS, which lists the bundles and the binaries, with cosign (keyless: the CircleCI OIDC token) and checks
# the signature, then creates the GitHub release, which also creates the tag. The distributor of the stack downloads
# the proxy from that release. It never pushes a commit or a tag with git.
#
# Environment:
#   GITHUB_TOKEN          from the context scalable-machine-runner-release. Without it every
#                         step runs except the last one.
#   PIPELINE_DEFINITION_ID  the pipeline definition (<< pipeline.definition.id >>), for the
#                         certificate identity that the signature is checked against
#   RELEASE_SKIP_SIGN=1   for a run outside CircleCI, where there is no OIDC token
#   RELEASE_OUT           output directory (default /tmp/release)
#
# Never run this with `set -x`: the OIDC token and GITHUB_TOKEN are in the environment.
set -euo pipefail

out="${RELEASE_OUT:-/tmp/release}"
bin="${RELEASE_BIN:-${HOME}/.local/bin}"
tag_glob='v[0-9]*.[0-9]*.[0-9]*'
oidc_issuer='https://oidc.circleci.com'
goroot="${RELEASE_GOROOT:-${HOME}/.local/go}"
export PATH="${goroot}/bin:${bin}:${PATH}"
proxy_assets=()   # the file names of the proxy builds: set in main, from ci/build-proxy.sh, which builds them

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

install_tools() {
  [ "$(uname -m)" = x86_64 ] || die "install-tools supports x86_64 Linux only"
  # Each tool: its version and the SHA-256 value of its download, which Renovate cannot compute. A Renovate pull request
  # changes the version only: put the new value next to it (docs/releasing.md, "Pinned tools").
  # renovate: datasource=github-releases depName=orhun/git-cliff extractVersion=^v(?<version>.*)$
  local git_cliff_version=2.14.2
  local git_cliff_sha256=24f397c733add5390fdceee3a2088588ab0d5f944ce00d34cb7029b888cf2db4
  # renovate: datasource=github-releases depName=sigstore/cosign extractVersion=^v(?<version>.*)$
  local cosign_version=3.1.3
  local cosign_sha256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
  # renovate: datasource=github-releases depName=cli/cli extractVersion=^v(?<version>.*)$
  local gh_version=2.102.0
  local gh_sha256=bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386
  # renovate: datasource=golang-version depName=go
  local go_version=1.27.2
  local go_sha256=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5
  local tmp; tmp="$(mktemp -d)"
  fetch() { # url sha256 file
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$3" "$1"
    echo "$2  $3" | sha256sum -c --quiet -
  }
  mkdir -p "${bin}"
  fetch "https://github.com/orhun/git-cliff/releases/download/v${git_cliff_version}/git-cliff-${git_cliff_version}-x86_64-unknown-linux-gnu.tar.gz" \
    "${git_cliff_sha256}" "${tmp}/git-cliff.tar.gz"
  tar -xzf "${tmp}/git-cliff.tar.gz" -C "${tmp}"
  install -m 0755 "${tmp}/git-cliff-${git_cliff_version}/git-cliff" "${bin}/git-cliff"
  fetch "https://github.com/sigstore/cosign/releases/download/v${cosign_version}/cosign-linux-amd64" \
    "${cosign_sha256}" "${tmp}/cosign"
  install -m 0755 "${tmp}/cosign" "${bin}/cosign"
  fetch "https://github.com/cli/cli/releases/download/v${gh_version}/gh_${gh_version}_linux_amd64.tar.gz" \
    "${gh_sha256}" "${tmp}/gh.tar.gz"
  tar -xzf "${tmp}/gh.tar.gz" -C "${tmp}"
  install -m 0755 "${tmp}/gh_${gh_version}_linux_amd64/bin/gh" "${bin}/gh"
  fetch "https://go.dev/dl/go${go_version}.linux-amd64.tar.gz" \
    "${go_sha256}" "${tmp}/go.tar.gz"
  rm -rf "${goroot}"; mkdir -p "${goroot}"
  tar -xzf "${tmp}/go.tar.gz" -C "${goroot}" --strip-components=1
  rm -rf "${tmp}"
  git cliff --version; cosign version 2>&1 | grep -E '^GitVersion'; gh --version | head -n 1; go version
}

# The stack files pin one exact runner version by default, the newest that CI tests (docs/releasing.md says how a release bumps it).
# It must be the same in every stack file, and CircleCI's manifest must still list it for every platform that the stack runs on.
check_runner_pin() {
  local f pin first=
  for f in linux/stack/runners.yaml linux/stack/microvm.yaml windows/stack/runners.yaml; do
    pin="$(sed -n 's/^  MACHINE_RUNNER_SWARM_RUNNER_VERSION: \${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-\([0-9][0-9.]*\)}.*/\1/p' "${f}")"
    [ -n "${pin}" ] || die "${f} has no exact default of MACHINE_RUNNER_SWARM_RUNNER_VERSION"
    [ -z "${first}" ] || [ "${pin}" = "${first}" ] || die "${f} pins runner ${pin}, another stack file pins ${first}: they must be equal"
    first="${pin}"
  done
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/manifest.json |
    python3 -c '
import json, sys
pin = sys.argv[1]
entry = json.load(sys.stdin)["releases"].get(pin)
want = {"linux": ["amd64", "arm64", "ppc64le", "s390x"], "windows": ["amd64", "arm64"]}
missing = [o + "/" + a for o, archs in want.items() for a in archs if not (entry or {}).get(o, {}).get(a, {}).get("sha256")]
if missing:
    sys.exit("runner " + pin + " is not in the manifest of CircleCI for " + ", ".join(missing))
' "${first}" || die "the pinned runner ${first} is not usable: bump it (docs/releasing.md)"
  say "Runner pin ${first}: in CircleCI's manifest for every platform"
}

# Sets $version, $resume (true when this commit already has its release tag) or exits 0.
choose_version() {
  say "Tags and history"
  if git remote | grep -qx origin; then
    [ "$(git rev-parse --is-shallow-repository)" = false ] || git fetch --quiet --unshallow origin
    git fetch --quiet --force --tags origin
  fi
  local here later last
  here="$(git tag --points-at HEAD --list "${tag_glob}" --sort=-v:refname | sed -n 1p)"
  later="$(git tag --contains HEAD --list "${tag_glob}" --sort=-v:refname | sed -n 1p)"
  resume=false
  if [ -n "${here}" ]; then
    version="${here}"; resume=true
    say "This commit is already tagged ${version}: finishing that release"
  elif [ -n "${later}" ]; then
    say "This commit is already part of ${later}: nothing to release"; exit 0
  else
    last="$(git describe --tags --abbrev=0 --match "${tag_glob}" 2>/dev/null || true)"
    version="$(git cliff --bumped-version)"
    if [ "${version}" = "${last}" ]; then
      say "Nothing to release since ${last}: no feat, fix, perf or breaking commit"; exit 0
    fi
    say "Last release: ${last:-none}. Next release: ${version}"
  fi
  [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected version '${version}'"
}

build() {
  local fmt
  say "Notes and CHANGELOG.md for ${version}"
  if [ "${resume}" = true ]; then
    git cliff --current --strip header > "${out}/notes.md"
    git cliff > "${out}/CHANGELOG.md"
  else
    git cliff --unreleased --tag "${version}" --strip header > "${out}/notes.md"
    git cliff --tag "${version}" > "${out}/CHANGELOG.md"
  fi
  printf '%s\n' "${version#v}" > "${out}/VERSION"
  say "Token proxy ${version}: pinned in the stack files, built for ${#proxy_assets[@]} platforms"
  local os pinned
  mkdir -p "${out}/pinned"
  for os in linux windows; do   # the stack file of each OS that names the proxy: the default of its version is this release
    grep -q 'MACHINE_RUNNER_SWARM_PROXY_VERSION:-unreleased}' "${os}/stack/runners.yaml" || continue
    pinned="${out}/pinned/${os}/runners.yaml"
    mkdir -p "${out}/pinned/${os}"
    sed "s/\(MACHINE_RUNNER_SWARM_PROXY_VERSION:-\)unreleased}/\1${version#v}}/" "${os}/stack/runners.yaml" > "${pinned}"
    grep -q "MACHINE_RUNNER_SWARM_PROXY_VERSION:-${version#v}}" "${pinned}" || die "could not pin the token proxy version in ${os}/stack/runners.yaml"
  done
  ci/build-proxy.sh "${out}" "${version#v}" > /dev/null
  say "Bundle ${name}"
  for fmt in tar.gz zip; do
    local -a add=() excl=()
    for os in linux windows; do
      [ -f "${out}/pinned/${os}/runners.yaml" ] || continue
      add+=("--prefix=${name}/${os}/stack/" "--add-file=${out}/pinned/${os}/runners.yaml")
      excl+=(":(exclude)${os}/stack/runners.yaml")
    done
    # --add-file puts a file under the last --prefix before it; the tracked files get the last --prefix of all
    git archive --format="${fmt}" "${add[@]}" --prefix="${name}/" \
      --add-file="${out}/VERSION" --add-file="${out}/CHANGELOG.md" -o "${out}/${name}.${fmt}" HEAD -- \
      README.md LICENSE SECURITY.md docs examples linux windows \
      ':(exclude)linux/tests' ':(exclude)windows/tests' ':(exclude)docs/ci.md' ':(exclude)docs/releasing.md' "${excl[@]}"
  done
  (cd "${out}" && sha256sum "${name}.tar.gz" "${name}.zip" "${proxy_assets[@]}" | tee SHA256SUMS)
}

sign_and_verify() {
  local id="https://circleci.com/api/v2/projects/${CIRCLE_PROJECT_ID:?}/pipeline-definitions/${PIPELINE_DEFINITION_ID:?}"
  say "Sign SHA256SUMS (keyless, CircleCI OIDC token)"
  SIGSTORE_ID_TOKEN="$(circleci run oidc get --claims '{"aud":"sigstore"}' --root-issuer)" \
    cosign sign-blob --yes --bundle "${out}/SHA256SUMS.sigstore.json" "${out}/SHA256SUMS" > /dev/null
  say "Verify the signature against ${id}"
  cosign verify-blob --bundle "${out}/SHA256SUMS.sigstore.json" \
    --certificate-identity "${id}" --certificate-oidc-issuer "${oidc_issuer}" "${out}/SHA256SUMS"
}

publish() {
  [ -n "${GITHUB_TOKEN:-}" ] || {
    say "publishing skipped: GITHUB_TOKEN is not set in context scalable-machine-runner-release"
    say "${version} was prepared in ${out} and is stored as a job artifact"
    return 0
  }
  local repo="${CIRCLE_PROJECT_USERNAME:?}/${CIRCLE_PROJECT_REPONAME:?}" remote
  local -a assets=("${out}/${name}.tar.gz" "${out}/${name}.zip" "${proxy_assets[@]/#/${out}/}" "${out}/SHA256SUMS" "${out}/SHA256SUMS.sigstore.json")
  [ "${RELEASE_SKIP_SIGN:-}" != 1 ] || die "refusing to publish an unsigned release"
  remote="$(gh api "repos/${repo}/git/ref/tags/${version}" --jq .object.sha 2>/dev/null || true)"
  [ -z "${remote}" ] || [ "${remote}" = "${sha}" ] || die "tag ${version} exists at ${remote}, not at ${sha}"
  if gh release view "${version}" --repo "${repo}" > /dev/null 2>&1; then
    say "Release ${version} exists at this commit: uploading the assets again"
    gh release upload "${version}" "${assets[@]}" --clobber --repo "${repo}"
  else
    say "Create release ${version} at ${sha}"
    printf '\nTo verify the download, see https://github.com/%s/blob/%s/docs/install-linux.md#verify-a-release\n' \
      "${repo}" "${version}" >> "${out}/notes.md"
    gh release create "${version}" "${assets[@]}" --repo "${repo}" --target "${sha}" \
      --title "${version}" --notes-file "${out}/notes.md"
  fi
}

main() {
  cd "$(git rev-parse --show-toplevel)"
  sha="$(git rev-parse HEAD)"
  [ -z "${CIRCLE_SHA1:-}" ] || [ "${CIRCLE_SHA1}" = "${sha}" ] || die "checked out ${sha}, but the pipeline is for ${CIRCLE_SHA1}"
  rm -rf "${out}"; mkdir -p "${out}"
  mapfile -t proxy_assets < <(ci/build-proxy.sh --assets)
  # Swarm configs are immutable: a release whose script changed under an old config name would not reach the services.
  ci/config-names.sh > /dev/null || die "a Swarm config of a stack file has a stale name: run ci/config-names.sh --write and commit it"
  check_runner_pin
  choose_version
  name="machine-runner-swarm-${version#v}"
  build
  if [ "${RELEASE_SKIP_SIGN:-}" = 1 ]; then say "Signing skipped (RELEASE_SKIP_SIGN=1)"; else sign_and_verify; fi
  publish
}

case "${1:-}" in
  install-tools) install_tools ;;
  "") main ;;
  *) die "usage: ci/release.sh [install-tools]" ;;
esac
