#!/usr/bin/env bash
# security-scan.sh test: ci/security-scan.sh scan_image verdict when Trivy cannot scan an image. A stub Trivy that always
# fails makes an infra image fail the images command; a report-only image still passes. Needs bash and jq only.
#
# Usage: ci/tests/security-scan.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "${here}/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/reports"
cat > "${tmp}/bin/trivy" <<'EOF'
#!/usr/bin/env bash
echo "stub: trivy cannot scan" >&2
exit 1
EOF
chmod +x "${tmp}/bin/trivy"

failed=0
rows=0
check() {
  local name=$1 want=$2 got=$3
  rows=$((rows + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL ${name}: got '${got}', want '${want}'"
    failed=$((failed + 1))
  else
    echo "ok   ${name}"
  fi
}

# shellcheck source=/dev/null
. <(sed -n '34,74p;79,118p' "${repo}/ci/security-scan.sh")
out="${tmp}/reports"
export TRIVY_BIN="${tmp}/bin/trivy"
infra_n=0 infra_failing=0 infra_unscannable=0 infra_high=0 report_n=0 report_crit=0 report_high=0
rc=0
scan_image "alpine:3.24@sha256:0000000000000000000000000000000000000000000000000000000000000001" infra || rc=$?
check "infra unscannable returns 1" 1 "${rc}"
check "infra unscannable counted" "1" "${infra_unscannable}"
check "infra failing (CRITICAL) unchanged" "0" "${infra_failing}"

infra_n=0 infra_failing=0 infra_unscannable=0
rc=0
scan_image "cimg/base:2026.10@sha256:0000000000000000000000000000000000000000000000000000000000000002" report || rc=$?
check "report-only unscannable returns 0" 0 "${rc}"
check "report-only does not increment infra unscannable" "0" "${infra_unscannable}"

rc=0
TRIVY_BIN="${tmp}/bin/trivy" SCAN_OUT="${tmp}/reports" PATH="${tmp}/bin:${PATH}" \
  "${repo}/ci/security-scan.sh" images > "${tmp}/summary.txt" 2>&1 || rc=$?
check "images with failing trivy exits 1" 1 "${rc}"
grep -q 'unscannable' "${tmp}/summary.txt" || { echo "FAIL summary line mentions unscannable"; failed=$((failed + 1)); rows=$((rows + 1)); }

echo "RESULT test=security-scan rows=${rows} failed=${failed}"
if [ "$failed" -eq 0 ]; then echo "PASS (${rows} rows)"; else echo "FAIL: ${failed} row(s)"; exit 1; fi
