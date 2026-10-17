#!/usr/bin/env bash
# require-credentials.sh test: a pipeline that must publish (REQUIRE_CREDENTIALS=true or 1, which the setup gate sets for main with both e2e tokens)
# fails when a publishing credential is missing, and every other pipeline skips the publication and stays green (docs/ci.md, "Publishing fails
# closed on main"). Covers require_credentials (ci/tools.sh), ci/proxy-image.sh (credentials, push, assemble, edge) and site/publish.sh. Needs bash
# only: no Docker, no network, and no secret (the credentials are made-up words).
#
# Usage: ci/tests/require-credentials.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "${here}/../.." && pwd)
# shellcheck source=ci/tools.sh
. "${repo}/ci/tools.sh"
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
failed=0
rows=0

# row NAME WANT COMMAND...: WANT is "ok" (exit 0) or "fail" (non-zero); the output is kept for the checks that follow
row() {
  local name=$1 want=$2 got=ok; shift 2
  rows=$((rows + 1))
  "$@" > "${work}/out" 2>&1 || got=fail
  if [ "${got}" = "${want}" ]; then echo "ok   ${name}: ${got}"; else echo "FAIL ${name}: ${got}, want ${want}"; sed 's/^/    /' "${work}/out" | tail -n 5; failed=$((failed + 1)); fi
}
said() { # the last command said TEXT
  rows=$((rows + 1))
  if grep -q -- "$1" "${work}/out"; then echo "ok   ... and says '$1'"; else echo "FAIL the output has no '$1'"; sed 's/^/    /' "${work}/out" | tail -n 5; failed=$((failed + 1)); fi
}

# require_credentials: only true and 1
for v in true 1; do
  row "require_credentials, REQUIRE_CREDENTIALS=${v}" ok env REQUIRE_CREDENTIALS="${v}" bash -c ". '${repo}/ci/tools.sh'; require_credentials"
done
for v in "" false 0 yes TRUE; do
  row "require_credentials, REQUIRE_CREDENTIALS='${v}'" fail env REQUIRE_CREDENTIALS="${v}" bash -c ". '${repo}/ci/tools.sh'; require_credentials"
done

# ci/proxy-image.sh: with no Docker Hub variable
nocreds() { env -u DOCKERHUB_USERNAME -u DOCKERHUB_TOKEN -u REQUIRE_CREDENTIALS "$@"; }
for cmd in credentials push assemble edge; do
  row "proxy-image.sh ${cmd}, no credentials, not required" ok nocreds "${repo}/ci/proxy-image.sh" "${cmd}"
  said "NOT PUSHED"
  row "proxy-image.sh ${cmd}, no credentials, REQUIRE_CREDENTIALS=true" fail nocreds REQUIRE_CREDENTIALS=true "${repo}/ci/proxy-image.sh" "${cmd}"
  said "must publish"
  row "proxy-image.sh ${cmd}, no credentials, REQUIRE_CREDENTIALS=1" fail nocreds REQUIRE_CREDENTIALS=1 "${repo}/ci/proxy-image.sh" "${cmd}"
  row "proxy-image.sh ${cmd}, only the user name, REQUIRE_CREDENTIALS=true" fail nocreds DOCKERHUB_USERNAME=made-up REQUIRE_CREDENTIALS=true "${repo}/ci/proxy-image.sh" "${cmd}"
done
row "proxy-image.sh credentials, both set, REQUIRE_CREDENTIALS=true" ok nocreds DOCKERHUB_USERNAME=made-up DOCKERHUB_TOKEN=made-up REQUIRE_CREDENTIALS=true "${repo}/ci/proxy-image.sh" credentials
# the values never reach the output
if grep -q made-up "${work}/out"; then echo "FAIL a credential value reached the output"; failed=$((failed + 1)); fi
rows=$((rows + 1))

# site/publish.sh: a copy of the script beside a made-up site, so that it needs no Hugo
mkdir -p "${work}/site/public"
cp "${repo}/site/publish.sh" "${work}/site/publish.sh"
echo '<html></html>' > "${work}/site/public/index.html"
publish() { env -u GITHUB_TOKEN -u REQUIRE_CREDENTIALS CIRCLE_SHA1=0123456789abcdef0123456789abcdef01234567 PUBLISH_REMOTE=https://example.invalid/none.git "$@" bash "${work}/site/publish.sh"; }
row "publish.sh, no GITHUB_TOKEN, not required" ok publish
said "skipped"
row "publish.sh, no GITHUB_TOKEN, REQUIRE_CREDENTIALS=true" fail publish REQUIRE_CREDENTIALS=true
said "must publish"
row "publish.sh, no GITHUB_TOKEN, REQUIRE_CREDENTIALS=1" fail publish REQUIRE_CREDENTIALS=1
row "publish.sh, no GITHUB_TOKEN, REQUIRE_CREDENTIALS=false" ok publish REQUIRE_CREDENTIALS=false

echo "RESULT test=require-credentials rows=${rows} failed=${failed}"
[ "${failed}" -eq 0 ] || exit 1
echo "PASS (a production main fails without its credentials, every other pipeline skips)"
