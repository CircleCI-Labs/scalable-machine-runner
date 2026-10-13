#!/usr/bin/env bash
# setup-gate.sh test: a table of (branch, context, full parameter, tokens) -> the parameters that ci/setup-gate.sh
# hands to the continuation config. Needs bash and jq; no Docker, no network, no secret.
#
# The rows that matter most: a branch that is not main or smr-swarm/* never gets an e2e flag, with or without a
# token in its environment, and the plain setup job (--e2e false) never enables e2e on any branch.
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
expect() {
  local name=$1 branch=$2 e2e=$3 full=$4 tl=$5 tw=$6 want=$7 got out
  rows=$((rows + 1))
  out=$(CIRCLE_BRANCH=$branch E2E_RUNNER_TOKEN_LINUX=$tl E2E_RUNNER_TOKEN_WINDOWS=$tw "$gate" --e2e "$e2e" --full "$full" 2>"$err") || {
    echo "FAIL ${name}: the gate exited non-zero"; cat "$err"; failed=$((failed + 1)); return
  }
  got=$(jq -r '[.["full-suite"], .["e2e-linux"], .["e2e-windows"], .release] | map(tostring) | join(" ")' <<< "$out")
  if [ "$got" != "$want" ]; then
    echo "FAIL ${name}: branch='${branch}' e2e=${e2e} full=${full} -> '${got}', want '${want}'"
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
expect "smr-swarm/v2, both tokens"            smr-swarm/v2         true   false  "$T"   "$T"     "true true true false"
expect "smr-swarm/x/y, Linux token only"      smr-swarm/x/y        true   false  "$T"   ""       "true true false false"
expect "smr-swarm/ (empty suffix)"            smr-swarm/           true   false  "$T"   "$T"     "true true true false"
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

# a bad invocation fails closed (no arguments mean --e2e false --full false)
for args in "--e2e" "--e2e maybe --full false" "--e2e true --full 1" "--bogus"; do
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
