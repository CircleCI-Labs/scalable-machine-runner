#!/usr/bin/env bash
# run-all.sh: every Linux test, sharing one pair of DinD containers (a Swarm manager and a worker) so
# the large images are loaded once. Prints one RESULT line per test and exits non-zero if any fails.
#
#   run-all.sh              stack-config, install, helper, ephemerality, exit80, token, task, placement,
#                           persistent, drain, limits, network, then the bats unit tests on cimg,
#                           Alpine and UBI
#   run-all.sh token drain  only these tests ("bats" is the unit-test matrix)
#
# Needs: Docker (the host's engine is not switched to Swarm mode), network access for images and the
# runner download. Env: see lib.sh (SWARM_TEST_DIND_IMAGE, SWARM_TEST_CIMG_IMAGE, SWARM_TEST_CACHE, SWARM_TEST_KEEP).
set -uo pipefail
# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

all=(stack-config install helper ephemerality exit80 token task placement persistent drain limits network bats)
tests=("$@")
[[ ${#tests[@]} -gt 0 ]] || tests=("${all[@]}")

needs_session=false
for t in "${tests[@]}"; do
  case $t in stack-config | install | helper | bats) ;; *) needs_session=true ;; esac
done
if [[ $needs_session == true ]]; then
  session_begin --worker
  export SWARM_TEST_SESSION_ACTIVE=1 SWARM_TEST_MGR SWARM_TEST_WRK
fi

failed=()
for t in "${tests[@]}"; do
  script=$tests_dir/$t.sh
  [[ $t == bats ]] && script=$tests_dir/bats/run.sh
  [[ -x $script ]] || { echo "unknown test: $t" >&2; exit 2; }
  log "=== $t"
  start=$(date +%s)
  if "$script"; then status=pass; else status=FAIL; failed+=("$t"); fi
  echo "RESULT run-all test=$t status=$status seconds=$(($(date +%s) - start))"
done

if [[ ${#failed[@]} -eq 0 ]]; then
  echo "PASS (all ${#tests[@]} test groups)"
else
  echo "FAIL: ${failed[*]}"
  exit 1
fi
