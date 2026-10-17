#!/usr/bin/env bash
# setup-gate.sh test: a table of (branch, context, full parameter, tokens) -> the parameters that ci/setup-gate.sh
# hands to the continuation config. Needs bash and jq; no Docker, no network, no secret.
#
# The rows that matter most: a branch that is not main or smr-swarm/* never gets an e2e flag, with or without a
# token in its environment, and the plain setup job (--e2e false) never enables e2e on any branch. Then the docs-only
# rows (a push that changes only documentation skips every suite and the release; anything not known, or anything that
# would make a release, does not), the path gating (every suite runs on a branch, or on a main push that makes no
# release, only for the paths that it reads; main with a release and --full true run everything; the pipeline files run
# everything), the rules between the flags (the release needs every job, proxy-test comes with proxy-image and e2e-windows),
# `strict` (the production main, where a missing credential fails), and the security-scan mode (nothing of the ci workflow runs).
#
# Usage: ci/tests/setup-gate.sh
set -euo pipefail
gate=$(cd "$(dirname "$0")/.." && pwd)/setup-gate.sh
sentinel=SENTINEL-TOKEN-0123456789abcdef

err=$(mktemp)
trap 'rm -f "$err"' EXIT
failed=0
rows=0
# expect NAME BRANCH E2E FULL LINUX_TOKEN WINDOWS_TOKEN EXPECTED(full e2e-linux e2e-windows release)
# The four values are completed with "false false" (docs-only, security-scan): these rows give no changed files. Four more values are derived from
# the rule and checked on every row: publish (main, not docs-only, not a scan), strict (main with both e2e tokens, a docs-only change included)
# and the three heavy suites windows, proxy-image and microvm (all on when the changed files are not known; all off for a docs-only change or a scan).
# HEAVY (a global, "windows proxy-image microvm") replaces the last three when the row gives changed files.
# PULL (a global) is the CIRCLE_PULL_REQUEST of the push; the last value, pull-request, is true when it is a GitHub pull request address.
# GATE_ARGS (a global) adds arguments to the call.
GATE_ARGS=()
HEAVY=
PULL=
expect() {
  local name=$1 branch=$2 e2e=$3 full=$4 tl=$5 tw=$6 want=$7 got out
  rows=$((rows + 1))
  [ "$(wc -w <<< "$want")" -ne 4 ] || want="$want false false"
  out=$(CIRCLE_BRANCH=$branch CIRCLE_PULL_REQUEST=$PULL E2E_RUNNER_TOKEN_LINUX=$tl E2E_RUNNER_TOKEN_WINDOWS=$tw "$gate" --e2e "$e2e" --full "$full" "${GATE_ARGS[@]}" 2>"$err") || {
    echo "FAIL ${name}: the gate exited non-zero"; cat "$err"; failed=$((failed + 1)); return
  }
  got=$(jq -r '[.["full-suite"], .["e2e-linux"], .["e2e-windows"], .release, .["docs-only"], .["security-scan"], .publish, .strict, .windows, .["proxy-image"], .microvm, .["pull-request"]] | map(tostring) | join(" ")' <<< "$out")
  # publish: main, and neither a docs-only change nor a scan (the last two values of want), whatever the tokens and the e2e flags say
  pub=false
  heavy=${HEAVY:-"true true true"}
  if [ "$branch" = main ] && [ "$(awk '{ print $5 $6 }' <<< "$want")" = falsefalse ] && [ "$(awk '{ print $2 }' <<< "$heavy")" = true ]; then pub=true; fi
  strict=false
  if [ "$branch" = main ] && [ "$e2e" = true ] && [ -n "$tl" ] && [ -n "$tw" ] && [ "$(awk '{ print $6 }' <<< "$want")" = false ]; then strict=true; fi
  if [ -z "$HEAVY" ] && [ "$(awk '{ print $5 $6 }' <<< "$want")" != falsefalse ]; then heavy="false false false"; fi
  pr=false
  if [[ "$PULL" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]] && [ "$(awk '{ print $6 }' <<< "$want")" != true ]; then pr=true; fi
  want="$want $pub $strict $heavy $pr"
  if [ "$got" != "$want" ]; then
    echo "FAIL ${name}: branch='${branch}' e2e=${e2e} full=${full} ${GATE_ARGS[*]:-} -> '${got}', want '${want}'"
    failed=$((failed + 1))
  elif grep -q "$sentinel" <<< "$(cat "$err")$out"; then
    echo "FAIL ${name}: a token value reached the output"
    failed=$((failed + 1))
  else
    echo "ok   ${name}: -> ${got}"
  fi
}
T=$sentinel
#      name                                   branch               e2e    full   linux  windows  want: full linux windows release
expect "main, both tokens"                    main                 true   false  "$T"   "$T"     "true true true true"
expect "main, both tokens, full parameter"    main                 true   true   "$T"   "$T"     "true true true true"
expect "main, Linux token only"               main                 true   false  "$T"   ""       "true true false false"
expect "main, Windows token only"             main                 true   false  ""     "$T"     "true false true false"
expect "main, no token (context missing)"     main                 true   false  ""     ""       "true false false false"
expect "smr-swarm/v2, both tokens"            smr-swarm/v2         true   false  "$T"   "$T"     "false true true false"
expect "smr-swarm/x/y, Linux token only"      smr-swarm/x/y        true   false  "$T"   ""       "false true false false"
expect "smr-swarm/ (empty suffix)"            smr-swarm/           true   false  "$T"   "$T"     "false true true false"
expect "smr-swarm/v2, both tokens, full"      smr-swarm/v2         true   true   "$T"   "$T"     "true true true false"
expect "plain job on main (never scheduled)"  main                 false  false  "$T"   "$T"     "true false false false"
expect "feature branch, plain, no token"      feature/x            false  false  ""     ""       "false false false false"
expect "feature branch, plain, tokens in env" feature/x            false  false  "$T"   "$T"     "false false false false"
expect "feature branch, full parameter"       feature/x            false  true   ""     ""       "true false false false"
expect "feature branch, full, tokens in env"  feature/x            false  true   "$T"   "$T"     "true false false false"
expect "feature branch, context by mistake"   feature/x            true   false  "$T"   "$T"     "false false false false"
expect "feature branch, context and full"     feature/x            true   true   "$T"   "$T"     "true false false false"
expect "smr-swarmx/y is not smr-swarm/*"      smr-swarmx/y         true   false  "$T"   "$T"     "false false false false"
expect "feature/smr-swarm/x is not either"    feature/smr-swarm/x  true   false  "$T"   "$T"     "false false false false"
expect "main-old is not main"                 main-old             true   false  "$T"   "$T"     "false false false false"
expect "Main is not main"                     Main                 true   false  "$T"   "$T"     "false false false false"
expect "smr-scratch/windows-runtime"          smr-scratch/windows-runtime true false "$T" "$T"   "false false false false"
expect "a pull request branch"                pull/12              true   false  "$T"   "$T"     "false false false false"
expect "tag pipeline (no branch), plain"      ""                   false  false  ""     ""       "false false false false"
expect "tag pipeline (no branch), tokens"     ""                   true   false  "$T"   "$T"     "false false false false"

# docs-only: the paths come from a file, as ci/changed-files.sh writes them. DOCS NAME BRANCH E2E FULL RELEASABLE WANT PATH...
#   (WANT: full linux windows release docs-only windows proxy-image microvm; the tokens are present on every row, as in the e2e context)
changed=$(mktemp)
trap 'rm -f "$err" "$changed"' EXIT
docs() {
  local name=$1 branch=$2 e2e=$3 full=$4 rel=$5 want=$6; shift 6
  printf '%s\n' "$@" > "$changed"
  [ "$#" -gt 0 ] || : > "$changed"
  GATE_ARGS=(--changed "$changed" --releasable "$rel")
  HEAVY=$(cut -d' ' -f6-8 <<< "$want")
  expect "$name" "$branch" "$e2e" "$full" "$T" "$T" "$(cut -d' ' -f1-5 <<< "$want") false"
  GATE_ARGS=()
  HEAVY=
}
#    name                                         branch        e2e    full   releasable  want: full linux windows release docs  win proxy microvm  paths
docs "PR: docs and site only"                     feature/x     false  false  true  "false false false false true false false false"  docs/ci.md site/hugo.yaml README.md
docs "PR: a nested Markdown file"                 feature/x     false  false  true  "false false false false true false false false"  linux/images/example/README.md .github/PULL_REQUEST_TEMPLATE.md
docs "PR: a docs asset"                           feature/x     false  false  true  "false false false false true false false false"  docs/images/diagram.svg
docs "PR: docs and a script that no suite reads"  feature/x     false  false  true  "false false false false false false false false"  docs/ci.md ci/release.sh
docs "PR: the scripts of the docs build are docs" feature/x     false  false  true  "false false false false true false false false"  site/stage.sh site/nav.txt
docs "PR: docs/microvm.md is read by a test"      feature/x     false  false  true  "false false false false false false false true"  docs/microvm.md
docs "PR: a file that only looks like docs"       feature/x     false  false  true  "false false false false false false false false"  docs.sh README.md.bak documentation/a.txt
docs "PR: CI config"                              feature/x     false  false  true  "false false false false false true true true"  .circleci/continue.yml
docs "PR: no changed file is known"               feature/x     false  false  true  "false false false false false true true true"
docs "PR: full parameter on a docs-only change"   feature/x     false  true   true  "true false false false false true true true"  docs/ci.md
docs "smr-swarm/v2: docs only"                    smr-swarm/v2  true   false  true  "false false false false true false false false"  docs/faq.md
docs "smr-swarm/v2: docs and code"                smr-swarm/v2  true   false  true  "false true true false false false true true"  docs/faq.md proxy/cmd/machine-runner-swarm-proxy/main.go
docs "main: docs only, nothing would release"     main          true   false  false "false false false false true false false false"  docs/ci.md CHANGELOG.md
docs "main: docs only, a release would be made"   main          true   false  true  "true true true true false true true true"  docs/ci.md
docs "main: docs and code, no release"            main          true   false  false "false true false false false false false false"  docs/ci.md linux/setup.sh
docs "main: no changed file is known"            main          true   false  false "true true true true false true true true"
docs "main: plain job (never scheduled), docs"   main          false  false  false "false false false false true false false false"  docs/ci.md

# the heavy suites on a branch that is not main: only the paths that a suite reads switch it on
docs "heavy: proxy code"                          feature/x     false  false  true  "false false false false false false true true"  proxy/cmd/machine-runner-swarm-proxy/main.go
docs "heavy: the proxy Dockerfile"                feature/x     false  false  true  "false false false false false false true true"  proxy/Dockerfile.windows
docs "heavy: a Windows stack file"                feature/x     false  false  true  "false false false false false true false false"  windows/stack/runners.yaml
docs "heavy: a Windows test"                      feature/x     false  false  true  "false false false false false true false false"  windows/tests/Test-Install.ps1
docs "heavy: the helpers of the Windows image test" feature/x   false  false  true  "false false false false false true true false"  windows/tests/SwarmTestHelpers.psm1
docs "heavy: the PSScriptAnalyzer settings"       feature/x     false  false  true  "false false false false false true false false"  PSScriptAnalyzerSettings.psd1
docs "heavy: a Linux stack file"                  feature/x     false  false  true  "false false false false false false false true"  linux/stack/microvm.yaml
docs "heavy: a Linux test"                        feature/x     false  false  true  "false false false false false false false true"  linux/tests/stack-config.sh
docs "heavy: the setup script of Linux"           feature/x     false  false  true  "false false false false false false false false"  linux/setup.sh
docs "heavy: an example"                          feature/x     false  false  true  "false false false false false false false false"  examples/linux-hello.yml
docs "heavy: the proxy image script"              feature/x     false  false  true  "false false false false false false true false"  ci/proxy-image.sh
docs "heavy: the gate runs every suite"           feature/x     false  false  true  "false false false false false true true true"  ci/setup-gate.sh
docs "heavy: the CI config runs every suite"      feature/x     false  false  true  "false false false false false true true true"  .circleci/config.yml
docs "heavy: two commits, two suites"             feature/x     false  false  true  "false false false false false true false true"  windows/Setup.ps1 linux/stack/runners.yaml
docs "heavy: a docs page and one stack file"      feature/x     false  false  true  "false false false false false false false true"  docs/ci.md linux/stack/microvm.yaml
docs "heavy: main runs them for a doc fix"        main          true   false  true  "true true true true false true true true"  docs/ci.md
docs "heavy: main without a release gates them"   main          true   false  false "false true false false false false false false"  linux/setup.sh
docs "heavy: main with a release runs them"       main          true   false  true  "true true true true false true true true"  linux/setup.sh
docs "heavy: smr-swarm/v2 keeps them off"         smr-swarm/v2  true   false  true  "false true false false false false false false"  linux/setup.sh
docs "heavy: full on a branch runs them all"      feature/x     false  true   true  "true false false false false true true true"  linux/setup.sh
docs "heavy: a plain job with the context by mistake" feature/x true   false  true  "false false false false false false false false"  linux/setup.sh

# Path gating of every suite. GATED NAME BRANCH E2E RELEASABLE "FLAGS" PATH...
#   FLAGS: the flags that are true, of the sixteen that switch a job on (full-suite, e2e-linux, e2e-windows, release, publish and the eleven
#   suites); every other flag must be false. The tokens are present on every row (the e2e context), so an e2e flag follows the path alone.
suite_keys="full-suite e2e-linux e2e-windows release publish windows proxy-image microvm linux-swarm linux-swarm-proxy linux-smoke linux-image container-agent e2e-sim proxy-test signing"
all_suites="windows proxy-image microvm linux-swarm linux-swarm-proxy linux-smoke linux-image container-agent e2e-sim proxy-test signing"
# the rules between the flags, checked on every row: the release needs every job, and a job never needs one that is off
invariants='
  . as $o
  | ["windows","proxy-image","microvm","linux-swarm","linux-swarm-proxy","linux-smoke","linux-image","container-agent","e2e-sim","proxy-test","signing"] as $suites
  | [ (select($o.release and (([$suites[] | $o[.]] + [$o["e2e-linux"], $o["e2e-windows"], $o["full-suite"]]) | all | not)) | "release without every job"),
      (select(($o["e2e-windows"] or $o["proxy-image"]) and ($o["proxy-test"] | not)) | "proxy-image or e2e-windows without proxy-test"),
      (select($o.publish and ($o["proxy-image"] | not)) | "publish without proxy-image"),
      (select($o["e2e-linux"] and $o["docs-only"]) | "e2e-linux in a docs-only change"),
      (select($o["security-scan"] and ([$suites[] | $o[.]] | any)) | "a suite in a scan") ]
  | join("; ")'
gated() {
  local name=$1 branch=$2 e2e=$3 rel=$4 want=$5 got broken out
  shift 5
  rows=$((rows + 1))
  printf '%s\n' "$@" > "$changed"
  [ "$#" -gt 0 ] || : > "$changed"
  out=$(CIRCLE_BRANCH=$branch CIRCLE_PULL_REQUEST="" E2E_RUNNER_TOKEN_LINUX=$T E2E_RUNNER_TOKEN_WINDOWS=$T "$gate" --e2e "$e2e" --full false --changed "$changed" --releasable "$rel" 2>"$err") || {
    echo "FAIL ${name}: the gate exited non-zero"; cat "$err"; failed=$((failed + 1)); return
  }
  got=$(jq -r --arg keys "$suite_keys" '. as $o | [($keys | split(" "))[] | select($o[.] == true)] | sort | join(" ")' <<< "$out")
  want=$(printf '%s\n' $want | LC_ALL=C sort | paste -sd' ' -)
  broken=$(jq -r "$invariants" <<< "$out")
  if [ "$got" != "$want" ]; then
    echo "FAIL ${name}: branch='${branch}' e2e=${e2e} releasable=${rel} $* -> '${got}', want '${want}'"
    failed=$((failed + 1))
  elif [ -n "$broken" ]; then
    echo "FAIL ${name}: ${broken}"
    failed=$((failed + 1))
  else
    echo "ok   ${name}: -> ${got:-nothing but lint}"
  fi
}
linux_all="linux-swarm linux-swarm-proxy microvm"
#      name                                         branch        e2e    rel    flags (the others are false)                                          paths
gated "a branch: only under windows/"             feature/x     false  true   "windows"                                                             windows/tests/Test-Placement.ps1
gated "a branch: a Windows stack file"            feature/x     false  true   "windows linux-swarm linux-swarm-proxy"                               windows/stack/runners.yaml
gated "a branch: the Windows test runner"         feature/x     false  true   "windows"                                                             ci/Invoke-Test.ps1
gated "a branch: only under proxy/"               feature/x     false  true   "proxy-image proxy-test microvm linux-swarm-proxy linux-smoke"        proxy/cmd/machine-runner-swarm-proxy/main.go
gated "a branch: the proxy build script"          feature/x     false  true   "proxy-image proxy-test"                                              ci/build-proxy.sh
gated "a branch: the image script"                feature/x     false  true   "proxy-image proxy-test signing"                                    ci/proxy-image.sh
gated "a branch: the tools"                       feature/x     false  true   "proxy-image proxy-test signing"                                    ci/tools.sh
gated "a branch: the deploy marker"               feature/x     false  true   "proxy-image proxy-test"                                              ci/deploy-marker.sh
gated "a branch: the Windows image script"        feature/x     false  true   "proxy-image proxy-test"                                              ci/Build-ProxyImage.ps1
gated "a branch: the image publication test"      feature/x     false  true   "proxy-image proxy-test"                                              ci/tests/proxy-image.sh
gated "a branch: only under linux/tests/"         feature/x     false  true   "$linux_all"                                                          linux/tests/helper.sh
gated "a branch: linux/setup.sh"                  feature/x     false  true   "linux-swarm linux-swarm-proxy linux-smoke"                           linux/setup.sh
gated "a branch: a Linux stack file"              feature/x     false  true   "$linux_all linux-smoke"                                              linux/stack/runners.yaml
gated "a branch: the container agent"             feature/x     false  true   "$linux_all linux-smoke container-agent"                              linux/stack/container-agent/api.go
gated "a branch: the Linux example image"         feature/x     false  true   "linux-image"                                                         linux/images/example/Dockerfile
gated "a branch: the Trivy ignore list"           feature/x     false  true   "linux-image"                                                         .trivyignore
gated "a branch: the smoke script"                feature/x     false  true   "linux-smoke"                                                         ci/linux-smoke.sh
gated "a branch: the e2e host script"             feature/x     false  true   "e2e-sim"                                                             ci/e2e-host.sh
gated "a branch: the e2e simulation test"         feature/x     false  true   "e2e-sim"                                                             ci/tests/e2e-sim.sh
gated "a branch: docs/microvm.md"                 feature/x     false  true   "microvm"                                                             docs/microvm.md
gated "a branch: a script that no suite reads"    feature/x     false  true   ""                                                                    ci/release.sh ci/bundle-links.py ci/tests/signature-ref.sh
gated "a branch: a lint configuration"            feature/x     false  true   ""                                                                    .yamllint.yaml .shellcheckrc renovate.json
gated "a branch: an example"                      feature/x     false  true   ""                                                                    examples/linux-hello.yml
gated "a branch: a comment in the continuation"   feature/x     false  true   "$all_suites"                                                         .circleci/continue.yml
gated "a branch: the setup job"                   feature/x     false  true   "$all_suites"                                                         .circleci/config.yml
gated "a branch: the gate"                        feature/x     false  true   "$all_suites"                                                         ci/setup-gate.sh
gated "a branch: the changed-files script"        feature/x     false  true   "$all_suites"                                                         ci/changed-files.sh
gated "a branch: line endings"                    feature/x     false  true   "$all_suites"                                                         .gitattributes
gated "a branch: the gate tests are lint"         feature/x     false  true   ""                                                                    ci/tests/setup-gate.sh
gated "a branch: two paths, two suites"           feature/x     false  true   "windows linux-image"                                                 windows/Setup.ps1 linux/images/example/Dockerfile
gated "a branch: not known"                       feature/x     false  true   "$all_suites"
gated "a branch: releasable is only for main"     feature/x     false  false  "windows"                                                             windows/Setup.ps1
# the e2e branches add the groups whose files change, with the tokens
gated "smr-swarm: only under windows/"            smr-swarm/v2  true   true   "windows e2e-windows proxy-test"                                       windows/tests/Test-Placement.ps1
gated "smr-swarm: only under proxy/"              smr-swarm/v2  true   true   "proxy-image proxy-test microvm linux-swarm-proxy linux-smoke e2e-linux e2e-windows" proxy/Dockerfile
gated "smr-swarm: only under linux/tests/"        smr-swarm/v2  true   true   "$linux_all"                                                          linux/tests/helper.sh
gated "smr-swarm: linux/setup.sh"                 smr-swarm/v2  true   true   "linux-swarm linux-swarm-proxy linux-smoke e2e-linux"                 linux/setup.sh
gated "smr-swarm: the Windows e2e host"           smr-swarm/v2  true   true   "e2e-windows proxy-test"                                              ci/E2E-Host.ps1
gated "smr-swarm: the Linux e2e probe"            smr-swarm/v2  true   true   "e2e-linux e2e-sim"                                                   ci/e2e-probe.sh
gated "smr-swarm: the continuation, everything"   smr-swarm/v2  true   true   "$all_suites e2e-linux e2e-windows"                                   .circleci/continue.yml
gated "smr-swarm: a script that no suite reads"   smr-swarm/v2  true   true   ""                                                                    ci/release.sh
gated "a plain job never has an e2e flag"         smr-swarm/v2  false  true   "$all_suites"                                                         .circleci/continue.yml
# main without a release is gated like a branch, and publishes only when the image is built
gated "main, no release: a chore under linux/tests/" main        true   false  "$linux_all"                                                          linux/tests/helper.sh
gated "main, no release: only under windows/"     main          true   false  "windows e2e-windows proxy-test"                                       windows/tests/Test-Placement.ps1
gated "main, no release: only under proxy/"       main          true   false  "proxy-image proxy-test microvm linux-swarm-proxy linux-smoke e2e-linux e2e-windows publish" proxy/cmd/machine-runner-swarm-proxy/main.go
gated "main, no release: linux/setup.sh"          main          true   false  "linux-swarm linux-swarm-proxy linux-smoke e2e-linux"                 linux/setup.sh
gated "main, no release: a comment in the pipeline" main        true   false  "$all_suites e2e-linux e2e-windows publish"                           .circleci/continue.yml
gated "main, no release: a script that no suite reads" main     true   false  ""                                                                    ci/release.sh
gated "main, no release: a test-only change"      main          true   false  ""                                                                    ci/tests/signature-ref.sh
gated "main, no release: docs and one stack file" main          true   false  "$linux_all linux-smoke e2e-linux"                                    docs/ci.md linux/stack/microvm.yaml
gated "main, no release: not known"               main          true   false  "$all_suites e2e-linux e2e-windows full-suite release publish"
# main with a release, or whatever the changes are, runs everything
gated "main, release: a chore under linux/tests/" main          true   true   "$all_suites e2e-linux e2e-windows full-suite release publish"     linux/tests/helper.sh
gated "main, release: docs only"                  main          true   true   "$all_suites e2e-linux e2e-windows full-suite release publish"     docs/ci.md
gated "main, release: a script that no suite reads" main        true   true   "$all_suites e2e-linux e2e-windows full-suite release publish"     ci/release.sh
gated "main, release: not known"                  main          true   true   "$all_suites e2e-linux e2e-windows full-suite release publish"

# The keys of the gate are the parameters of the continuation config, no more and no fewer: the continuation call fails on an unknown one, and a
# parameter that the gate never sets stays false for ever.
rows=$((rows + 1))
config_keys=$(awk '/^parameters:/ { in_params = 1; next } /^[a-z]/ { in_params = 0 } in_params && /^  [a-z0-9-]+:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$(dirname "$gate")/../.circleci/continue.yml" | LC_ALL=C sort | paste -sd' ' -)
gate_keys=$(CIRCLE_BRANCH=feature/x "$gate" --e2e false --full false 2> /dev/null | jq -r 'keys | join(" ")')
gate_keys=$(printf '%s\n' $gate_keys | LC_ALL=C sort | paste -sd' ' -)
if [ "$config_keys" = "$gate_keys" ] && [ -n "$config_keys" ]; then
  echo "ok   the gate sets exactly the parameters of .circleci/continue.yml"
else
  echo "FAIL the parameters of .circleci/continue.yml: '${config_keys}'; the keys of the gate: '${gate_keys}'"
  failed=$((failed + 1))
fi

# the changed files and the releasable answer are optional, and a missing file means "not known"
GATE_ARGS=(--changed /nonexistent/changed.txt)
expect "main: changed file missing"               main          true   false  "$T"   "$T"     "true true true true"
GATE_ARGS=(--changed "$changed")
printf 'docs/ci.md\n' > "$changed"
expect "main: --releasable not given counts as true" main       true   false  "$T"   "$T"     "true true true true"
GATE_ARGS=()

# a pull request: the address that CircleCI puts in CIRCLE_PULL_REQUEST (docs-site-comment runs). Nothing else counts
PULL=https://github.com/CircleCI-Labs/machine-runner-swarm/pull/2
expect "a pull request on a feature branch"       feature/x            false  false  ""     ""       "false false false false"
expect "a pull request on main (a merge queue?)"  main                 true   false  "$T"   "$T"     "true true true true"
PULL=https://example.com/o/r/pull/2
expect "a pull request address of another host"   feature/x            false  false  ""     ""       "false false false false"
PULL=https://github.com/o/r/pull/
expect "a pull request address with no number"    feature/x            false  false  ""     ""       "false false false false"
PULL="https://github.com/o/r/pull/2 and more"
expect "a pull request address with a tail"       feature/x            false  false  ""     ""       "false false false false"
PULL=https://github.com/o/r/pull/2
GATE_ARGS=(--scan true)
expect "a scan ignores the pull request"         feature/x            false  false  ""     ""       "false false false false false true"
GATE_ARGS=()
PULL=

# security-scan: the workflow of the schedule. Nothing of the ci workflow runs, on any branch, with or without tokens, with --full
GATE_ARGS=(--scan true)
expect "scan on main"                             main          false  false  "$T"   "$T"     "false false false false false true"
expect "scan on main with full"                   main          false  true   "$T"   "$T"     "false false false false false true"
expect "scan on a feature branch"                 feature/x     false  false  ""     ""       "false false false false false true"
expect "scan on smr-swarm/v2"                     smr-swarm/v2  false  false  "$T"   "$T"     "false false false false false true"
expect "scan with no branch"                      ""            false  false  ""     ""       "false false false false false true"
GATE_ARGS=(--scan false)
expect "scan false is the ordinary decision"      main          true   false  "$T"   "$T"     "true true true true false false"
GATE_ARGS=()

# a bad invocation fails closed (no arguments mean --e2e false --full false)
for args in "--e2e" "--e2e maybe --full false" "--e2e true --full 1" "--bogus" "--scan maybe" "--e2e true --scan true" "--releasable 1" "--changed"; do
  rows=$((rows + 1))
  # shellcheck disable=SC2086  # the arguments are words
  if CIRCLE_BRANCH=main "$gate" $args > /dev/null 2>&1; then
    echo "FAIL arguments '${args}': the gate accepted them"
    failed=$((failed + 1))
  else
    echo "ok   arguments '${args}': rejected"
  fi
done

echo "RESULT test=setup-gate rows=${rows} failed=${failed}"
if [ "$failed" -eq 0 ]; then echo "PASS (${rows} rows)"; else echo "FAIL: ${failed} row(s)"; exit 1; fi
