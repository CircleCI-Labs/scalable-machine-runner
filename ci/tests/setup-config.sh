#!/usr/bin/env bash
# setup-config.sh test: compile .circleci/config.yml for a table of branches and check that exactly ONE setup
# workflow is left, that only main and smr-swarm/* get the e2e context, and that every other branch gets a
# setup job without any context (e2e off). `circleci config process` evaluates the `when` clauses, so the
# expression `<< pipeline.git.branch >>` is replaced by each branch name before compiling. A pipeline that sets the
# pipeline parameter security-scan (the weekly schedule) gets the third workflow, setup-scan, on every branch,
# including main and smr-swarm/*: the scan never has the e2e context.
#
# Needs: the CircleCI CLI (config process asks the CircleCI API to compile; no token), yq (mikefarah) and jq.
# Usage: ci/tests/setup-config.sh [path to circleci]
set -euo pipefail
cli=${1:-circleci}
config=$(cd "$(dirname "$0")/../.." && pwd)/.circleci/config.yml
context=scalable-machine-runner-e2e
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

grep -q '<< pipeline.git.branch >>' "$config" || { echo "FAIL: no << pipeline.git.branch >> in $config"; exit 1; }

failed=0
rows=0
# check BRANCH WORKFLOW CONTEXT E2E [SCAN [PIPELINE_PARAMETERS]]   (CONTEXT: the context of the setup job, or "none")
check() {
  local branch=$1 want_wf=$2 want_ctx=$3 want_e2e=$4 want_scan=${5:-false} params=${6:-"{}"} got_wf got_ctx got_e2e got_scan
  rows=$((rows + 1))
  sed "s|<< pipeline.git.branch >>|${branch}|g" "$config" > "$tmp/config.yml"
  "$cli" config process "$tmp/config.yml" --pipeline-parameters "$params" > "$tmp/compiled.yml" 2> "$tmp/err" || { echo "FAIL ${branch}: config process failed"; cat "$tmp/err"; failed=$((failed + 1)); return; }
  yq -o=json '.' "$tmp/compiled.yml" > "$tmp/compiled.json"
  got_wf=$(jq -r '[.workflows | del(.version) | keys[]] | join(",")' "$tmp/compiled.json")
  got_ctx=$(jq -r '[.workflows | del(.version) | .[] | .jobs[] | if type == "object" then to_entries[0].value.context // empty else empty end | if type == "array" then .[] else . end] | unique | if length == 0 then "none" else join(",") end' "$tmp/compiled.json")
  got_e2e=$(jq -r '[.jobs.setup.steps[] | objects | .run.command? // empty | select(contains("setup-gate.sh")) | capture("--e2e \"(?<v>[a-z]+)\"").v] | join(",")' "$tmp/compiled.json")
  got_scan=$(jq -r '[.jobs.setup.steps[] | objects | .run.command? // empty | select(contains("setup-gate.sh")) | capture("--scan \"(?<v>[a-z]+)\"").v] | join(",")' "$tmp/compiled.json")
  if [ "$got_wf" = "$want_wf" ] && [ "$got_ctx" = "$want_ctx" ] && [ "$got_e2e" = "$want_e2e" ] && [ "$got_scan" = "$want_scan" ]; then
    echo "ok   ${branch} ${params}: workflow=${got_wf} context=${got_ctx} e2e=${got_e2e} scan=${got_scan}"
  else
    echo "FAIL ${branch} ${params}: workflow=${got_wf} context=${got_ctx} e2e=${got_e2e} scan=${got_scan}; want workflow=${want_wf} context=${want_ctx} e2e=${want_e2e} scan=${want_scan}"
    failed=$((failed + 1))
  fi
}

# the e2e branches: the context is attached
check main setup-e2e "$context" true
check smr-swarm/v2 setup-e2e "$context" true
check smr-swarm/docs/x setup-e2e "$context" true
# every other branch: no context at all, e2e off
check feature/x setup-plain none false
check smr-scratch/windows-runtime setup-plain none false
check smr-swarmx/y setup-plain none false
check feature/smr-swarm/x setup-plain none false
check main-old setup-plain none false
check Main setup-plain none false
check pull/12 setup-plain none false
# the weekly scan: setup-scan on every branch, no context even on the e2e branches, the gate told --scan true
scan='{security-scan: true}'
check main setup-scan none false true "$scan"
check smr-swarm/v2 setup-scan none false true "$scan"
check feature/x setup-scan none false true "$scan"
check pull/12 setup-scan none false true "$scan"
# the parameter at its default or set to false is the ordinary decision
check main setup-e2e "$context" true false '{security-scan: false}'

echo "RESULT test=setup-config rows=${rows} failed=${failed}"
if [ "$failed" -eq 0 ]; then echo "PASS (${rows} rows: one setup workflow each, the e2e context only on main and smr-swarm/*, never in the scan)"; else echo "FAIL: ${failed} row(s)"; exit 1; fi
