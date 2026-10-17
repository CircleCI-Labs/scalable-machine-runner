#!/usr/bin/env bash
# The release job of this repository (docs/releasing.md).
#
#   ci/release.sh install-tools   install git-cliff, cosign, crane, gh and Go (pinned, SHA-256 checked)
#   ci/release.sh                 version, notes, bundle, SHA256SUMS, signature, the tags of the token proxy image, then publish
#
# From the Conventional Commits since the last tag it computes the next version (cliff.toml),
# checks that every Swarm config of the stack files is named after its content (ci/config-names.sh) and that the exact runner
# version that the stack files pin (MACHINE_RUNNER_SWARM_RUNNER_VERSION, the newest one that CI tests) is in CircleCI's manifest
# for every platform,
# builds the bundle from the tracked files, with the token proxy image of the stack files pinned to this release
# (MACHINE_RUNNER_SWARM_PROXY_IMAGE: ${...:-ccilabs/machine-runner-swarm-proxy:latest} becomes ${...:-ccilabs/machine-runner-swarm-proxy:<version>@sha256:<digest>},
# the digest being the image that the pipeline of this commit pushed as sha-<12 characters of the commit>: ci/proxy-image.sh),
# signs SHA256SUMS, which lists the bundles, with cosign (keyless: the CircleCI OIDC token) and checks the signature and that its certificate
# names refs/heads/main as the source repository ref, checks the signature of the image too and gives it the release tags (X.Y.Z, which never moves, and X.Y, X and latest when this is the newest
# of its line: ci/proxy-image.sh release-tags), then creates the GitHub release, which also creates the tag. It never pushes a
# commit or a tag with git.
#
# Environment:
#   GITHUB_TOKEN          from the context scalable-machine-runner-release. Without it every
#                         step runs except the last one.
#   DOCKERHUB_USERNAME, DOCKERHUB_TOKEN   from the context scalable-machine-runner-dockerhub. They give the token proxy image its release
#                         tags. Without them the release is not published: a bundle that names an image tag that does not exist would be
#                         broken, so every step runs except the tags and the last one.
#   PIPELINE_DEFINITION_ID  the pipeline definition (<< pipeline.definition.id >>), for the
#                         certificate identity that the signature is checked against
#   REQUIRE_CREDENTIALS   true or 1 on a production main (the setup gate): a release that is due fails when GITHUB_TOKEN or the Docker Hub credentials
#                         are missing, instead of ending green with nothing published
#   RELEASE_SKIP_SIGN=1   for a run outside CircleCI, where there is no OIDC token
#   RELEASE_DEPLOY_MARKER=1  record the release in the Deploys view of CircleCI (docs/ci.md, "Deploys"): component
#                         machine-runner-swarm, environment github-releases, version = the release tag; and the tags of the image:
#                         component token-proxy-image, environment docker-hub, version = X.Y.Z. Only a run that publishes is recorded
#                         (both tokens set, signing on). A marker never fails the release.
#   RELEASE_OUT           output directory (default /tmp/release)
#   RELEASE_RUNNER_MANIFEST   path to a local circleci-runner manifest.json (tests only; the release job fetches the manifest over HTTPS)
#
# Never run this with `set -x`: the OIDC token and GITHUB_TOKEN are in the environment.
set -euo pipefail

out="${RELEASE_OUT:-/tmp/release}"
bin="${RELEASE_BIN:-${HOME}/.local/bin}"
tag_glob='v[0-9]*.[0-9]*.[0-9]*'
oidc_issuer='https://oidc.circleci.com'
sign_ref=refs/heads/main   # the ref that the certificate of a release must name (signed_only_on, ci/tools.sh)
goroot="${RELEASE_GOROOT:-${HOME}/.local/go}"
export PATH="${goroot}/bin:${bin}:${PATH}"
ci_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CI_TOOLS_BIN="${bin}"
# shellcheck source=ci/tools.sh
. "${ci_dir}/tools.sh"   # fetch, install_cosign and install_crane
image_repo=ccilabs/machine-runner-swarm-proxy
proxy_digest=   # the digest of the image that the pipeline of this commit pushed: set in main

say() { printf '==> %s\n' "$*"; }
marker() { if [ "${RELEASE_DEPLOY_MARKER:-}" = 1 ]; then ci/deploy-marker.sh "$@"; fi; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

install_tools() {
  [ "$(uname -m)" = x86_64 ] || die "install-tools supports x86_64 Linux only"
  # Each tool: its version and the SHA-256 value of its download, which Renovate cannot compute. A Renovate pull request
  # changes the version only: put the new value next to it (docs/releasing.md, "Pinned tools"). cosign and crane are in ci/tools.sh.
  # renovate: datasource=github-releases depName=orhun/git-cliff extractVersion=^v(?<version>.*)$
  local git_cliff_version=2.14.2
  local git_cliff_sha256=24f397c733add5390fdceee3a2088588ab0d5f944ce00d34cb7029b888cf2db4
  # renovate: datasource=github-releases depName=cli/cli extractVersion=^v(?<version>.*)$
  local gh_version=2.102.0
  local gh_sha256=bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386
  # renovate: datasource=golang-version depName=go
  local go_version=1.27.2
  local go_sha256=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "${bin}"
  fetch "https://github.com/orhun/git-cliff/releases/download/v${git_cliff_version}/git-cliff-${git_cliff_version}-x86_64-unknown-linux-gnu.tar.gz" \
    "${git_cliff_sha256}" "${tmp}/git-cliff.tar.gz"
  tar -xzf "${tmp}/git-cliff.tar.gz" -C "${tmp}"
  install -m 0755 "${tmp}/git-cliff-${git_cliff_version}/git-cliff" "${bin}/git-cliff"
  install_cosign
  install_crane
  fetch "https://github.com/cli/cli/releases/download/v${gh_version}/gh_${gh_version}_linux_amd64.tar.gz" \
    "${gh_sha256}" "${tmp}/gh.tar.gz"
  tar -xzf "${tmp}/gh.tar.gz" -C "${tmp}"
  install -m 0755 "${tmp}/gh_${gh_version}_linux_amd64/bin/gh" "${bin}/gh"
  fetch "https://go.dev/dl/go${go_version}.linux-amd64.tar.gz" \
    "${go_sha256}" "${tmp}/go.tar.gz"
  rm -rf "${goroot}"; mkdir -p "${goroot}"
  tar -xzf "${tmp}/go.tar.gz" -C "${goroot}" --strip-components=1
  rm -rf "${tmp}"
  git cliff --version; cosign version 2>&1 | grep -E '^GitVersion'; crane version; gh --version | head -n 1; go version
}

# The stack files pin one exact runner version by default, the newest that CI tests (docs/releasing.md says how a release bumps it).
# It must be the same in every stack file, and CircleCI's manifest must still list it for every platform that the stack runs on.
check_runner_pin() {
  local f pin first='' manifest_file tmp_manifest=''
  for f in linux/stack/runners.yaml linux/stack/microvm.yaml windows/stack/runners.yaml; do
    pin="$(sed -n 's/^  MACHINE_RUNNER_SWARM_RUNNER_VERSION: \${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-\([0-9][0-9.]*\)}.*/\1/p' "${f}")"
    [ -n "${pin}" ] || die "${f} has no exact default of MACHINE_RUNNER_SWARM_RUNNER_VERSION"
    [ -z "${first}" ] || [ "${pin}" = "${first}" ] || die "${f} pins runner ${pin}, another stack file pins ${first}: they must be equal"
    first="${pin}"
  done
  if [ -n "${RELEASE_RUNNER_MANIFEST:-}" ]; then
    manifest_file="${RELEASE_RUNNER_MANIFEST}"
    [ -f "${manifest_file}" ] || die "RELEASE_RUNNER_MANIFEST is not a file: ${manifest_file}"
  else
    manifest_file="$(mktemp)"
    tmp_manifest="${manifest_file}"
    curl -fsSL --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors \
      https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/manifest.json -o "${manifest_file}"
  fi
  if ! python3 -c '
import json, re, sys
pin, manifest_path = sys.argv[1], sys.argv[2]
manifest = json.load(open(manifest_path))
entry = (manifest.get("releases") or {}).get(pin)
want = {"linux": ["amd64", "arm64", "ppc64le", "s390x"], "windows": ["amd64", "arm64"]}
missing = [o + "/" + a for o, archs in want.items() for a in archs if not (entry or {}).get(o, {}).get(a, {}).get("sha256")]
if missing:
    sys.exit("runner " + pin + " is not in the manifest of CircleCI for " + ", ".join(missing))
sha_re = re.compile(r"^  MACHINE_RUNNER_SWARM_RUNNER_SHA256: \$\{MACHINE_RUNNER_SWARM_RUNNER_SHA256:-([0-9a-f,]*)\}$")
checks = [
    ("linux/stack/runners.yaml", "linux", ["amd64", "arm64", "ppc64le", "s390x"]),
    ("linux/stack/microvm.yaml", "linux", ["amd64", "arm64", "ppc64le", "s390x"]),
    ("windows/stack/runners.yaml", "windows", ["amd64", "arm64"]),
]
together = "bump the runner pin and its SHA-256 list together (docs/releasing.md)"
for path, os_name, archs in checks:
    got_shas = None
    with open(path) as fh:
        for line in fh:
            m = sha_re.match(line.rstrip("\n"))
            if m:
                got_shas = [h for h in m.group(1).split(",") if h]
                break
    if got_shas is None:
        sys.exit(path + ": has no default list of MACHINE_RUNNER_SWARM_RUNNER_SHA256")
    if len(got_shas) != len(archs):
        sys.exit(path + " " + os_name + ": the default SHA-256 list has " + str(len(got_shas)) + " value(s), want " + str(len(archs)) + ": " + together)
    for i, arch in enumerate(archs):
        want = entry[os_name][arch]["sha256"].lower()
        got = got_shas[i].lower()
        if got != want:
            sys.exit(path + " " + os_name + "/" + arch + ": SHA-256 " + got + " does not match the manifest for pin " + pin + " (" + want + "): " + together)
' "${first}" "${manifest_file}"; then
    [ -n "${tmp_manifest}" ] && rm -f "${tmp_manifest}"
    exit 1
  fi
  [ -n "${tmp_manifest}" ] && rm -f "${tmp_manifest}"
  say "Runner pin ${first}: in CircleCI's manifest for every platform, SHA-256 lists match"
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
  say "Token proxy image ${image_repo}:${version#v}${proxy_digest:+@${proxy_digest}}: pinned in the stack files"
  local os pinned pin="${image_repo}:${version#v}${proxy_digest:+@${proxy_digest}}"
  mkdir -p "${out}/pinned"
  for os in linux windows; do   # the stack file of each OS that names the proxy: the default of its image is this release
    grep -q "MACHINE_RUNNER_SWARM_PROXY_IMAGE:-${image_repo}:latest}" "${os}/stack/runners.yaml" || continue
    pinned="${out}/pinned/${os}/runners.yaml"
    mkdir -p "${out}/pinned/${os}"
    sed "s|\(MACHINE_RUNNER_SWARM_PROXY_IMAGE:-\)${image_repo}:latest}|\1${pin}}|" "${os}/stack/runners.yaml" > "${pinned}"
    grep -qF "MACHINE_RUNNER_SWARM_PROXY_IMAGE:-${pin}}" "${pinned}" || die "could not pin the token proxy image in ${os}/stack/runners.yaml"
  done
  say "Bundle ${name}"
  # What the bundle holds: the user-facing files, without the tests and the pages about this repository's own pipeline and release.
  local -a paths=(README.md LICENSE SECURITY.md docs examples linux windows ':(exclude)linux/tests' ':(exclude)windows/tests' ':(exclude)docs/ci.md' ':(exclude)docs/releasing.md')
  # The pages that ship link to the ones that do not: those links become links to GitHub at the tag (ci/bundle-links.py, which stops on a link
  # that is dead in the repository too). The rewritten pages are added in place of the originals.
  local -a relinked=() links_add=() links_excl=()
  local p dir
  mapfile -t relinked < <(python3 "${ci_dir}/bundle-links.py" --repo "${CIRCLE_PROJECT_USERNAME:-CircleCI-Labs}/${CIRCLE_PROJECT_REPONAME:-machine-runner-swarm}" \
    --tag "${version}" --out "${out}/links" --extra VERSION --extra CHANGELOG.md -- "${paths[@]}")
  for p in "${relinked[@]}"; do
    dir=$(dirname "${p}")
    if [ "${dir}" = . ]; then links_add+=("--prefix=${name}/"); else links_add+=("--prefix=${name}/${dir}/"); fi
    links_add+=("--add-file=${out}/links/${p}")
    links_excl+=(":(exclude)${p}")
  done
  say "${#relinked[@]} page(s) of the bundle link to files that it does not hold: those links point to GitHub at ${version}"
  for fmt in tar.gz zip; do
    local -a add=() excl=()
    for os in linux windows; do
      [ -f "${out}/pinned/${os}/runners.yaml" ] || continue
      add+=("--prefix=${name}/${os}/stack/" "--add-file=${out}/pinned/${os}/runners.yaml")
      excl+=(":(exclude)${os}/stack/runners.yaml")
    done
    # --add-file puts a file under the last --prefix before it; the tracked files get the last --prefix of all
    git archive --format="${fmt}" "${add[@]}" "${links_add[@]}" --prefix="${name}/" \
      --add-file="${out}/VERSION" --add-file="${out}/CHANGELOG.md" -o "${out}/${name}.${fmt}" HEAD -- \
      "${paths[@]}" "${excl[@]}" "${links_excl[@]}"
  done
  (cd "${out}" && sha256sum "${name}.tar.gz" "${name}.zip" | tee SHA256SUMS)
}

sign_and_verify() {
  local id="https://circleci.com/api/v2/projects/${CIRCLE_PROJECT_ID:?}/pipeline-definitions/${PIPELINE_DEFINITION_ID:?}"
  say "Sign SHA256SUMS (keyless, CircleCI OIDC token)"
  SIGSTORE_ID_TOKEN="$(circleci run oidc get --claims '{"aud":"sigstore"}' --root-issuer)" \
    cosign sign-blob --yes --bundle "${out}/SHA256SUMS.sigstore.json" "${out}/SHA256SUMS" > /dev/null
  say "Verify the signature against ${id}, made for ${sign_ref}"
  cosign verify-blob --bundle "${out}/SHA256SUMS.sigstore.json" \
    --certificate-identity "${id}" --certificate-oidc-issuer "${oidc_issuer}" "${out}/SHA256SUMS"
  # The identity is the same for every branch of the project: the ref is what tells a release from a signature made by a job of a feature branch.
  signed_only_on "${sign_ref}" < "${out}/SHA256SUMS.sigstore.json" ||
    die "the certificate of the signature does not name ${sign_ref} as its source repository ref (OID 1.3.6.1.4.1.57264.1.14): this job did not run for it"
  say "The certificate names ${sign_ref}"
}

# proxy_image: the image of this commit is on Docker Hub (the job proxy-image-publish pushed it as sha-<12>): its digest goes in the bundle.
# Reading it needs no credentials. A release that publishes checks the signature of the image and gives it the release tags first.
resolve_proxy_image() {
  proxy_digest="$("${ci_dir}/proxy-image.sh" digest 2> /dev/null || true)"
  if [ -n "${proxy_digest}" ]; then
    say "Token proxy image of this commit: ${image_repo}@${proxy_digest}"
  else
    say "No token proxy image of this commit (${image_repo}:sha-${sha:0:12}): the bundle names the tag only, and nothing is published"
  fi
}

# will_publish: every condition of a release that publishes is met. A message says what is missing when it is not.
will_publish() {
  [ "${RELEASE_SKIP_SIGN:-}" != 1 ] || return 1
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    ! require_credentials || die "GITHUB_TOKEN is not set in context scalable-machine-runner-release, and this pipeline must publish (REQUIRE_CREDENTIALS=${REQUIRE_CREDENTIALS})"
    say "publishing skipped: GITHUB_TOKEN is not set in context scalable-machine-runner-release"; return 1
  fi
  if [ -z "${DOCKERHUB_USERNAME:-}" ] || [ -z "${DOCKERHUB_TOKEN:-}" ]; then
    ! require_credentials || die "DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are not both set in context scalable-machine-runner-dockerhub, and this pipeline must publish (REQUIRE_CREDENTIALS=${REQUIRE_CREDENTIALS})"
    say "publishing skipped: DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are not both set in context scalable-machine-runner-dockerhub (a release needs them to tag its token proxy image)"
    return 1
  fi
  [ -n "${proxy_digest}" ] || die "the token proxy image of this commit is not on Docker Hub (${image_repo}:sha-${sha:0:12}): the job proxy-image-publish pushes it, and the release requires that job"
  return 0
}

publish() {
  local repo="${CIRCLE_PROJECT_USERNAME:?}/${CIRCLE_PROJECT_REPONAME:?}" remote
  local -a assets=("${out}/${name}.tar.gz" "${out}/${name}.zip" "${out}/SHA256SUMS" "${out}/SHA256SUMS.sigstore.json")
  [ "${RELEASE_SKIP_SIGN:-}" != 1 ] || die "refusing to publish an unsigned release"
  remote="$(gh api "repos/${repo}/git/ref/tags/${version}" --jq .object.sha 2>/dev/null || true)"
  [ -z "${remote}" ] || [ "${remote}" = "${sha}" ] || die "tag ${version} exists at ${remote}, not at ${sha}"
  # The image first: its signature is checked, and X.Y.Z (which never moves) and the floating tags are made. A release that fails after this
  # one is finished by the next run, which tags the same digest again.
  say "Tag ${image_repo}@${proxy_digest} (signature checked first)"
  marker update proxy-image RUNNING
  "${ci_dir}/proxy-image.sh" release-tags "${version}"
  marker update proxy-image SUCCESS
  if gh release view "${version}" --repo "${repo}" > /dev/null 2>&1; then
    say "Release ${version} exists at this commit: uploading the assets again"
    gh release upload "${version}" "${assets[@]}" --clobber --repo "${repo}"
  else
    say "Create release ${version} at ${sha}"
    {
      printf '\nToken proxy image: `%s:%s@%s`, signed like the bundle. To verify the download and the image, see https://github.com/%s/blob/%s/docs/install-linux.md#verify-a-release and https://github.com/%s/blob/%s/docs/security.md#verify-the-token-proxy-image\n' \
        "${image_repo}" "${version#v}" "${proxy_digest}" "${repo}" "${version}" "${repo}" "${version}"
    } >> "${out}/notes.md"
    gh release create "${version}" "${assets[@]}" --repo "${repo}" --target "${sha}" \
      --title "${version}" --notes-file "${out}/notes.md"
  fi
}

main() {
  cd "$(git rev-parse --show-toplevel)"
  sha="$(git rev-parse HEAD)"
  [ -z "${CIRCLE_SHA1:-}" ] || [ "${CIRCLE_SHA1}" = "${sha}" ] || die "checked out ${sha}, but the pipeline is for ${CIRCLE_SHA1}"
  rm -rf "${out}"; mkdir -p "${out}"
  # Swarm configs are immutable: a release whose script changed under an old config name would not reach the services.
  ci/config-names.sh > /dev/null || die "a Swarm config of a stack file has a stale name: run ci/config-names.sh --write and commit it"
  check_runner_pin
  choose_version
  name="machine-runner-swarm-${version#v}"
  resolve_proxy_image
  # A release that will publish is a deploy. Plan it before the first step that can fail, and give it the final status on
  # every way out of the script (a die, a failed command, a cancel): the job `release` is the one job of plan and updates.
  # The tags of the image are a deploy of their own, in the same job.
  local publishing=false
  if will_publish; then
    publishing=true
    marker plan release machine-runner-swarm github-releases "${version}"
    marker plan proxy-image token-proxy-image docker-hub "${version#v}"
    # shellcheck disable=SC2154  # rc is set by the trap itself
    trap 'rc=$?; case ${rc} in 0) ;; 130 | 143) marker update release CANCELED; marker update proxy-image CANCELED ;; *) marker update release FAILED "ci/release.sh exited with status ${rc}"; marker update proxy-image FAILED "ci/release.sh exited with status ${rc}" ;; esac' EXIT
  fi
  build
  if [ "${RELEASE_SKIP_SIGN:-}" = 1 ]; then say "Signing skipped (RELEASE_SKIP_SIGN=1)"; else sign_and_verify; fi
  if [ "${publishing}" = true ]; then
    marker update release RUNNING
    publish
    marker update release SUCCESS
  else
    say "${version} was prepared in ${out} and is stored as a job artifact"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    install-tools) install_tools ;;
    "") main ;;
    *) die "usage: ci/release.sh [install-tools]" ;;
  esac
fi
