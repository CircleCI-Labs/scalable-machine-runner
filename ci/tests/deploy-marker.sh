#!/usr/bin/env bash
# deploy-marker.sh test: ci/deploy-marker.sh against a stub `circleci` that records its arguments. Checks the calls of a
# good deploy, a failed one, an update with no plan, the final status that cannot change, a task agent that refuses
# calls, and a run outside CircleCI. Needs only bash.
#
# Usage: ci/tests/deploy-marker.sh
set -euo pipefail
marker=$(cd "$(dirname "$0")/.." && pwd)/deploy-marker.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/circleci" <<'EOF'
#!/usr/bin/env bash
# stub: log the call; fail when STUB_FAIL names the subcommand
echo "$*" >> "$STUB_LOG"
[ "${STUB_FAIL:-}" != "$3" ] || exit 1
EOF
chmod +x "$tmp/bin/circleci"

failed=0
rows=0
export STUB_LOG="$tmp/calls" DEPLOY_MARKER_DIR="$tmp/state" CIRCLECI=true PATH="$tmp/bin:$PATH"
reset() { rm -rf "$tmp/calls" "$tmp/state"; unset STUB_FAIL; }
# step ARGS...: one call of the script; its exit status goes to $rc
step() { rc=0; "$marker" "$@" > "$tmp/out" 2>&1 || rc=$?; }
# check NAME WANT_EXIT WANT_CALLS: compare the exit status of the last step and the recorded calls
check() {
  local name=$1 want_rc=$2 want_calls=$3 got_calls=""
  rows=$((rows + 1))
  [ ! -f "$tmp/calls" ] || got_calls=$(cat "$tmp/calls")
  if [ "$rc" != "$want_rc" ] || [ "$got_calls" != "$want_calls" ]; then
    echo "FAIL ${name}: exit ${rc} (want ${want_rc}), calls:"; echo "$got_calls"; echo "want:"; echo "$want_calls"
    failed=$((failed + 1))
  else
    echo "ok   ${name}"
  fi
}
nl=$'\n'

reset
step plan release machine-runner-swarm github-releases v0.2.0
step update release RUNNING
step update release SUCCESS
check "plan, running, success" 0 "run release plan release --environment-name=github-releases --component-name=machine-runner-swarm --target-version=v0.2.0${nl}run release update release --status=RUNNING${nl}run release update release --status=SUCCESS"

reset
step plan docs-site docs-site github-pages 0123abc
step update docs-site FAILED "site/publish.sh failed${nl}second line"
step update docs-site SUCCESS
check "failure with a reason; a second final status is not sent" 0 "run release plan docs-site --environment-name=github-pages --component-name=docs-site --target-version=0123abc${nl}run release update docs-site --status=FAILED --failure-reason=site/publish.sh failed second line"

reset
step update release FAILED "no plan"
check "update with no plan calls nothing" 0 ""

reset
STUB_FAIL=plan step plan release machine-runner-swarm github-releases v0.2.0
step update release FAILED "after a failed plan"
check "a refused plan does not fail the job, and nothing is updated" 0 "run release plan release --environment-name=github-releases --component-name=machine-runner-swarm --target-version=v0.2.0"

reset
step plan release machine-runner-swarm github-releases v0.2.0
STUB_FAIL=update step update release SUCCESS
check "a refused update does not fail the job" 0 "run release plan release --environment-name=github-releases --component-name=machine-runner-swarm --target-version=v0.2.0${nl}run release update release --status=SUCCESS"

reset
CIRCLECI='' step plan release machine-runner-swarm github-releases v0.2.0
check "outside CircleCI nothing is called" 0 ""

# guard: a command that ends by itself is passed through, and a cancel (SIGTERM) gives the deploy CANCELED
reset
step plan release machine-runner-swarm github-releases v0.2.0
step update release RUNNING
step guard release true
check "guard: a command that passes sends no status" 0 "run release plan release --environment-name=github-releases --component-name=machine-runner-swarm --target-version=v0.2.0${nl}run release update release --status=RUNNING"
step guard release bash -c 'exit 7'
check "guard: the exit status of a failing command is kept, and no status is sent" 7 "run release plan release --environment-name=github-releases --component-name=machine-runner-swarm --target-version=v0.2.0${nl}run release update release --status=RUNNING"
reset
step plan release machine-runner-swarm github-releases v0.2.0
step update release RUNNING
"$marker" guard release sleep 30 > "$tmp/out" 2>&1 &
gpid=$!
sleep 1
cpid=$(pgrep -P "$gpid" | head -n 1)
kill -TERM "$gpid"
rc=0; wait "$gpid" || rc=$?
check "guard: a cancel gives the deploy CANCELED and exits 143" 143 "run release plan release --environment-name=github-releases --component-name=machine-runner-swarm --target-version=v0.2.0${nl}run release update release --status=RUNNING${nl}run release update release --status=CANCELED"
rows=$((rows + 1))
if [ -n "$cpid" ] && kill -0 "$cpid" 2> /dev/null; then echo "FAIL guard: the command is still running"; failed=$((failed + 1)); kill "$cpid" || true; else echo "ok   guard: the command was stopped"; fi
reset
step guard release
check "guard with no command is a usage error" 2 ""

reset
step update release DONE
check "a bad status is a usage error" 2 ""
step plan release only-three args
check "a plan with missing arguments is a usage error" 2 ""
step plan 'bad name' c e v
check "a bad deploy name is a usage error" 2 ""
step unknown release
check "an unknown command is a usage error" 2 ""

echo "RESULT test=deploy-marker rows=${rows} failed=${failed}"
if [ "$failed" -eq 0 ]; then echo "PASS (${rows} rows)"; else echo "FAIL: ${failed} row(s)"; exit 1; fi
