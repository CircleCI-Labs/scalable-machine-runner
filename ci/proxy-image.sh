#!/usr/bin/env bash
# proxy-image.sh: the token proxy as a published image, ccilabs/machine-runner-swarm-proxy (docs/releasing.md, "The token proxy image").
#
#   ci/proxy-image.sh setup           QEMU handlers for the other architectures and a pinned BuildKit builder
#   ci/proxy-image.sh test            build proxy/Dockerfile for linux/amd64, arm64, ppc64le and s390x, and test each image
#   ci/proxy-image.sh push            build the four platforms and push them as ONE index, REPO:sha-<12>-linux (needs the credentials)
#   ci/proxy-image.sh assemble        join the Linux index and the two Windows images into one manifest list, tag it sha-<12> (and nothing
#                                     else), sign every digest, and check the result (needs the credentials)
#   ci/proxy-image.sh edge            verify the signature of REPO:sha-<12> and tag it edge, unless a newer commit is on main (needs the
#                                     credentials). The last job of the pipeline of main runs it, after every test has passed
#   ci/proxy-image.sh rehearse        sign and verify a throwaway image in a registry of its own (no credential, no Docker Hub), with the OIDC token of
#                                     this job, for the ref of this branch. Every pipeline runs it, so that main is not the first real run of the signing
#   ci/proxy-image.sh credentials     check the credentials at once: fails when REQUIRE_CREDENTIALS is set and they are missing, says so otherwise
#   ci/proxy-image.sh digest          print the digest of REPO:sha-<12>, the image of this commit (no credentials; exit 1 when there is none)
#   ci/proxy-image.sh release-tags vX.Y.Z   verify the signature of that digest and give it the release tags (needs the credentials):
#                                     X.Y.Z (immutable: an existing X.Y.Z must be this digest), and X.Y, X and latest when X.Y.Z is the
#                                     newest of its minor line, its major line, and of all releases
#   ci/proxy-image.sh install-tools   crane and cosign (ci/tools.sh: pinned, SHA-256 checked)
#
# The pipeline of a push to main runs them in this order: test and push in the job that builds the Linux image; the Windows jobs push
# REPO:sha-<12>-windows-ltsc2022 and -ltsc2025 (ci/Build-ProxyImage.ps1); then assemble, which makes sha-<12>. No tag that a user pulls by default
# moves before the tests have passed: edge moves in the last job of the pipeline, and a release adds X.Y.Z, X.Y, X and latest, the default of the stack
# files, to the digest of sha-<12> (ci/release.sh). docs/releasing.md has the table of tags.
#
# Environment:
#   DOCKERHUB_USERNAME, DOCKERHUB_TOKEN   from the context scalable-machine-runner-dockerhub (main only). Without both, push, assemble and edge
#                          print that they did nothing and exit 0, so that a pipeline without the credentials stays green. Never printed.
#   REQUIRE_CREDENTIALS    true or 1 on a production main (the setup gate): then they exit 1 instead, so that a missing credential cannot hide
#   PROXY_IMAGE_REPO       the repository (default ccilabs/machine-runner-swarm-proxy)
#   PROXY_IMAGE_SIGN       oidc (default: keyless cosign with the CircleCI OIDC token, the way ci/release.sh signs) or none (the local test)
#   PIPELINE_DEFINITION_ID, CIRCLE_PROJECT_ID   for the certificate identity that the signature is checked against, as in ci/release.sh
#   PROXY_IMAGE_BUILDER    the buildx builder (default proxy-image)
#   PROXY_IMAGE_OUT        a directory for the digests that the job writes (default /tmp/proxy-image)
#   PROXY_IMAGE_REGISTRY_INSECURE=1   the registry of the test is plain HTTP on localhost
#   PROXY_IMAGE_MAIN_REF   the ref of main that edge is compared with (default origin/main, fetched; the test names a local one)
#   SIGN_EXPECT_REF        the ref that the certificate of a signature must name (default refs/heads/main; the signing rehearsal of any
#                          other branch names its own)
#   REHEARSAL_REGISTRY     the registry of the rehearsal (default localhost:5000, the registry:2 container of the job; plain HTTP)
#   PROXY_IMAGE_RELEASE_TAGS   the release tags that exist, one per line (default: the vX.Y.Z tags of this repository)
#
# Never run this with `set -x`: the credentials and the OIDC token are in the environment.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "${here}/.." && pwd)
cd "${repo_dir}"
image_repo=${PROXY_IMAGE_REPO:-ccilabs/machine-runner-swarm-proxy}
builder=${PROXY_IMAGE_BUILDER:-proxy-image}
out=${PROXY_IMAGE_OUT:-/tmp/proxy-image}
oidc_issuer='https://oidc.circleci.com'
platforms=(linux/amd64 linux/arm64 linux/ppc64le linux/s390x)
windows_tags=(ltsc2022 ltsc2025)
# The QEMU installer and the BuildKit image (pinned like every image of the CI; Renovate keeps both).
binfmt_image=tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0
buildkit_image=moby/buildkit:v0.33.1@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea

sha=${CIRCLE_SHA1:-$(git rev-parse HEAD)}
short=${sha:0:12}
version=sha-${short}
export PATH="${CI_TOOLS_BIN:-${RELEASE_BIN:-${HOME}/.local/bin}}:${PATH}"
# shellcheck source=ci/tools.sh
. "${here}/tools.sh"   # install_cosign, install_crane and signed_only_on

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
have_credentials() { [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; }
no_credentials() {
  if require_credentials; then
    die "DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are not both set, and this pipeline must publish (REQUIRE_CREDENTIALS=${REQUIRE_CREDENTIALS}): the context scalable-machine-runner-dockerhub is missing, restricted for this pipeline, or lacks a variable (docs/ci.md, 'The Docker Hub context')"
  fi
  say "NOT PUSHED: DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are not both set (the context scalable-machine-runner-dockerhub holds them)."
  say "The image was built and tested; nothing was published. The maintainer adds the values to the context (docs/releasing.md)."
}
# craned SUBCOMMAND ARGS...: crane, with --insecure for the plain HTTP registry of the test
craned() {
  local -a flag=()
  [ "${PROXY_IMAGE_REGISTRY_INSECURE:-}" != 1 ] || flag=(--insecure)
  crane "$1" "${flag[@]}" "${@:2}"
}
login() {
  # docker and crane both read ~/.docker/config.json; the token goes in on stdin
  case ${image_repo} in
    localhost* | 127.0.0.1*) return 0 ;;   # the registry of the test has no login
  esac
  printf '%s' "${DOCKERHUB_TOKEN}" | docker login --username "${DOCKERHUB_USERNAME}" --password-stdin > /dev/null 2>&1 ||
    die "docker login failed for ${DOCKERHUB_USERNAME}"
}

setup() {
  local a handler
  for a in arm64 ppc64le s390x; do
    handler=qemu-${a}
    [ "${a}" != arm64 ] || handler=qemu-aarch64   # the name that the kernel gives the arm64 handler
    if [ ! -e "/proc/sys/fs/binfmt_misc/${handler}" ]; then
      say "registering the ${handler} handler (a kernel setting, it stays until the next boot)"
      docker run --privileged --rm "${binfmt_image}" --install "${a}" > /dev/null 2>&1 || true
    fi
    [ -e "/proc/sys/fs/binfmt_misc/${handler}" ] || die "the ${handler} handler is not registered and could not be (${binfmt_image} --install ${a} needs a privileged container)"
  done
  if ! docker buildx inspect "${builder}" > /dev/null 2>&1; then
    say "creating the buildx builder ${builder} (${buildkit_image})"
    docker buildx create --name "${builder}" --driver docker-container --driver-opt "image=${buildkit_image}" --driver-opt network=host > /dev/null
  fi
  docker buildx inspect --bootstrap "${builder}" | sed -n '1,/^Platforms/p' | tail -n 4
}

# build_args: the build arguments of proxy/Dockerfile
build_args() { printf '%s\n' --build-arg "VERSION=${version}" --build-arg "REVISION=${sha}"; }

test_images() {
  local p a tag work failures=0 cid vol
  work=$(mktemp -d)
  trap 'rm -rf "${work}"' RETURN
  # a token file and a state volume, as a stack gives them to the proxy: the proxy finds its classes as the <service>-token files of its secrets
  # directory, so smoke-token is the class smoke
  mkdir -m 0755 "${work}/tokens"
  printf 'api:\n  auth_token: smoke-not-a-real-token\n' > "${work}/tokens/smoke-token"
  chmod 0444 "${work}/tokens/smoke-token"
  for p in "${platforms[@]}"; do
    a=${p#*/}
    tag=machine-runner-swarm-proxy:ci-${a}
    say "build and test ${p}"
    mapfile -t args < <(build_args)
    docker buildx build --builder "${builder}" --platform "${p}" --load --tag "${tag}" "${args[@]}" proxy/ > "${work}/build-${a}.log" 2>&1 ||
      { tail -n 20 "${work}/build-${a}.log"; die "the build for ${p} failed"; }
    check() { # NAME COMMAND...: a line per check; a failure is counted and the next platform still runs
      local name=$1; shift
      if "$@" > "${work}/check.out" 2>&1; then
        printf 'CHECK %s %s PASS\n' "${a}" "${name}"
      else
        printf 'CHECK %s %s FAIL\n' "${a}" "${name}"
        sed 's/^/    /' "${work}/check.out" | tail -n 12
        failures=$((failures + 1))
      fi
    }
    image_is() { [ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${tag}")" = "${p}" ]; }
    check platform image_is
    runs_as_nobody() { [ "$(docker image inspect --format '{{.Config.User}}' "${tag}")" = 65534:65534 ]; }
    check non-root runs_as_nobody
    reports_version() {
      local v
      v=$(docker run --rm --platform "${p}" "${tag}" -version) && echo "${v}" && [ "${v}" = "machine-runner-swarm-proxy ${version}" ]
    }
    check reports-its-version reports_version
    size_note() { docker image inspect --format '{{.Size}} bytes' "${tag}"; }
    check size size_note
    # It starts as a stack would start it: read-only root, no capabilities, a token file, a state volume owned by the image.
    vol=mrsp-smoke-${a}-$$
    cid=$(docker run -d --platform "${p}" --read-only --cap-drop ALL --user 65534:65534 -v "${work}/tokens:/tokens:ro" -v "${vol}:/state" \
      "${tag}" -secrets-dir /tokens -state-dir /state -upstream http://127.0.0.1:9)
    healthcheck_flag() {
      for _ in $(seq 1 60); do
        docker exec "${cid}" /machine-runner-swarm-proxy -healthcheck && return 0
        sleep 2
      done
      docker logs "${cid}" 2>&1 | tail -n 10
      return 1
    }
    check healthcheck-flag healthcheck_flag
    writes_state() { docker cp "${cid}:/state/state.json" - | tar -xO | grep -q '"version":1'; }
    check writes-its-state-on-a-volume writes_state
    docker_healthy() {
      local s
      for _ in $(seq 1 30); do
        s=$(docker inspect --format '{{.State.Health.Status}}' "${cid}")
        [ "${s}" = healthy ] && { echo healthy; return 0; }
        sleep 2
      done
      echo "${s}"
      return 1
    }
    check healthcheck-of-the-image docker_healthy
    no_token_in_log() { ! docker logs "${cid}" 2>&1 | grep -q smoke-not-a-real-token; }
    check no-token-in-the-log no_token_in_log
    docker rm -f "${cid}" > /dev/null
    docker volume rm "${vol}" > /dev/null 2>&1 || true
  done
  [ "${failures}" -eq 0 ] || die "${failures} check(s) of the image failed"
  say "every platform builds, runs and passes its checks: ${platforms[*]}"
}

push() {
  have_credentials || { no_credentials; return 0; }
  local digest meta
  mkdir -p "${out}"
  login
  meta=$(mktemp)
  mapfile -t args < <(build_args)
  say "build ${platforms[*]} and push ${image_repo}:${version}-linux (one index)"
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct "${sha}") docker buildx build --builder "${builder}" \
    --platform "$(IFS=,; echo "${platforms[*]}")" --provenance=false --sbom=false "${args[@]}" \
    --output "type=image,name=${image_repo}:${version}-linux,push=true,rewrite-timestamp=true" --metadata-file "${meta}" proxy/
  digest=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["containerimage.digest"])' "${meta}")
  rm -f "${meta}"
  printf '%s\n' "${digest}" > "${out}/linux.digest"
  say "pushed ${image_repo}:${version}-linux ${digest}"
}

# --- assemble ---------------------------------------------------------------------------------------------------------------------

digest_of() { craned digest "$1"; }

sign_all() { # DIGEST...: keyless cosign of each digest, the way ci/release.sh signs
  local d
  [ "${PROXY_IMAGE_SIGN:-oidc}" != none ] || { say "signing skipped (PROXY_IMAGE_SIGN=none)"; return 0; }
  for d in "$@"; do
    say "sign ${image_repo}@${d} (keyless, CircleCI OIDC token)"
    SIGSTORE_ID_TOKEN="$(circleci run oidc get --claims '{"aud":"sigstore"}' --root-issuer)" cosign sign --yes "${image_repo}@${d}" > /dev/null
    verify_signature "${d}"
  done
}

# check_index REF: the platforms of the manifest list that a user pulls
check_index() {
  local ref=$1
  craned manifest "${ref}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
want_linux = {"amd64", "arm64", "ppc64le", "s390x"}
linux = {m["platform"]["architecture"] for m in d["manifests"] if m["platform"]["os"] == "linux"}
windows = [m["platform"] for m in d["manifests"] if m["platform"]["os"] == "windows"]
for p in sorted(m["platform"]["os"] + "/" + m["platform"]["architecture"] + " " + m["platform"].get("os.version", "") for m in d["manifests"]):
    print("   ", p.strip())
if linux != want_linux:
    sys.exit("the linux platforms are " + ",".join(sorted(linux)) + ", want " + ",".join(sorted(want_linux)))
if len(windows) != int(sys.argv[1]) or any(w["architecture"] != "amd64" for w in windows):
    sys.exit("want %s windows/amd64 images, got %d" % (sys.argv[1], len(windows)))
' "${#windows_tags[@]}" || die "the manifest list ${ref} does not hold every platform"
}

assemble() {
  have_credentials || { no_credentials; return 0; }
  local linux idx t w
  local -a members=() digests=()
  mkdir -p "${out}"
  login
  linux=$(digest_of "${image_repo}:${version}-linux") || die "${image_repo}:${version}-linux is not on the registry: the Linux job did not push it"
  digests+=("${linux}")
  members+=(-m "${image_repo}@${linux}")
  for t in "${windows_tags[@]}"; do
    w=$(digest_of "${image_repo}:${version}-windows-${t}") || die "${image_repo}:${version}-windows-${t} is not on the registry: the Windows ${t} job did not push it"
    digests+=("${w}")
    members+=(-m "${image_repo}@${w}")
  done
  say "join the Linux index ${linux:0:19} and the Windows images ${digests[*]:1}"
  craned index append -t "${image_repo}:${version}" "${members[@]}" > /dev/null
  idx=$(digest_of "${image_repo}:${version}")
  say "${image_repo}:${version} is ${idx}"
  check_index "${image_repo}@${idx}"
  printf '%s\n' "${idx}" > "${out}/index.digest"
  sign_all "${digests[@]}" "${idx}"
}

# edge: the tag edge follows main, once the tests of the pipeline have passed. A pipeline of an older commit (a newer one is already on main) must
# not move it back. The signature is checked first, as the release does, so edge never names an image that main did not sign.
edge() {
  have_credentials || { no_credentials; return 0; }
  local idx main_sha
  login
  idx=$(image_digest) || die "${image_repo}:${version} is not on the registry: the job that assembles it did not run"
  verify_signature "${idx}"
  [ -n "${PROXY_IMAGE_MAIN_REF:-}" ] || git fetch --quiet origin main 2> /dev/null || true
  main_sha=$(git rev-parse --verify --quiet "${PROXY_IMAGE_MAIN_REF:-origin/main}" || true)
  if [ -n "${main_sha}" ] && [ "${main_sha}" != "${sha}" ] && git merge-base --is-ancestor "${sha}" "${main_sha}"; then
    say "edge stays where it is: ${main_sha:0:12} is on main after this commit and publishes its own"
  else
    craned tag "${image_repo}@${idx}" edge
    say "${image_repo}:edge is ${idx}"
  fi
}

image_digest() { digest_of "${image_repo}:${version}"; }

# rehearse: everything that main does to sign, on a throwaway image, in every pipeline. The OIDC token needs no context (any job of any branch gets
# one), the registry is a registry:2 container of the job and needs no credential, and what is signed is a layer of one file. It runs the code of
# the real publication (sign_all and verify_signature, so cosign sign, cosign verify, the certificate identity and the ref of the certificate), against
# the real Fulcio and Rekor, so that a change in them, in the claims of CircleCI's token or in this script fails a pull request and not the first merge.
# The ref that the certificate must name is the branch of this pipeline; then the check is shown to fail for a ref that this pipeline is not on.
rehearse() {
  local reg=${REHEARSAL_REGISTRY:-localhost:5000} branch=${CIRCLE_BRANCH:?CIRCLE_BRANCH is not set: the rehearsal runs for a branch} work d n other out
  work=$(mktemp -d)
  trap 'rm -rf "${work}"' RETURN
  image_repo=${reg}/signing-rehearsal
  export PROXY_IMAGE_REGISTRY_INSECURE=1
  for _ in $(seq 1 30); do curl -fsS "http://${reg}/v2/" > /dev/null 2>&1 && break; sleep 1; done
  curl -fsS "http://${reg}/v2/" > /dev/null || die "the registry ${reg} does not answer: the job needs registry:2 as its second container"
  # an image of its own for every pipeline, so that no signature of an earlier run is on it
  printf 'signing rehearsal of %s, workflow %s, %s\n' "${sha}" "${CIRCLE_WORKFLOW_ID:-local}" "$(date -u +%FT%TZ)" > "${work}/rehearsal.txt"
  tar -C "${work}" -cf "${work}/layer.tar" rehearsal.txt
  craned append -t "${image_repo}:rehearsal" -f "${work}/layer.tar" > /dev/null 2>&1 || die "cannot push the throwaway image to ${reg}"
  d=$(digest_of "${image_repo}:rehearsal")
  say "throwaway image ${image_repo}@${d}"
  if [ "${PROXY_IMAGE_SIGN:-oidc}" = none ]; then say "signing skipped (PROXY_IMAGE_SIGN=none): the image was made, nothing more"; return 0; fi
  # Fulcio and Rekor are public services: a brief failure of theirs is retried, a failure of the check itself is not.
  for n in 1 2 3; do
    if (SIGN_EXPECT_REF="refs/heads/${branch}" sign_all "${d}"); then break; fi
    [ "${n}" -lt 3 ] || die "the rehearsal could not sign and verify ${image_repo}@${d} for refs/heads/${branch} in 3 attempts"
    say "attempt ${n} failed: trying again in 15 seconds"; sleep 15
  done
  say "signed and verified for refs/heads/${branch}"
  # The check must be able to fail: this signature is not one of another ref.
  other=refs/heads/not-${branch}
  [ "${branch}" = main ] || other=refs/heads/main
  if out=$(SIGN_EXPECT_REF="${other}" verify_signature "${d}" 2>&1); then
    die "the ref check accepted a signature of refs/heads/${branch} for ${other}: it does not check the ref"
  fi
  grep -q 'does not name' <<< "${out}" || die "the check of ${other} failed, but not on the ref: ${out}"
  say "the same signature is refused for ${other}: the ref check works"
}

# verify_signature DIGEST: keyless, against the pipeline definition that signed it (the release job and the publication are jobs of one pipeline
# definition), and for the ref SIGN_EXPECT_REF (default refs/heads/main). The identity is the same for every branch, so the ref in the certificate
# is what tells the image of main from one that a job of another branch signed. Every signature of the digest must name it (ci/tools.sh).
verify_signature() {
  local id ref=${SIGN_EXPECT_REF:-refs/heads/main}
  [ "${PROXY_IMAGE_SIGN:-oidc}" != none ] || return 0
  id="https://circleci.com/api/v2/projects/${CIRCLE_PROJECT_ID:?}/pipeline-definitions/${PIPELINE_DEFINITION_ID:?}"
  cosign verify --certificate-identity "${id}" --certificate-oidc-issuer "${oidc_issuer}" "${image_repo}@$1" > /dev/null ||
    die "the signature of ${image_repo}@$1 does not verify against ${id}"
  cosign download signature "${image_repo}@$1" | signed_only_on "${ref}" ||
    die "a signature of ${image_repo}@$1 does not name ${ref} as its source repository ref (OID 1.3.6.1.4.1.57264.1.14), or the certificate cannot be read"
}

release_tags() {
  local rel=${1:-} ver major minor idx existing t all
  local -a tags=()
  [[ ${rel} =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "release-tags wants a version such as v1.2.3, got '${rel}'"
  ver=${rel#v}
  major=${BASH_REMATCH[1]}
  minor=${BASH_REMATCH[2]}
  have_credentials || die "release-tags needs DOCKERHUB_USERNAME and DOCKERHUB_TOKEN"
  idx=$(image_digest) || die "${image_repo}:${version} is not on the registry: the publication of the image of this commit did not run"
  verify_signature "${idx}"
  login
  # the tag X.Y.Z never moves
  if existing=$(digest_of "${image_repo}:${ver}" 2> /dev/null); then
    [ "${existing}" = "${idx}" ] || die "${image_repo}:${ver} exists and is ${existing}, not ${idx} (the image of ${version}): a release tag never moves"
  fi
  tags+=("${ver}")
  all=$(printf '%s\n' "${PROXY_IMAGE_RELEASE_TAGS:-$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*')}" "${rel}" | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -uV)
  newest() { printf '%s\n' "${all}" | grep -E "$1" | tail -n 1; }   # the highest version that matches a pattern
  [ "$(newest "^${major}\\.${minor}\\.")" != "${ver}" ] || tags+=("${major}.${minor}")
  [ "$(newest "^${major}\\.")" != "${ver}" ] || tags+=("${major}")
  [ "$(newest '.')" != "${ver}" ] || tags+=(latest)
  for t in "${tags[@]}"; do
    craned tag "${image_repo}@${idx}" "${t}"
  done
  say "${image_repo}@${idx} is now ${tags[*]}"
}

case "${1:-}" in
  digest) image_digest ;;
  release-tags) release_tags "${2:-}" ;;
  setup) setup ;;
  test) setup; test_images ;;
  push) push ;;
  assemble) assemble ;;
  edge) edge ;;
  rehearse) rehearse ;;
  credentials) have_credentials && say "the Docker Hub credentials are set" || no_credentials ;;
  install-tools) install_cosign; install_crane; crane version; cosign version 2>&1 | grep -E '^GitVersion' ;;
  *) die "usage: ci/proxy-image.sh setup | test | push | assemble | edge | rehearse | credentials | digest | release-tags vX.Y.Z | install-tools" ;;
esac
