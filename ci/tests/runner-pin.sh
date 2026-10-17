#!/usr/bin/env bash
# runner-pin.sh test: check_runner_pin of ci/release.sh. The stack files pin one runner version and a comma-separated list of tarball
# SHA-256 values; the release job checks that every stack file agrees on the version and that each list matches CircleCI's manifest for that
# pin (RELEASE_RUNNER_MANIFEST supplies a local manifest.json in tests). Needs bash and python3 only; no network, no secret.
#
# Usage: ci/tests/runner-pin.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "${here}/../.." && pwd)
# shellcheck source=ci/release.sh
. "${repo}/ci/release.sh"
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
failed=0
rows=0

pin=3.1.13
linux_sha=cc02803cc8367b404a7ceb7810afea23a22526ebc478ac4e8de7c585c9fbfe77,2763ff1d7241ce380cdf88130d60a8a12610811356d5cd7f948e6e853b0daaf3,980b9099a2af792c2cef3e9629907811cf269d12a7a3152464d1c72b619f3f51,743bc959480cf5e172944a29d99425863b8cadfd256c6553f332952393d5f4e8
win_sha=d0dd82447266a9dec0f9b31f63b3a276b1dc49121c61284c4e8ca1fa393936da,6a85ea6bb2862ebee3739607b416536e6d5b2f93c867f5d093d0e414e7d6d64e
zero=0000000000000000000000000000000000000000000000000000000000000000

write_stack() {
  local root=$1 lpin=$2 lsha=$3 wpin=$4 wsha=$5
  mkdir -p "${root}/linux/stack" "${root}/windows/stack"
  for f in runners.yaml microvm.yaml; do
    printf '%s\n' \
      "  MACHINE_RUNNER_SWARM_RUNNER_VERSION: \${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-${lpin}}" \
      "  MACHINE_RUNNER_SWARM_RUNNER_SHA256: \${MACHINE_RUNNER_SWARM_RUNNER_SHA256:-${lsha}}" \
      > "${root}/linux/stack/${f}"
  done
  printf '%s\n' \
    "  MACHINE_RUNNER_SWARM_RUNNER_VERSION: \${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-${wpin}}" \
    "  MACHINE_RUNNER_SWARM_RUNNER_SHA256: \${MACHINE_RUNNER_SWARM_RUNNER_SHA256:-${wsha}}" \
    > "${root}/windows/stack/runners.yaml"
}

write_manifest() {
  local path=$1 vers=$2
  python3 -c '
import json, sys
vers, path = sys.argv[1], sys.argv[2]
linux = {
    "amd64": {"sha256": "cc02803cc8367b404a7ceb7810afea23a22526ebc478ac4e8de7c585c9fbfe77"},
    "arm64": {"sha256": "2763ff1d7241ce380cdf88130d60a8a12610811356d5cd7f948e6e853b0daaf3"},
    "ppc64le": {"sha256": "980b9099a2af792c2cef3e9629907811cf269d12a7a3152464d1c72b619f3f51"},
    "s390x": {"sha256": "743bc959480cf5e172944a29d99425863b8cadfd256c6553f332952393d5f4e8"},
}
windows = {
    "amd64": {"sha256": "d0dd82447266a9dec0f9b31f63b3a276b1dc49121c61284c4e8ca1fa393936da"},
    "arm64": {"sha256": "6a85ea6bb2862ebee3739607b416536e6d5b2f93c867f5d093d0e414e7d6d64e"},
}
releases = {v: {"linux": linux, "windows": windows} for v in vers.split(",")}
json.dump({"releases": releases}, open(path, "w"))
' "${vers}" "${path}"
}

# row NAME WANT ROOT MANIFEST  (check_runner_pin in ROOT with RELEASE_RUNNER_MANIFEST=MANIFEST)
row() {
  local name=$1 want=$2 root=$3 manifest=$4 got=ok
  rows=$((rows + 1))
  if ( cd "${root}" && RELEASE_RUNNER_MANIFEST="${manifest}" check_runner_pin ) > "${work}/out" 2>&1; then
    :
  else
    got=fail
  fi
  if [ "${got}" = "${want}" ]; then
    echo "ok   ${name}: ${got}"
  else
    echo "FAIL ${name}: ${got}, want ${want}"
    sed 's/^/    /' "${work}/out" | tail -n 5
    failed=$((failed + 1))
  fi
}

said() {
  rows=$((rows + 1))
  if grep -qF -- "$1" "${work}/out"; then
    echo "ok   ... and says '$1'"
  else
    echo "FAIL the output has no '$1'"
    sed 's/^/    /' "${work}/out" | tail -n 5
    failed=$((failed + 1))
  fi
}

good="${work}/good"
write_stack "${good}" "${pin}" "${linux_sha}" "${pin}" "${win_sha}"
write_manifest "${good}/manifest.json" "${pin}"

bad_linux="${work}/bad-linux"
write_stack "${bad_linux}" "${pin}" "${zero},${linux_sha#*,}" "${pin}" "${win_sha}"
write_manifest "${bad_linux}/manifest.json" "${pin}"

short_win="${work}/short-win"
write_stack "${short_win}" "${pin}" "${linux_sha}" "${pin}" "${win_sha%%,*}"
write_manifest "${short_win}/manifest.json" "${pin}"

diff_ver="${work}/diff-ver"
write_stack "${diff_ver}" "${pin}" "${linux_sha}" 3.1.14 "${win_sha}"
write_manifest "${diff_ver}/manifest.json" "${pin},3.1.14"

no_pin="${work}/no-pin"
write_stack "${no_pin}" 9.9.9 "${linux_sha}" 9.9.9 "${win_sha}"
write_manifest "${no_pin}/manifest.json" "${pin}"

wrong_order="${work}/wrong-order"
IFS=',' read -r l_amd64 l_arm64 l_ppc64le l_s390x <<< "${linux_sha}"
write_stack "${wrong_order}" "${pin}" "${l_arm64},${l_amd64},${l_ppc64le},${l_s390x}" "${pin}" "${win_sha}"
write_manifest "${wrong_order}/manifest.json" "${pin}"

row "every stack file matches the manifest" ok "${good}" "${good}/manifest.json"
row "a wrong Linux amd64 hash" fail "${bad_linux}" "${bad_linux}/manifest.json"
said "linux/amd64"
said "bump the runner pin and its SHA-256 list together (docs/releasing.md)"
row "a Windows list that is too short" fail "${short_win}" "${short_win}/manifest.json"
said "windows"
said "bump the runner pin and its SHA-256 list together (docs/releasing.md)"
row "different pins in two stack files" fail "${diff_ver}" "${diff_ver}/manifest.json"
said "they must be equal"
row "a pin that is not in the manifest" fail "${no_pin}" "${no_pin}/manifest.json"
said "is not in the manifest"
row "Linux hashes in the wrong order" fail "${wrong_order}" "${wrong_order}/manifest.json"
said "linux/amd64"
said "bump the runner pin and its SHA-256 list together (docs/releasing.md)"

echo "RESULT test=runner-pin rows=${rows} failed=${failed}"
[ "${failed}" -eq 0 ] || exit 1
echo "PASS (the runner pin and its SHA-256 lists)"
