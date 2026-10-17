#!/usr/bin/env bash
# setup-gate.sh: decide which suites a pipeline runs. The setup job (.circleci/config.yml) calls it and passes
# the printed JSON on as the parameters of the continuation config (.circleci/continue.yml).
#
#   ci/setup-gate.sh --e2e true|false --full true|false [--scan true|false] [--changed FILE] [--releasable true|false] > parameters.json
#
#   --e2e         true only for the setup job of the workflow that has the scalable-machine-runner-e2e context attached
#                 (branches main and smr-swarm/*). The plain job has no context and passes false, so e2e stays off
#                 even if a runner token appears in its environment.
#   --full        the pipeline parameter `full` (a manual run through the API): runs every suite on any branch.
#   --scan        true only for the setup job of the workflow `setup-scan`, which a scheduled pipeline starts through the
#                 pipeline parameter `security-scan`: the weekly security scan and nothing else. It excludes --e2e true.
#   --changed     a file with the paths that this push changes, one per line (ci/changed-files.sh). Without it, or empty,
#                 the changes are not known and every suite that the branch allows runs.
#   --releasable  true when a commit of the push would make a release (ci/changed-files.sh --releasable). Only main looks at
#                 it. Without it the answer is true.
#
# Environment: CIRCLE_BRANCH, CIRCLE_PULL_REQUEST (the pull request of the push, when it has one), and E2E_RUNNER_TOKEN_LINUX and
# E2E_RUNNER_TOKEN_WINDOWS (only present with the context). Token values are tested for presence and never printed.
#
# Rules (docs/ci.md, "When things run, and the setup gate"):
#   lint         always: the lint jobs and the docs site build run on every change
#   everything   branch main when a commit of the push would make a release (--releasable true), or --full true: every suite runs,
#                and the Windows Server 2025 jobs and linux-mixed-arch (full-suite) with them
#   path gating  every other push, on any branch (main without a release included): a suite runs only when a changed path is one that
#                it reads (suite_path below), or when the changed files are not known. full-suite stays off
#   pipeline     a change to .circleci/, ci/setup-gate.sh, ci/changed-files.sh or .gitattributes runs every suite (the definition changed)
#   suites       windows, proxy-image, microvm, linux-swarm, linux-swarm-proxy, linux-smoke, linux-image, container-agent, e2e-sim,
#                proxy-test, signing, and the e2e groups e2e-linux and e2e-windows
#   proxy-test   also runs when proxy-image or e2e-windows does: they need its windows/amd64 build
#   e2e branch   main or smr-swarm/*: the only branches that may use the e2e tokens
#   e2e-linux    --e2e true, an e2e branch, E2E_RUNNER_TOKEN_LINUX non-empty, and the path gate
#   e2e-windows  the same with E2E_RUNNER_TOKEN_WINDOWS
#   release      branch main, both e2e flags, and everything (so a release job never waits for a suite that was gated off)
#   strict       branch main with both e2e tokens, whatever the path gate says, and a docs-only change does not turn it off: this is the
#                production project, where a missing publishing credential (Docker Hub, GITHUB_TOKEN) must fail the job, not skip it.
#                The jobs get it as REQUIRE_CREDENTIALS
#   publish      branch main, not docs-only, and proxy-image: the jobs that push the token proxy image to Docker Hub (sha-<12> only) replace
#                the plain image jobs, with the context scalable-machine-runner-dockerhub. No other branch, a pull request included, can
#                reach it. It does not need the e2e tokens, and the release requires the publication
#   pull-request CIRCLE_PULL_REQUEST is the address of a GitHub pull request: the job docs-site-comment runs (it holds the context that can
#                comment on a pull request, and no other job does)
#   docs-only    --changed lists at least one path and every path is documentation (docs/, site/, *.md, but not
#                docs/microvm.md, which linux/tests/microvm.sh reads), --full is false, and on main no commit of the push
#                would make a release (cliff.toml: a `fix(docs):` commit releases, a `docs:` commit does not). It
#                turns every suite and release off: lint and the docs site build still run
#   security-scan  --scan true: every flag above and docs-only are false, so no suite of the `ci` workflow runs
set -euo pipefail

e2e=false
full_param=false
scan=false
changed_file=
releasable=true

# docs_path PATH: documentation that no job but the lint and the docs site build reads. docs/microvm.md is the exception:
# linux/tests/microvm.sh takes its Docker configuration from it.
docs_path() {
  case $1 in
    docs/microvm.md) return 1 ;;
    docs/* | site/* | *.md) return 0 ;;
  esac
  return 1
}
usage() { echo "usage: setup-gate.sh --e2e true|false --full true|false [--scan true|false] [--changed FILE] [--releasable true|false]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --e2e) e2e=${2:?--e2e needs true or false}; shift 2 ;;
    --full) full_param=${2:?--full needs true or false}; shift 2 ;;
    --scan) scan=${2:?--scan needs true or false}; shift 2 ;;
    --changed) changed_file=${2:?--changed needs a file}; shift 2 ;;
    --releasable) releasable=${2:?--releasable needs true or false}; shift 2 ;;
    *) usage ;;
  esac
done

for value in "${e2e}" "${full_param}" "${scan}" "${releasable}"; do
  case ${value} in true | false) ;; *) echo "setup-gate.sh: --e2e, --full, --scan and --releasable must be true or false" >&2; exit 2 ;; esac
done
if [ "${scan}" = true ] && [ "${e2e}" = true ]; then
  echo "setup-gate.sh: --scan true never has the e2e context (--e2e true)" >&2
  exit 2
fi

branch=${CIRCLE_BRANCH:-}

# The suites that the continuation config switches on, each by the parameter of the same name. The e2e groups have their own flags
# (e2e-linux, e2e-windows), which need the tokens as well as the path.
suites=(windows proxy-image microvm linux-swarm linux-swarm-proxy linux-smoke linux-image container-agent e2e-sim proxy-test signing)
declare -A on

if [ "${scan}" = true ]; then
  {
    echo "security-scan: true (branch ${branch:-<none>}): the scan workflow only"
    echo "full-suite:  false (a scan runs no suite of the ci workflow, whatever the parameter full says)"
    echo "e2e-linux:   false (a scan has no e2e context)"
    echo "e2e-windows: false (a scan has no e2e context)"
    echo "release:     false"
    echo "docs-only:   false"
    echo "publish:     false"
  } >&2
  json=$(jq -n -c '{"full-suite": false, "e2e-linux": false, "e2e-windows": false, "release": false, "strict": false, "publish": false, "pull-request": false, "docs-only": false, "security-scan": true}')
  for s in "${suites[@]}"; do json=$(jq -c --arg k "${s}" '. + {($k): false}' <<< "${json}"); done
  echo "${json}"
  exit 0
fi

eligible=false
case ${branch} in
  main | smr-swarm/*) eligible=true ;;
esac

# The changed paths, one per line (ci/changed-files.sh). Empty when they are not known.
changed=()
if [ -n "${changed_file}" ] && [ -f "${changed_file}" ]; then
  while IFS= read -r path; do
    [ -z "${path}" ] || changed+=("${path}")
  done < "${changed_file}"
fi

# everything: the full suite. Main when a commit of the push would make a release, or a manual run (the pipeline parameter full).
everything=false
reason="branch ${branch:-<none>} runs lint, and the suites for the files it changes"
if [ "${branch}" = main ]; then
  if [ "${releasable}" = true ]; then
    everything=true
    reason="main, and a commit of this push would make a release (cliff.toml)"
  else
    reason="main, and no commit of this push would make a release (cliff.toml): the suites for the files it changes"
  fi
fi
if [ "${branch}" = main ] && [ "${#changed[@]}" -eq 0 ]; then
  everything=true
  reason="main, and the changed files are not known"
fi
if [ "${full_param}" = true ]; then everything=true; reason="pipeline parameter full=true"; fi
full=${everything}

present() { if [ -n "${!1:-}" ]; then echo present; else echo absent; fi; }
linux=false
windows=false
if [ "${e2e}" = true ] && [ "${eligible}" = true ]; then
  [ -z "${E2E_RUNNER_TOKEN_LINUX:-}" ] || linux=true
  [ -z "${E2E_RUNNER_TOKEN_WINDOWS:-}" ] || windows=true
fi
token_linux=${linux}
token_windows=${windows}

# A push whose branch has a pull request (CircleCI sets CIRCLE_PULL_REQUEST only when the pull request exists at the time of the push)
pull_request=false
if [[ "${CIRCLE_PULL_REQUEST:-}" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then pull_request=true; fi
echo "pull-request: ${pull_request} (${CIRCLE_PULL_REQUEST:-this push has no pull request})" >&2

# pipeline_path PATH: the pipeline definition. A change to it can change what every suite does, so it runs them all.
pipeline_path() {
  case $1 in
    .circleci/* | ci/setup-gate.sh | ci/changed-files.sh | .gitattributes) return 0 ;;
  esac
  return 1
}

# suite_path SUITE PATH: succeeds when the changed path PATH is one that the suite reads, builds or runs, from the job in
# .circleci/continue.yml. A path that no list names (a lint configuration, an example, a license) runs no suite: lint reads it.
suite_path() {
  local suite=$1 path=$2
  if pipeline_path "${path}"; then return 0; fi
  case ${suite}:${path} in
    # windows-swarm (2022, 2025): the stack files, the tests, the installer; ci/Invoke-Test.ps1 runs each test
    windows:windows/* | windows:ci/Invoke-Test.ps1 | windows:PSScriptAnalyzerSettings.psd1) return 0 ;;
    # the token proxy image jobs: the proxy, the image scripts, the Windows image test helpers
    proxy-image:proxy/* | proxy-image:ci/proxy-image.sh | proxy-image:ci/tools.sh | proxy-image:ci/tests/proxy-image.sh) return 0 ;;
    proxy-image:ci/Build-ProxyImage.ps1 | proxy-image:ci/build-proxy.sh | proxy-image:ci/deploy-marker.sh | proxy-image:windows/tests/SwarmTestHelpers.psm1) return 0 ;;
    # linux-microvm builds the proxy image from proxy/, deploys linux/stack/microvm.yaml and reads the Docker configuration of docs/microvm.md
    microvm:linux/stack/* | microvm:linux/tests/* | microvm:proxy/* | microvm:docs/microvm.md) return 0 ;;
    # linux/tests/run-all.sh: the stack files, the helper (linux/setup.sh), and the pin that stack-config compares with windows/stack/runners.yaml
    linux-swarm:linux/stack/* | linux-swarm:linux/tests/* | linux-swarm:linux/setup.sh | linux-swarm:windows/stack/runners.yaml | linux-swarm:ci/config-names.sh) return 0 ;;
    # the same job group that runs the token proxy in a Swarm (linux/tests/proxy.sh builds the image from proxy/)
    linux-swarm-proxy:linux/stack/* | linux-swarm-proxy:linux/tests/* | linux-swarm-proxy:linux/setup.sh | linux-swarm-proxy:proxy/*) return 0 ;;
    linux-swarm-proxy:windows/stack/runners.yaml | linux-swarm-proxy:ci/config-names.sh) return 0 ;;
    # linux-setup and linux-arm64 (ci/linux-smoke.sh): setup.sh, the shipped stack, the proxy image built from proxy/
    linux-smoke:ci/linux-smoke.sh | linux-smoke:linux/setup.sh | linux-smoke:linux/stack/* | linux-smoke:proxy/*) return 0 ;;
    linux-image:linux/images/example/* | linux-image:.trivyignore) return 0 ;;
    container-agent:linux/stack/container-agent/*) return 0 ;;
    e2e-sim:ci/e2e-host.sh | e2e-sim:ci/e2e-probe.sh | e2e-sim:ci/tests/e2e-sim.sh) return 0 ;;
    proxy-test:proxy/* | proxy-test:ci/build-proxy.sh) return 0 ;;
    signing:ci/proxy-image.sh | signing:ci/tools.sh) return 0 ;;
    # the e2e groups: the host script, the probes, the stack they host and the proxy they build
    e2e-linux:ci/e2e-host.sh | e2e-linux:ci/e2e-probe.sh | e2e-linux:linux/setup.sh | e2e-linux:linux/stack/* | e2e-linux:proxy/*) return 0 ;;
    e2e-windows:ci/E2E-*.ps1 | e2e-windows:ci/Build-ProxyImage.ps1 | e2e-windows:ci/build-proxy.sh | e2e-windows:windows/* | e2e-windows:proxy/*) return 0 ;;
  esac
  return 1
}
# suite SUITE: prints true or false, and the reason on stderr
suite() {
  local name=$1 path
  if [ "${everything}" = true ]; then echo "${name}: true (${reason})" >&2; echo true; return; fi
  if [ "${#changed[@]}" -eq 0 ]; then echo "${name}: true (the changed files are not known)" >&2; echo true; return; fi
  for path in "${changed[@]}"; do
    if suite_path "${name}" "${path}"; then echo "${name}: true (${path} changes)" >&2; echo true; return; fi
  done
  echo "${name}: false (no changed file is read by this suite)" >&2
  echo false
}
for s in "${suites[@]}" e2e-linux e2e-windows; do on[${s}]=$(suite "${s}"); done

# The e2e groups need the tokens and the path.
[ "${on[e2e-linux]}" = true ] || linux=false
[ "${on[e2e-windows]}" = true ] || windows=false
# proxy-image (the Windows jobs) and e2e-windows require the windows/amd64 build of proxy-test.
if [ "${on[proxy-test]}" != true ] && { [ "${on[proxy-image]}" = true ] || [ "${windows}" = true ]; }; then
  on[proxy-test]=true
  echo "proxy-test: true (proxy-image or e2e-windows runs, and needs its windows/amd64 build)" >&2
fi

{
  echo "full-suite:  ${full} (${reason})"
  if [ "${e2e}" = true ]; then
    echo "e2e-linux:   ${linux} (E2E_RUNNER_TOKEN_LINUX $(present E2E_RUNNER_TOKEN_LINUX), path gate ${on[e2e-linux]})"
    echo "e2e-windows: ${windows} (E2E_RUNNER_TOKEN_WINDOWS $(present E2E_RUNNER_TOKEN_WINDOWS), path gate ${on[e2e-windows]})"
    if [ "${token_linux}${token_windows}" != truetrue ]; then
      echo "An e2e workflow is skipped because its token is absent. The scalable-machine-runner-e2e"
      echo "context is missing, restricted for this pipeline, or lacks the secret. See docs/ci.md."
    fi
  else
    echo "e2e-linux:   false (this job has no context: branch ${branch:-<none>} never uses the e2e tokens)"
    echo "e2e-windows: false (this job has no context)"
  fi
} >&2

release=false
strict=false
if [ "${branch}" = main ] && [ "${token_linux}${token_windows}" = truetrue ]; then
  strict=true
  echo "strict:      true (a production main: a missing publishing credential fails the job)" >&2
  if [ "${everything}" = true ]; then
    release=true
    echo "release:     true (main with both e2e tokens and a release to make: the release job waits for every other job)" >&2
  else
    echo "release:     false (no commit of this push would make a release: the jobs that a gate turned off are not required by anything)" >&2
  fi
else
  echo "release:     false (only main with both e2e tokens releases)" >&2
  echo "strict:      false (a missing publishing credential skips the publication with a message)" >&2
fi

# Documentation only: lint and the docs site build are enough. Anything that is not known runs everything.
docs_only=false
docs_reason="the changed files are not known"
if [ "${full_param}" = true ]; then
  docs_reason="the pipeline parameter full is true"
elif [ -n "${changed_file}" ] && [ -f "${changed_file}" ]; then
  paths=0
  docs_reason="every changed path is documentation"
  docs_only=true
  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    paths=$((paths + 1))
    if ! docs_path "${path}"; then docs_only=false; docs_reason="${path} is not documentation"; break; fi
  done < "${changed_file}"
  if [ "${paths}" -eq 0 ]; then docs_only=false; docs_reason="no changed file is listed"; fi
  if [ "${docs_only}" = true ] && [ "${branch}" = main ] && [ "${releasable}" = true ]; then
    docs_only=false
    docs_reason="a commit of this push would make a release (cliff.toml), so main runs the whole pipeline"
  fi
fi
if [ "${docs_only}" = true ]; then
  echo "docs-only:   true (${docs_reason}): the flags above are turned off; lint and the docs site build still run" >&2
  full=false linux=false windows=false release=false
  for s in "${suites[@]}"; do on[${s}]=false; done
else
  echo "docs-only:   false (${docs_reason})" >&2
fi

# publish: main pushes the proxy image it builds (sha-<12>), unless no suite builds it
publish=false
if [ "${branch}" = main ] && [ "${docs_only}" = false ] && [ "${on[proxy-image]}" = true ]; then
  publish=true
  echo "publish:     true (main: the token proxy image is pushed when the context has the Docker Hub credentials)" >&2
else
  echo "publish:     false (only main publishes, and only when it builds the proxy image: not for a change that the image does not read)" >&2
fi

json=$(jq -n -c --argjson full "${full}" --argjson linux "${linux}" --argjson windows "${windows}" --argjson release "${release}" --argjson strict "${strict}" \
  --argjson publish "${publish}" --argjson pr "${pull_request}" --argjson docs "${docs_only}" \
  '{"full-suite": $full, "e2e-linux": $linux, "e2e-windows": $windows, "release": $release, "strict": $strict, "publish": $publish, "pull-request": $pr, "docs-only": $docs, "security-scan": false}')
for s in "${suites[@]}"; do json=$(jq -c --arg k "${s}" --argjson v "${on[${s}]}" '. + {($k): $v}' <<< "${json}"); done
echo "${json}"
