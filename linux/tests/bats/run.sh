#!/usr/bin/env bash
# Run the entrypoint unit tests (entrypoint.bats) as root inside stock images.
#   run.sh                 the default matrix: cimg/base (dash), Alpine (BusyBox ash) and UBI 9 minimal (bash)
#   run.sh IMAGE [IMAGE..] only these images
# Each image gets sudo and util-linux (setpriv) installed first when it lacks them; the tests hide
# them again to exercise every path (sudo, setpriv, su fallback, neither). Needs network access for
# those packages. Prints one RESULT line per image and exits non-zero if any image fails.
set -euo pipefail

BATS_IMAGE=${BATS_IMAGE:-bats/bats:1.14.0}
repo=$(cd "$(dirname "$0")/../../.." && pwd)
images=("$@")
if [ ${#images[@]} -eq 0 ]; then
  images=("${SMR_CIMG_IMAGE:-cimg/base:2026.10}" "$BATS_IMAGE" "${SMR_UBI_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}")
fi

# Install what the image lacks. Runs inside the image as root.
# shellcheck disable=SC2016  # runs in the container's shell, not here
prep='
set -e
have() { command -v "$1" >/dev/null 2>&1; }
if have apt-get; then
  { have sudo && have setpriv; } || { apt-get update -q >/dev/null && apt-get install -y -q --no-install-recommends sudo util-linux >/dev/null; }
elif have apk; then
  apk add --no-cache sudo setpriv >/dev/null
elif have microdnf; then
  microdnf -y --setopt=install_weak_deps=0 --nodocs install sudo util-linux findutils >/dev/null 2>&1
fi'

work=$(mktemp -d)
cid=$(docker create "$BATS_IMAGE")
trap 'docker rm -f "$cid" >/dev/null 2>&1; rm -rf "$work"' EXIT
docker cp -q "$cid:/opt/bats" "$work/bats"

rc=0
for image in "${images[@]}"; do
  echo "== $image"
  if docker run --rm --user 0 --entrypoint sh \
    -v "$work/bats:/opt/bats:ro,z" -v "$repo:/src:ro,z" \
    "$image" -c "$prep; exec /opt/bats/bin/bats --print-output-on-failure ${BATS_ARGS:-} /src/linux/tests/bats"; then
    echo "RESULT bats image=$image status=pass"
  else
    echo "RESULT bats image=$image status=FAIL"
    rc=1
  fi
done
exit "$rc"
