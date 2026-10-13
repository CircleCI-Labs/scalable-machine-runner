#!/usr/bin/env bash
# The release job of this repository (docs/releasing.md).
#
#   ci/release.sh install-tools   install git-cliff, cosign and gh (pinned, SHA-256 checked)
#   ci/release.sh                 version, notes, bundle, SHA256SUMS, signature, then publish
#
# From the Conventional Commits since the last tag it computes the next version (cliff.toml),
# builds the bundle from the tracked files, signs SHA256SUMS with cosign (keyless: the CircleCI
# OIDC token) and checks the signature, then creates the GitHub release, which also creates the
# tag. It never pushes a commit or a tag with git.
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
export PATH="${bin}:${PATH}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

install_tools() {
  [ "$(uname -m)" = x86_64 ] || die "install-tools supports x86_64 Linux only"
  local tmp; tmp="$(mktemp -d)"
  fetch() { # url sha256 file
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$3" "$1"
    echo "$2  $3" | sha256sum -c --quiet -
  }
  mkdir -p "${bin}"
  fetch https://github.com/orhun/git-cliff/releases/download/v2.14.2/git-cliff-2.14.2-x86_64-unknown-linux-gnu.tar.gz \
    24f397c733add5390fdceee3a2088588ab0d5f944ce00d34cb7029b888cf2db4 "${tmp}/git-cliff.tar.gz"
  tar -xzf "${tmp}/git-cliff.tar.gz" -C "${tmp}"
  install -m 0755 "${tmp}/git-cliff-2.14.2/git-cliff" "${bin}/git-cliff"
  fetch https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign-linux-amd64 \
    4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71 "${tmp}/cosign"
  install -m 0755 "${tmp}/cosign" "${bin}/cosign"
  fetch https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_linux_amd64.tar.gz \
    bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386 "${tmp}/gh.tar.gz"
  tar -xzf "${tmp}/gh.tar.gz" -C "${tmp}"
  install -m 0755 "${tmp}/gh_2.102.0_linux_amd64/bin/gh" "${bin}/gh"
  rm -rf "${tmp}"
  git cliff --version; cosign version 2>&1 | grep -E '^GitVersion'; gh --version | head -n 1
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
  say "Bundle ${name}"
  for fmt in tar.gz zip; do
    git archive --format="${fmt}" --prefix="${name}/" \
      --add-file="${out}/VERSION" --add-file="${out}/CHANGELOG.md" -o "${out}/${name}.${fmt}" HEAD -- \
      README.md LICENSE SECURITY.md docs examples linux windows \
      ':(exclude)linux/tests' ':(exclude)windows/tests' ':(exclude)docs/ci.md' ':(exclude)docs/releasing.md'
  done
  (cd "${out}" && sha256sum "${name}.tar.gz" "${name}.zip" | tee SHA256SUMS)
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
  local -a assets=("${out}/${name}.tar.gz" "${out}/${name}.zip" "${out}/SHA256SUMS" "${out}/SHA256SUMS.sigstore.json")
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
