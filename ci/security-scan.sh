#!/usr/bin/env bash
# security-scan.sh: the weekly security scan (docs/ci.md, "Security scan"). The workflow `security-scan` of
# .circleci/continue.yml runs it, on a schedule.
#
#   ci/security-scan.sh images   Trivy on every image that the repository pins; fails on a HIGH or CRITICAL finding that has a fix
#   ci/security-scan.sh go       govulncheck on proxy/; fails on a vulnerability that the proxy calls and that has a fix
#   ci/security-scan.sh refs     print the image references that `images` scans, one per line (no scan)
#
# Which images: a reference of any tracked file that carries a digest (name[:tag]@sha256:...: .circleci/*.yml, ci/, the stack
# files, the tests), and the `image:` of every stack file (linux/stack, windows/stack): tags without a digest (CoreDNS,
# alpine:3.24, the cimg classes) are scanned too. Windows images are listed and skipped: Trivy finds no operating system in
# them when it runs on Linux, so a scan would only say "clean". Placeholders (registry.example.com, ${VARIABLES}) are not images.
# The list comes from the files, so a bump by Renovate is scanned in the next run and nobody keeps a second list.
#
# A finding with no fix yet is reported (counted per image) and does not fail the run. .trivyignore applies, with its expiry
# dates: add an entry there for a finding that cannot be fixed here (the policy is in that file).
#
# Environment:
#   TRIVY_IMAGE    the Trivy image, with its digest (the job sets it). It runs through `docker run`.
#   TRIVY_BIN      a Trivy binary to run instead (for a workstation without the image)
#   SCAN_OUT       the directory of the reports (default /tmp/reports): one JSON file per image, and the summary of each command
#
# Never run this with `set -x`: nothing here is secret, but the job log is public.
set -euo pipefail

out="${SCAN_OUT:-/tmp/reports}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

refs() {
  cd "$(git rev-parse --show-toplevel)"
  {
    git ls-files -z -- '*.yml' '*.yaml' '*.sh' '*.ps1' '*.md' \
      | xargs -0 grep -hoE '[a-z0-9][a-z0-9._/-]*[a-z0-9](:[A-Za-z0-9][A-Za-z0-9._-]*)?@sha256:[a-f0-9]{64}' || true
    git ls-files -z -- 'linux/stack/*.yaml' 'windows/stack/*.yaml' \
      | xargs -0 sed -nE 's/^[[:space:]]+image:[[:space:]]+([^[:space:]#]+).*/\1/p'
  } | grep -vE '[$]|^registry\.example\.com/|^localhost[:/]' | sort -u
}

run_trivy() {
  if [ -n "${TRIVY_BIN:-}" ]; then
    "${TRIVY_BIN}" "$@"
  else
    [ -n "${TRIVY_IMAGE:-}" ] || die "TRIVY_IMAGE is not set (or set TRIVY_BIN)"
    mkdir -p "${HOME}/trivy/cache"
    docker run --rm -v "${HOME}/trivy:/trivy" -v "${out}:/reports" -v "${PWD}/.trivyignore:/work/.trivyignore:ro" -w /work \
      -e TRIVY_NO_PROGRESS=true -e TRIVY_CACHE_DIR=/trivy/cache "${TRIVY_IMAGE}" "$@"
  fi
}

# scan_image REF: one JSON report; prints one line, and the findings that have a fix. Returns 1 when there are some.
scan_image() {
  local ref=$1 name json rep fixable unfixed
  name=$(printf '%s' "${ref}" | tr -c 'A-Za-z0-9._-' '_')
  rep="${out}/trivy-${name}.json"
  if [ -n "${TRIVY_BIN:-}" ]; then json=${rep}; else json=/reports/trivy-${name}.json; fi
  if ! run_trivy image --image-src remote --scanners vuln --severity HIGH,CRITICAL --ignorefile .trivyignore \
      --format json --output "${json}" --quiet --no-progress "${ref}" > "${out}/trivy-${name}.log" 2>&1; then
    # Trivy could not pull or read the image: a pinned image that cannot be scanned is a finding too.
    printf 'ERROR %s: trivy failed (%s)\n' "${ref}" "$(tail -n 1 "${out}/trivy-${name}.log" | cut -c1-200)"
    return 1
  fi
  fixable=$(jq '[.Results[]? | .Vulnerabilities[]? | select((.FixedVersion // "") != "")] | length' "${rep}")
  unfixed=$(jq '[.Results[]? | .Vulnerabilities[]? | select((.FixedVersion // "") == "")] | length' "${rep}")
  if [ "${fixable}" -eq 0 ]; then
    printf 'ok    %s: no HIGH or CRITICAL finding with a fix (%s without a fix yet)\n' "${ref}" "${unfixed}"
    return 0
  fi
  printf 'FIX   %s: %s HIGH or CRITICAL finding(s) with a fix (%s without a fix yet)\n' "${ref}" "${fixable}" "${unfixed}"
  jq -r '[.Results[]? | .Target as $t | .Vulnerabilities[]? | select((.FixedVersion // "") != "")
          | "      \(.Severity) \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion) (\($t))"]
         | unique | .[:12][]' "${rep}"
  return 1
}

scan_images() {
  local ref bad=0 count=0 list
  cd "$(git rev-parse --show-toplevel)"
  list=$(refs)
  [ -n "${list}" ] || die "no pinned image found: the discovery is broken"
  say "Images that the repository pins:"
  printf '%s\n' "${list}" | sed 's/^/  /'
  say "Trivy, HIGH and CRITICAL findings with a fix fail the run"
  while IFS= read -r ref; do
    case ${ref} in
      mcr.microsoft.com/windows/*)
        printf 'skip  %s: a Windows image (Trivy finds no operating system in it on Linux)\n' "${ref}"
        continue ;;
    esac
    count=$((count + 1))
    scan_image "${ref}" || bad=$((bad + 1))
  done <<< "${list}"
  say "${count} images scanned, ${bad} with a finding that has a fix (the reports are in ${out})"
  [ "${bad}" -eq 0 ]
}

# The vulnerabilities that the proxy calls, with a fixed version: the same rule as `govulncheck` with no flag, plus the fix.
scan_go() {
  # renovate: datasource=go depName=golang.org/x/vuln
  local govulncheck_version=v1.9.0
  local gobin; gobin="$(mktemp -d)"
  say "Install govulncheck ${govulncheck_version} (go ${GOVERSION:-$(go env GOVERSION)})"
  GOBIN="${gobin}" go install "golang.org/x/vuln/cmd/govulncheck@${govulncheck_version}"
  say "govulncheck on proxy/ (source mode: only a vulnerable function that the proxy calls counts)"
  (cd "$(git rev-parse --show-toplevel)/proxy" && "${gobin}/govulncheck" -format json ./... > "${out}/govulncheck-proxy.json")
  rm -rf "${gobin}"
  jq -s -r '
    [.[] | select(.finding) | .finding | select((.fixed_version // "") != "" and .trace[0].function != null)
     | {osv, module: .trace[0].module, fixed: .fixed_version}] | unique
    | if length == 0 then "ok    no vulnerability with a fix is called by the proxy"
      else (length | tostring) + " vulnerabilit" + (if length == 1 then "y" else "ies" end) + " with a fix called by the proxy:",
           (.[] | "      \(.osv) in \(.module), fixed in \(.fixed) (https://pkg.go.dev/vuln/\(.osv))") end' "${out}/govulncheck-proxy.json"
  jq -s -e '[.[] | select(.finding) | .finding | select((.fixed_version // "") != "" and .trace[0].function != null)] | length == 0' \
    "${out}/govulncheck-proxy.json" > /dev/null
}

mkdir -p "${out}"
case "${1:-}" in
  images) scan_images 2>&1 | tee "${out}/summary-images.txt" ;;
  go) scan_go 2>&1 | tee "${out}/summary-go.txt" ;;
  refs) refs ;;
  *) die "usage: ci/security-scan.sh images|go|refs" ;;
esac
