#!/usr/bin/env bash
# security-scan.sh: the weekly security scan (docs/ci.md, "Security scan"). The workflow `security-scan` of
# .circleci/continue.yml runs it, on a schedule.
#
#   ci/security-scan.sh images   Trivy on every image that the repository pins; fails only on a CRITICAL finding that has a fix,
#                                and reports the HIGH findings that have a fix (summary, one table and one JSON file per image)
#   ci/security-scan.sh go       govulncheck on proxy/; fails on any vulnerability that the proxy's code calls (code that we own)
#   ci/security-scan.sh refs     print the image references that `images` scans, one per line (no scan)
#
# Which images: a reference of any tracked file that carries a digest (name[:tag]@sha256:...: .circleci/*.yml, ci/, the stack
# files, the tests), and the `image:` of every stack file (linux/stack, windows/stack): tags without a digest (CoreDNS,
# alpine:3.24, the cimg classes) are scanned too. Windows images are listed and skipped: Trivy finds no operating system in
# them when it runs on Linux, so a scan would only say "clean". Placeholders (registry.example.com, ${VARIABLES}) are not images.
# The list comes from the files, so a bump by Renovate is scanned in the next run and nobody keeps a second list.
#
# What fails: a CRITICAL finding with a fixed version. What is only reported: a HIGH finding with a fixed version, and every
# finding with no fix yet (counted per image). Most pinned images carry some HIGH finding on any given week, from upstream
# packages and bundled Go binaries, so failing on them would keep the run red and teach nobody to look. An image that Trivy
# cannot pull also fails: a pin that cannot be scanned is a problem. .trivyignore applies, with its expiry dates.
# What to do about a failure: bump the digest (a Renovate pull request does it, docs/ci.md "Pinned versions"), or add a
# justified .trivyignore entry (the CVE, the reason, an owner and an expiry date; the policy is in that file).
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

# scan_image REF: one JSON report and one table of the findings that have a fix. Prints one line. Returns 1 when the image
# has a CRITICAL finding with a fix (or cannot be scanned); a HIGH finding is reported and returns 0. The counts go to $counts.
scan_image() {
  local ref=$1 name json rep table crit high unfixed
  name=$(printf '%s' "${ref}" | tr -c 'A-Za-z0-9._-' '_')
  rep="${out}/trivy-${name}.json"
  table="${out}/findings-${name}.txt"
  if [ -n "${TRIVY_BIN:-}" ]; then json=${rep}; else json=/reports/trivy-${name}.json; fi
  if ! run_trivy image --image-src remote --scanners vuln --severity HIGH,CRITICAL --ignorefile .trivyignore \
      --format json --output "${json}" --quiet --no-progress "${ref}" > "${out}/trivy-${name}.log" 2>&1; then
    printf 'ERROR %s: trivy failed (%s)\n' "${ref}" "$(tail -n 1 "${out}/trivy-${name}.log" | cut -c1-200)"
    return 1
  fi
  crit=$(jq '[.Results[]? | .Vulnerabilities[]? | select((.FixedVersion // "") != "" and .Severity == "CRITICAL")] | length' "${rep}")
  high=$(jq '[.Results[]? | .Vulnerabilities[]? | select((.FixedVersion // "") != "" and .Severity == "HIGH")] | length' "${rep}")
  unfixed=$(jq '[.Results[]? | .Vulnerabilities[]? | select((.FixedVersion // "") == "")] | length' "${rep}")
  # The table: every finding with a fix, CRITICAL first, as an artifact.
  jq -r '[.Results[]? | .Target as $t | .Vulnerabilities[]? | select((.FixedVersion // "") != "")
          | "\(.Severity)\t\(.VulnerabilityID)\t\(.PkgName)\t\(.InstalledVersion)\t\(.FixedVersion)\t\($t)"]
         | unique | sort_by(if startswith("CRITICAL") then 0 else 1 end)[]' "${rep}" > "${table}"
  crit_total=$((crit_total + crit)); high_total=$((high_total + high))
  if [ "${crit}" -gt 0 ]; then
    printf 'FAIL  %s: %s CRITICAL finding(s) with a fix; %s HIGH with a fix reported; %s without a fix yet\n' "${ref}" "${crit}" "${high}" "${unfixed}"
    grep '^CRITICAL' "${table}" | head -n 12 | awk -F'\t' '{ printf "      %s %s %s %s -> %s (%s)\n", $1, $2, $3, $4, $5, $6 }'
    return 1
  fi
  if [ "${high}" -gt 0 ]; then
    images_high=$((images_high + 1))
    printf 'high  %s: no CRITICAL finding with a fix; %s HIGH with a fix reported (%s); %s without a fix yet\n' "${ref}" "${high}" "findings-${name}.txt" "${unfixed}"
  else
    printf 'ok    %s: no CRITICAL or HIGH finding with a fix (%s without a fix yet)\n' "${ref}" "${unfixed}"
  fi
  return 0
}

scan_images() {
  local ref bad=0 count=0 list crit_total=0 high_total=0 images_high=0
  cd "$(git rev-parse --show-toplevel)"
  list=$(refs)
  [ -n "${list}" ] || die "no pinned image found: the discovery is broken"
  say "Images that the repository pins:"
  printf '%s\n' "${list}" | sed 's/^/  /'
  say "Trivy: a CRITICAL finding with a fix fails the run; a HIGH finding with a fix is reported"
  while IFS= read -r ref; do
    case ${ref} in
      mcr.microsoft.com/windows/*)
        printf 'skip  %s: a Windows image (Trivy finds no operating system in it on Linux)\n' "${ref}"
        continue ;;
    esac
    count=$((count + 1))
    scan_image "${ref}" || bad=$((bad + 1))
  done <<< "${list}"
  say "${count} images scanned: ${bad} failing (${crit_total} CRITICAL with a fix, or an image that could not be scanned), ${high_total} HIGH with a fix reported in ${images_high} images"
  say "Tables and Trivy reports: ${out} (findings-<image>.txt, trivy-<image>.json)"
  if [ "${bad}" -gt 0 ] || [ "${high_total}" -gt 0 ]; then
    say "What to do: bump the digest (a Renovate pull request does it: docs/ci.md, Pinned versions), or add a justified .trivyignore entry (the CVE, the reason, an owner and an expiry date)"
  fi
  [ "${bad}" -eq 0 ]
}

# The vulnerabilities that the proxy's code calls: the same rule as `govulncheck` with no flag. All of them fail, with a fix or not.
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
    ([.[] | select(.finding) | .finding | select(.trace[0].function != null)
      | {osv, module: .trace[0].module, fixed: (.fixed_version // "")}] | unique) as $called
    | ([.[] | select(.finding) | .finding | select(.trace[0].function == null) | .osv] | unique | length) as $other
    | if ($called | length) == 0 then "ok    no vulnerability is called by the proxy (" + ($other | tostring) + " in modules or packages that it does not call, reported in the JSON)"
      else (($called | length | tostring) + " vulnerabilit" + (if ($called | length) == 1 then "y" else "ies" end) + " called by the proxy:"),
           ($called[] | "      \(.osv) in \(.module), " + (if .fixed == "" then "no fix yet" else "fixed in " + .fixed end) + " (https://pkg.go.dev/vuln/\(.osv))"),
           "What to do: bump the Go toolchain (a Renovate pull request for the golang image and the release Go does it) or the module that the entry names"
      end' "${out}/govulncheck-proxy.json"
  jq -s -e '[.[] | select(.finding) | .finding | select(.trace[0].function != null)] | length == 0' \
    "${out}/govulncheck-proxy.json" > /dev/null
}

mkdir -p "${out}"
case "${1:-}" in
  images) scan_images 2>&1 | tee "${out}/summary-images.txt" ;;
  go) scan_go 2>&1 | tee "${out}/summary-go.txt" ;;
  refs) refs ;;
  *) die "usage: ci/security-scan.sh images|go|refs" ;;
esac
