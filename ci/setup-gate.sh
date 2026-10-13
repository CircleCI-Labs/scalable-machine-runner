#!/usr/bin/env bash
# setup-gate.sh: decide which suites a pipeline runs. The setup job (.circleci/config.yml) calls it and passes
# the printed JSON on as the parameters of the continuation config (.circleci/continue.yml).
#
#   ci/setup-gate.sh --e2e true|false --full true|false > parameters.json
#
#   --e2e   true only for the setup job of the workflow that has the scalable-machine-runner-e2e context attached
#           (branches main and smr-swarm/*). The plain job has no context and passes false, so e2e stays off
#           even if a runner token appears in its environment.
#   --full  the pipeline parameter `full` (a manual run through the API): adds the full suite on any branch.
#
# Environment: CIRCLE_BRANCH, and E2E_RUNNER_TOKEN_LINUX and E2E_RUNNER_TOKEN_WINDOWS (only present with the
# context). Token values are tested for presence and never printed.
#
# Rules (docs/ci.md, "When things run, and the setup gate"):
#   e2e branch   main or smr-swarm/*: the only branches that may use the e2e tokens
#   full-suite   an e2e branch, or --full true
#   e2e-linux    --e2e true, an e2e branch, and E2E_RUNNER_TOKEN_LINUX non-empty
#   e2e-windows  the same with E2E_RUNNER_TOKEN_WINDOWS
#   release      branch main and both e2e flags
set -euo pipefail

e2e=false
full_param=false
while [ $# -gt 0 ]; do
  case $1 in
    --e2e) e2e=${2:?--e2e needs true or false}; shift 2 ;;
    --full) full_param=${2:?--full needs true or false}; shift 2 ;;
    *) echo "usage: setup-gate.sh --e2e true|false --full true|false" >&2; exit 2 ;;
  esac
done
case ${e2e}:${full_param} in
  true:true | true:false | false:true | false:false) ;;
  *) echo "setup-gate.sh: --e2e and --full must be true or false" >&2; exit 2 ;;
esac

branch=${CIRCLE_BRANCH:-}
eligible=false
case ${branch} in
  main | smr-swarm/*) eligible=true ;;
esac

full=${eligible}
reason="branch ${branch:-<none>} runs lint, builds and local tests only"
if [ "${eligible}" = true ]; then reason=${branch}; fi
if [ "${full_param}" = true ]; then full=true; reason="pipeline parameter full=true"; fi

present() { if [ -n "${!1:-}" ]; then echo present; else echo absent; fi; }
linux=false
windows=false
if [ "${e2e}" = true ] && [ "${eligible}" = true ]; then
  [ -z "${E2E_RUNNER_TOKEN_LINUX:-}" ] || linux=true
  [ -z "${E2E_RUNNER_TOKEN_WINDOWS:-}" ] || windows=true
fi

{
  echo "full-suite:  ${full} (${reason})"
  if [ "${e2e}" = true ]; then
    echo "e2e-linux:   ${linux} (E2E_RUNNER_TOKEN_LINUX $(present E2E_RUNNER_TOKEN_LINUX))"
    echo "e2e-windows: ${windows} (E2E_RUNNER_TOKEN_WINDOWS $(present E2E_RUNNER_TOKEN_WINDOWS))"
    if [ "${linux}${windows}" != truetrue ]; then
      echo "An e2e workflow is skipped because its token is absent. The scalable-machine-runner-e2e"
      echo "context is missing, restricted for this pipeline, or lacks the secret. See docs/ci.md."
    fi
  else
    echo "e2e-linux:   false (this job has no context: branch ${branch:-<none>} never uses the e2e tokens)"
    echo "e2e-windows: false (this job has no context)"
  fi
} >&2

release=false
if [ "${branch}" = main ] && [ "${linux}${windows}" = truetrue ]; then
  release=true
  echo "release:     true (main with both e2e tokens: the release job waits for every other job)" >&2
else
  echo "release:     false (only main with both e2e tokens releases)" >&2
fi

jq -n -c --argjson full "${full}" --argjson linux "${linux}" --argjson windows "${windows}" --argjson release "${release}" \
  '{"full-suite": $full, "e2e-linux": $linux, "e2e-windows": $windows, "release": $release}'
