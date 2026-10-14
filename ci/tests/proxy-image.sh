#!/usr/bin/env bash
# proxy-image.sh test: the publication of the token proxy image (ci/proxy-image.sh push, assemble, digest and release-tags) against a registry
# of its own (registry:2 on localhost), with no credential and no signature. It builds the real Linux image for the four platforms, and
# stands in two Windows images (a Windows image cannot be built here) with the same names that ci/Build-ProxyImage.ps1 pushes. Checks:
#   - push        one index with the four Linux platforms, tagged sha-<12>-linux
#   - assemble    one manifest list with the four Linux platforms and both Windows images, tagged sha-<12> and edge, by the digests that were pushed
#   - older       a commit that is not the newest on main makes its sha-<12> tag and leaves edge where it is
#   - missing     a Windows image that was not pushed stops the assembly (no tag is made from a part)
#   - digest      the digest of the image of a commit is what the release pins
#   - release     X.Y.Z, X.Y, X and latest for a first release; a newer patch moves the floating tags and leaves X.Y.Z of the old one; an old
#                 release finished late moves nothing but its own tag; an X.Y.Z that is another image is refused
#   - credentials without DOCKERHUB_USERNAME and DOCKERHUB_TOKEN, push and assemble say that nothing was pushed, and exit 0
#
# Usage: ci/tests/proxy-image.sh      Needs Docker (buildx, QEMU for the other platforms: ci/proxy-image.sh setup), crane, and a git history.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
export PATH="${CI_TOOLS_BIN:-${RELEASE_BIN:-${HOME}/.local/bin}}:${PATH}"
repo_dir=$(cd "${here}/../.." && pwd)
cd "${repo_dir}"
script=${repo_dir}/ci/proxy-image.sh
registry_image=registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373
name=proxy-image-test-$$
work=$(mktemp -d)
failed=0
git rev-parse --verify --quiet HEAD~1 > /dev/null || { echo "the test needs a history of two commits"; exit 1; }
newer=$(git rev-parse HEAD)
older=$(git rev-parse HEAD~1)

cleanup() { docker rm -f "${name}" > /dev/null 2>&1 || true; git update-ref -d refs/proxy-image-test/main 2> /dev/null || true; rm -rf "${work}"; }
trap cleanup EXIT

say() { printf '[proxy-image-test] %s\n' "$*"; }
check() { # NAME COMMAND...
  local n=$1; shift
  if "$@" > "${work}/check.out" 2>&1; then
    printf 'CHECK %s PASS\n' "${n}"
  else
    printf 'CHECK %s FAIL\n' "${n}"
    sed 's/^/    /' "${work}/check.out" | tail -n 15
    failed=$((failed + 1))
  fi
}

# the registry, on a free port of the loopback
docker run -d --name "${name}" -p 127.0.0.1::5000 "${registry_image}" > /dev/null
port=$(docker port "${name}" 5000/tcp | head -n 1 | sed 's/.*://')
export PROXY_IMAGE_REPO=localhost:${port}/proxy PROXY_IMAGE_REGISTRY_INSECURE=1 PROXY_IMAGE_SIGN=none PROXY_IMAGE_OUT=${work}/out
export PROXY_IMAGE_BUILDER=proxy-image-test-builder PROXY_IMAGE_MAIN_REF=refs/proxy-image-test/main
repo=${PROXY_IMAGE_REPO}
crane() { command crane --insecure "$@"; }
for _ in $(seq 1 30); do curl -fsS "http://localhost:${port}/v2/" > /dev/null 2>&1 && break; sleep 1; done

"${script}" setup > /dev/null
trap 'docker buildx rm --force "${PROXY_IMAGE_BUILDER}" > /dev/null 2>&1 || true; cleanup' EXIT

# --- no credentials: nothing is pushed, and the job stays green ---------------------------------------------------------------
no_creds() {
  local o
  o=$(env -u DOCKERHUB_USERNAME -u DOCKERHUB_TOKEN CIRCLE_SHA1="${newer}" "${script}" push 2>&1) && [[ ${o} == *"NOT PUSHED"* ]] || { echo "push: ${o}"; return 1; }
  o=$(env -u DOCKERHUB_USERNAME -u DOCKERHUB_TOKEN CIRCLE_SHA1="${newer}" "${script}" assemble 2>&1) && [[ ${o} == *"NOT PUSHED"* ]] || { echo "assemble: ${o}"; return 1; }
  ! crane ls "${repo}" 2> /dev/null | grep -q .
}
check no-credentials-push-nothing no_creds

export DOCKERHUB_USERNAME=test DOCKERHUB_TOKEN=test
short_new=${newer:0:12}
short_old=${older:0:12}

# --- push: the Linux index ------------------------------------------------------------------------------------------------------
say "ci/proxy-image.sh push (the four Linux platforms)"
CIRCLE_SHA1=${newer} "${script}" push > "${work}/push.log" 2>&1 || { tail -n 20 "${work}/push.log"; echo "push failed"; exit 1; }
linux_index() {
  crane manifest "${repo}:sha-${short_new}-linux" | python3 -c '
import json, sys
d = json.load(sys.stdin)
got = sorted(m["platform"]["os"] + "/" + m["platform"]["architecture"] for m in d["manifests"])
want = ["linux/amd64", "linux/arm64", "linux/ppc64le", "linux/s390x"]
if got != want:
    sys.exit("platforms %s, want %s" % (got, want))'
}
check push-linux-index linux_index
[ "$(cat "${work}/out/linux.digest")" = "$(crane digest "${repo}:sha-${short_new}-linux")" ] || { echo "the digest file does not name what was pushed"; failed=$((failed + 1)); }

# --- the Windows images that ci/Build-ProxyImage.ps1 would push (stand-ins, with the platform of a Windows image) ---------------------
fake_windows() { # SHORT: both tags of a commit
  local t
  for t in ltsc2022 ltsc2025; do
    echo "$1 ${t}" > "${work}/marker"   # each image has its own content, so its own digest
    printf 'FROM scratch\nCOPY marker /marker\n' | docker buildx build --builder "${PROXY_IMAGE_BUILDER}" --platform windows/amd64 --provenance=false --sbom=false \
      -f - --output "type=image,name=${repo}:sha-$1-windows-${t},push=true" "${work}" > /dev/null 2>&1
  done
}
fake_windows "${short_new}"

# --- assemble ---------------------------------------------------------------------------------------------------------------------
say "ci/proxy-image.sh assemble"
CIRCLE_SHA1=${newer} "${script}" assemble > "${work}/assemble.log" 2>&1 || { tail -n 20 "${work}/assemble.log"; echo "assemble failed"; exit 1; }
sed 's/^/    /' "${work}/assemble.log" | tail -n 12
joined() { # the list holds exactly the manifests of the Linux index and the two Windows images
  python3 - "${work}" "${repo}" "${short_new}" << 'PY'
import json, subprocess, sys
work, repo, short = sys.argv[1:4]
def manifest(ref):
    return json.loads(subprocess.check_output(["crane", "--insecure", "manifest", ref]))
def digest(ref):
    return subprocess.check_output(["crane", "--insecure", "digest", ref]).decode().strip()
want = {m["digest"] for m in manifest("%s:sha-%s-linux" % (repo, short))["manifests"]}
want |= {digest("%s:sha-%s-windows-%s" % (repo, short, t)) for t in ("ltsc2022", "ltsc2025")}
got = {m["digest"] for m in manifest("%s:sha-%s" % (repo, short))["manifests"]}
if got != want:
    sys.exit("the list holds %d manifests, want %d; missing %s, extra %s" % (len(got), len(want), sorted(want - got), sorted(got - want)))
PY
}
check assemble-joins-the-three-pushes joined
same_tag() { [ "$(crane digest "${repo}:sha-${short_new}")" = "$(crane digest "${repo}:$1")" ]; }
check edge-is-the-new-image same_tag edge
idx_new=$(crane digest "${repo}:sha-${short_new}")
[ "$(cat "${work}/out/index.digest")" = "${idx_new}" ] || { echo "index.digest is not the digest of sha-${short_new}"; failed=$((failed + 1)); }
digest_cmd() { [ "$(CIRCLE_SHA1=${newer} "${script}" digest)" = "${idx_new}" ]; }
check digest-subcommand digest_cmd
no_digest() { ! CIRCLE_SHA1=0123456789abcdef0123456789abcdef01234567 "${script}" digest 2> /dev/null; }
check digest-of-a-commit-that-was-never-published no_digest

# --- an older commit: its tag, and edge stays ----------------------------------------------------------------------------------------
git update-ref refs/proxy-image-test/main "${newer}"
for t in linux windows-ltsc2022 windows-ltsc2025; do crane tag "${repo}:sha-${short_new}-${t}" "sha-${short_old}-${t}"; done
CIRCLE_SHA1=${older} "${script}" assemble > "${work}/assemble-old.log" 2>&1 || { tail -n 20 "${work}/assemble-old.log"; echo "assemble of the older commit failed"; exit 1; }
older_commit() {
  [ -n "$(crane digest "${repo}:sha-${short_old}")" ] && grep -q 'edge stays where it is' "${work}/assemble-old.log" && [ "$(crane digest "${repo}:edge")" = "${idx_new}" ]
}
check older-commit-keeps-edge older_commit

# --- a part is missing --------------------------------------------------------------------------------------------------------------
missing_part() {
  local fake=0123456789abcdef0123456789abcdef01234567
  crane tag "${repo}:sha-${short_new}-linux" "sha-${fake:0:12}-linux"
  crane tag "${repo}:sha-${short_new}-windows-ltsc2022" "sha-${fake:0:12}-windows-ltsc2022"   # ltsc2025 was never pushed
  ! CIRCLE_SHA1=${fake} "${script}" assemble > "${work}/assemble-part.log" 2>&1 && grep -q 'windows-ltsc2025 is not on the registry' "${work}/assemble-part.log" &&
    ! crane digest "${repo}:sha-${fake:0:12}" > /dev/null 2>&1
}
check a-missing-windows-image-stops-the-assembly missing_part

# --- release tags -----------------------------------------------------------------------------------------------------------------------
tags_of_image() { # the release tags that name the image of the newer commit
  local t out=
  for t in "$@"; do if [ "$(crane digest "${repo}:${t}" 2> /dev/null || true)" = "${idx_new}" ]; then out="${out}${t} "; fi; done
  echo "${out% }"
}
release() { # RELEASE EXISTING_TAGS...
  local rel=$1; shift
  CIRCLE_SHA1=${newer} PROXY_IMAGE_RELEASE_TAGS=$(printf '%s\n' "$@") "${script}" release-tags "${rel}"
}
first_release() {
  release v0.1.0 v0.1.0 > "${work}/rel.log" 2>&1 || { cat "${work}/rel.log"; return 1; }
  [ "$(tags_of_image 0.1.0 0.1 0 latest)" = "0.1.0 0.1 0 latest" ]
}
check first-release-gets-X.Y.Z-X.Y-X-and-latest first_release
# a second image for the newer patch (another commit): the floating tags move to it, 0.1.0 stays
idx_other=
other_image() {
  # the older commit's image is the same digest here (a retag), so make a different one: an index of the Linux part only
  crane index append -t "${repo}:sha-other" -m "${repo}:sha-${short_new}-windows-ltsc2022" > /dev/null
  idx_other=$(crane digest "${repo}:sha-other")
  crane tag "${repo}:sha-other" "sha-${short_old}"
  [ "${idx_other}" != "${idx_new}" ]
}
check a-second-image-for-the-next-release other_image
next_patch() {
  CIRCLE_SHA1=${older} PROXY_IMAGE_RELEASE_TAGS=$(printf '%s\n' v0.1.0 v0.1.1) "${script}" release-tags v0.1.1 > "${work}/rel2.log" 2>&1 || { cat "${work}/rel2.log"; return 1; }
  [ "$(crane digest "${repo}:0.1.1")" = "${idx_other}" ] && [ "$(crane digest "${repo}:0.1")" = "${idx_other}" ] && [ "$(crane digest "${repo}:0")" = "${idx_other}" ] &&
    [ "$(crane digest "${repo}:latest")" = "${idx_other}" ] && [ "$(crane digest "${repo}:0.1.0")" = "${idx_new}" ]
}
check next-patch-moves-the-floating-tags-and-not-the-old-version next_patch
late_old_release() { # the newer commit's release is finished again after 0.1.1 exists: only its own tag
  release v0.1.0 v0.1.0 v0.1.1 > "${work}/rel3.log" 2>&1 || { cat "${work}/rel3.log"; return 1; }
  [ "$(crane digest "${repo}:latest")" = "${idx_other}" ] && [ "$(crane digest "${repo}:0.1")" = "${idx_other}" ] && [ "$(crane digest "${repo}:0.1.0")" = "${idx_new}" ]
}
check an-old-release-finished-late-moves-nothing-else late_old_release
new_minor() { # 0.2.0 is the newest of its own line, and of all: 0.1 stays
  release v0.2.0 v0.1.0 v0.1.1 v0.2.0 > "${work}/rel4.log" 2>&1 || { cat "${work}/rel4.log"; return 1; }
  [ "$(crane digest "${repo}:0.2")" = "${idx_new}" ] && [ "$(crane digest "${repo}:latest")" = "${idx_new}" ] && [ "$(crane digest "${repo}:0")" = "${idx_new}" ] &&
    [ "$(crane digest "${repo}:0.1")" = "${idx_other}" ]
}
check a-new-minor-keeps-the-old-minor-line new_minor
immutable() { # 0.1.0 is the newer image: another image under that version is refused
  ! CIRCLE_SHA1=${older} PROXY_IMAGE_RELEASE_TAGS=$(printf '%s\n' v0.1.0) "${script}" release-tags v0.1.0 > "${work}/rel5.log" 2>&1 &&
    grep -q 'a release tag never moves' "${work}/rel5.log" && [ "$(crane digest "${repo}:0.1.0")" = "${idx_new}" ]
}
check an-existing-X.Y.Z-is-never-moved immutable
bad_version() { ! "${script}" release-tags 1.2 > /dev/null 2>&1 && ! "${script}" release-tags v1.2.3-rc1 > /dev/null 2>&1; }
check a-version-that-is-not-X.Y.Z-is-refused bad_version

echo "RESULT test=proxy-image failed=${failed}"
[ "${failed}" -eq 0 ] || exit 1
echo "PASS (the publication of the token proxy image: push, assemble, digest and release tags)"
