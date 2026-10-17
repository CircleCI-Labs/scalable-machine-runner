#!/usr/bin/env bash
# run-all.sh: every Linux test, sharing one pair of DinD containers (a Swarm manager and a worker) so
# the large images are loaded once. Prints one RESULT line per test and exits non-zero if any fails.
#
#   run-all.sh              stack-config, helper, ephemerality, exit80, token, task, proxy (the token proxy), placement, persistent, drain,
#                           limits, network, distributor (install, upgrade, rollback, auto, pruning), then the bats unit tests on cimg,
#                           Alpine and UBI
#   run-all.sh token drain  only these tests ("bats" is the unit-test matrix). CI runs the suite as four jobs, each with its own list
#                           (.circleci/continue.yml, the job linux-swarm); an unknown name fails before anything starts
#   run-all.sh --list       the names of all tests, one per line (lint-circleci checks that the CI jobs together run every one)
#
# Needs: Docker (the host's engine is not switched to Swarm mode), network access for images and the
# runner download. Env: see lib.sh (SWARM_TEST_DIND_IMAGE, SWARM_TEST_CIMG_IMAGE, SWARM_TEST_CACHE, SWARM_TEST_KEEP).
set -uo pipefail

all=(stack-config helper ephemerality exit80 token task proxy placement persistent drain limits network distributor bats)
if [[ ${1:-} == --list ]]; then
  printf '%s\n' "${all[@]}"
  exit 0
fi

# shellcheck source=linux/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

tests=("$@")
[[ ${#tests[@]} -gt 0 ]] || tests=("${all[@]}")

# a typo in a list of CI would otherwise fail after the other tests have run
for t in "${tests[@]}"; do
  script=$tests_dir/$t.sh
  [[ $t == bats ]] && script=$tests_dir/bats/run.sh
  [[ -x $script ]] || { echo "unknown test: $t" >&2; exit 2; }
done

needs_session=false
for t in "${tests[@]}"; do
  case $t in stack-config | helper | bats) ;; *) needs_session=true ;; esac
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
