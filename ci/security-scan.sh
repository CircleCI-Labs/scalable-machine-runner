#!/usr/bin/env bash
# security-scan.sh: the weekly security scan (docs/ci.md, "Security scan"). The workflow `security-scan` of
# .circleci/continue.yml runs it, on a schedule.
#
#   ci/security-scan.sh images   Trivy on every image that the repository pins, in two lists (ci/security-scan-images.txt):
#                                infra images (what a stack runs on a user's cluster) fail on a CRITICAL finding with a fix;
#                                report-only images (job images, CI tools) are listed with a table and a JSON file each, never fail
#   ci/security-scan.sh go       govulncheck on proxy/; fails on any vulnerability that the proxy's code calls (code that we own)
#   ci/security-scan.sh lists    check that every pinned image is on a list (no scan, no network); fails on one that is not
#   ci/security-scan.sh refs     print the image references that `images` scans, one per line (no scan)
#
# Which images: a reference of any tracked file that carries a digest (name[:tag]@sha256:...: .circleci/*.yml, ci/, the stack
# files, the tests), and the `image:` of every stack file (linux/stack, windows/stack): tags without a digest (CoreDNS,
# alpine:3.24, the cimg classes) are scanned too. Windows images are on the list as `skip`: Trivy finds no operating system in
# them when it runs on Linux, so a scan would only say "clean". Placeholders (registry.example.com, ${VARIABLES}) are not images.
# The list of images comes from the files, so a bump by Renovate is scanned in the next run; ci/security-scan-images.txt only
# says which list an image is on, and an image on no list fails the scan (and `lists`, in the pull request).
#
# What fails: for an infra image, a CRITICAL finding with a fixed version, or an image that Trivy cannot pull. What is only
# reported: its HIGH findings, every finding of a report-only image, and every finding with no fix yet. Most pinned images
# carry some HIGH finding on any given week, from upstream packages and bundled Go binaries, and the job images are not ours to
# patch, so failing on them would keep the run red and teach nobody to look. .trivyignore applies, with its expiry dates.
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
lists_file="$(git rev-parse --show-toplevel)/ci/security-scan-images.txt"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

refs() {
  cd "$(git rev-parse --show-toplevel)"
  {
    git ls-files -z -- '*.yml' '*.yaml' '*.sh' '*.ps1' '*.md' \
      | xargs -0 grep -hoE '[a-z0-9][a-z0-9._/-]*[a-z0-9](:[A-Za-z0-9][A-Za-z0-9._-]*)?@sha256:[a-f0-9]{64}' || true
    git ls-files -z -- 'linux/stack/*.yaml' 'windows/stack/*.yaml' \
      | xargs -0 sed -nE 's/^[[:space:]]+image:[[:space:]]+([^[:space:]#]+).*/\1/p'
    # an image that a stack names by a variable, with its published default: the token proxy (the tag latest, the newest release)
    git ls-files -z -- 'linux/stack/*.yaml' 'windows/stack/*.yaml' \
      | xargs -0 sed -nE 's/^[[:space:]]+image:[[:space:]]+[$][{][A-Z_]+:-([^}[:space:]]+)[}].*/\1/p'
  } | grep -vE '[$]|^registry\.example\.com/|^localhost[:/]' | sort -u
}

# list_of REF: the list of ci/security-scan-images.txt that the repository of REF is on (infra, report or skip), or nothing.
list_of() {
  local name=${1%%@*} list pattern
  if [[ "${name##*/}" == *:* ]]; then name=${name%:*}; fi   # drop the tag (the colon after the last slash), not a registry port
  while read -r list pattern _; do
    case ${list} in "" | "#"*) continue ;; esac
    # shellcheck disable=SC2254  # the pattern is a glob on purpose
    case ${name} in ${pattern}) echo "${list}"; return 0 ;; esac
  done < "${lists_file}"
  return 0
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

# scan_image REF LIST: one JSON report and one table (CRITICAL first) of the HIGH and CRITICAL findings, as artifacts; prints one
# line. Adds to the counters of scan_images. Returns 1 only for an infra image with a CRITICAL finding that has a fix, or that
# Trivy cannot scan; a report-only image never returns 1.
scan_image() {
  local ref=$1 list=$2 name json rep table crit high unfixed label
  name=$(printf '%s' "${ref}" | tr -c 'A-Za-z0-9._-' '_')
  rep="${out}/trivy-${name}.json"
  table="${out}/findings-${name}.txt"
  if [ -n "${TRIVY_BIN:-}" ]; then json=${rep}; else json=/reports/trivy-${name}.json; fi
  if ! run_trivy image --image-src remote --scanners vuln --severity HIGH,CRITICAL --ignorefile .trivyignore \
      --format json --output "${json}" --quiet --no-progress "${ref}" > "${out}/trivy-${name}.log" 2>&1; then
    printf '%-6s %s: trivy could not scan it (%s)\n' "ERROR" "${ref}" "$(tail -n 1 "${out}/trivy-${name}.log" | cut -c1-200)"
    [ "${list}" = infra ] || return 0
    return 1
  fi
  crit=$(jq '[.Results[]? | .Vulnerabilities[]? | select((.FixedVersion // "") != "" and .Severity == "CRITICAL")] | length' "${rep}")
  high=$(jq '[.Results[]? | .Vulnerabilities[]? | select((.FixedVersion // "") != "" and .Severity == "HIGH")] | length' "${rep}")
  unfixed=$(jq '[.Results[]? | .Vulnerabilities[]? | select((.FixedVersion // "") == "")] | length' "${rep}")
  # The table: every HIGH and CRITICAL finding, CRITICAL first, with the fixed version ("-" when there is none yet).
  jq -r '[.Results[]? | .Target as $t | .Vulnerabilities[]?
          | "\(.Severity)\t\(.VulnerabilityID)\t\(.PkgName)\t\(.InstalledVersion)\t\(if (.FixedVersion // "") == "" then "-" else .FixedVersion end)\t\($t)"]
         | unique | sort_by(if startswith("CRITICAL") then 0 else 1 end)[]' "${rep}" > "${table}"
  if [ "${list}" = infra ]; then
    infra_n=$((infra_n + 1)); infra_high=$((infra_high + high))
    if [ "${crit}" -gt 0 ]; then
      infra_failing=$((infra_failing + 1))
      printf 'FAIL   %s: %s CRITICAL finding(s) with a fix; %s HIGH with a fix reported; %s without a fix yet\n' "${ref}" "${crit}" "${high}" "${unfixed}"
      awk -F'\t' '$1 == "CRITICAL" && $5 != "-" { printf "      %s %s %s %s -> %s (%s)\n", $1, $2, $3, $4, $5, $6 }' "${table}" | head -n 12
      return 1
    fi
    label=ok
    [ "${high}" -eq 0 ] || label=high
    printf '%-6s %s: infra, no CRITICAL finding with a fix; %s HIGH with a fix reported (%s); %s without a fix yet\n' "${label}" "${ref}" "${high}" "findings-${name}.txt" "${unfixed}"
    return 0
  fi
  report_n=$((report_n + 1)); report_crit=$((report_crit + crit)); report_high=$((report_high + high))
  printf '%-6s %s: report-only, %s CRITICAL and %s HIGH with a fix listed (%s); %s without a fix yet\n' "list" "${ref}" "${crit}" "${high}" "findings-${name}.txt" "${unfixed}"
  return 0
}

# Every image of the repository with its list. Prints "list ref" lines; returns 1 when an image is on no list.
classify() {
  local ref list bad=0
  while IFS= read -r ref; do
    list=$(list_of "${ref}")
    if [ -z "${list}" ]; then
      printf 'none %s\n' "${ref}"
      bad=1
    else
      printf '%s %s\n' "${list}" "${ref}"
    fi
  done <<< "$(refs)"
  return "${bad}"
}

scan_lists() {
  local rows rc=0
  cd "$(git rev-parse --show-toplevel)"
  rows=$(classify) || rc=1
  printf '%s\n' "${rows}"
  if [ "${rc}" -ne 0 ]; then
    echo "error: the images marked none are on no list: add each one to ci/security-scan-images.txt as infra (a stack runs it on a cluster) or report (a job image or a CI tool)" >&2
  fi
  return "${rc}"
}

scan_images() {
  local ref list rows unlisted=0 infra_n=0 infra_failing=0 infra_high=0 report_n=0 report_crit=0 report_high=0
  cd "$(git rev-parse --show-toplevel)"
  rows=$(classify) || unlisted=1
  [ -n "${rows}" ] || die "no pinned image found: the discovery is broken"
  say "Images that the repository pins, and their lists (ci/security-scan-images.txt):"
  printf '%s\n' "${rows}" | awk '{ printf "  %-7s %s\n", $1, $2 }'
  say "Trivy: an infra image fails on a CRITICAL finding with a fix; a report-only image is listed and never fails"
  while read -r list ref; do
    case ${list} in
      skip) printf 'skip   %s: not scanned (a Windows image: Trivy finds no operating system in it on Linux)\n' "${ref}"; continue ;;
      none) printf 'ERROR  %s: on no list of ci/security-scan-images.txt: add it as infra or report\n' "${ref}"; continue ;;
    esac
    scan_image "${ref}" "${list}" || true
  done <<< "${rows}"
  say "infra: ${infra_n} images, ${infra_failing} failing (${infra_high} HIGH with a fix reported); report-only: ${report_n} images, ${report_crit} CRITICAL and ${report_high} HIGH with a fix listed"
  say "Tables and Trivy reports: ${out} (findings-<image>.txt, trivy-<image>.json)"
  if [ "${infra_failing}" -gt 0 ] || [ "${unlisted}" -gt 0 ]; then
    say "What to do: bump the digest (a Renovate pull request does it: docs/ci.md, Pinned versions), or add a justified .trivyignore entry (the CVE, the reason, an owner and an expiry date); an image on no list needs a line in ci/security-scan-images.txt"
  fi
  [ "${infra_failing}" -eq 0 ] && [ "${unlisted}" -eq 0 ]
}

# The vulnerabilities that the proxy's code calls: the same rule as `govulncheck` with no flag. All of them fail, with a fix or not.
scan_go() {
  # renovate: datasource=go depName=golang.org/x/vuln
  local govulncheck_version=v1.9.0
  local gobin; gobin="$(mktemp -d)"
  # The scan must read the toolchain that builds the proxy: the golang image of ci/build-proxy.sh and the Go of ci/release.sh.
  local have want_build want_release root
  root=$(git rev-parse --show-toplevel)
  have=$(go env GOVERSION); have=${have#go}
  want_build=$(sed -nE 's/.*golang:([0-9][0-9.]*)@sha256.*/\1/p' "${root}/ci/build-proxy.sh" | head -n 1)
  want_release=$(sed -nE 's/^[[:space:]]*local go_version=([0-9][0-9.]*)$/\1/p' "${root}/ci/release.sh" | head -n 1)
  if [ "${have}" != "${want_build}" ] || [ "${have}" != "${want_release}" ]; then
    die "the scan runs Go ${have}, but the proxy is built with Go ${want_build} (ci/build-proxy.sh) and ${want_release} (ci/release.sh): the Go pins must agree, and the job image must be the same (GOTOOLCHAIN=go${want_build} on a workstation)"
  fi
  say "Install govulncheck ${govulncheck_version} (Go ${have}, the toolchain of the proxy builds)"
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
  lists) scan_lists ;;
  go) scan_go 2>&1 | tee "${out}/summary-go.txt" ;;
  refs) refs ;;
  *) die "usage: ci/security-scan.sh images|go|lists|refs" ;;
esac
