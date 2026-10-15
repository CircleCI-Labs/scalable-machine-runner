#!/usr/bin/env bash
# setup-gate.sh: decide which suites a pipeline runs. The setup job (.circleci/config.yml) calls it and passes
# the printed JSON on as the parameters of the continuation config (.circleci/continue.yml).
#
#   ci/setup-gate.sh --e2e true|false --full true|false [--scan true|false] [--changed FILE] [--releasable true|false] > parameters.json
#
#   --e2e         true only for the setup job of the workflow that has the scalable-machine-runner-e2e context attached
#                 (branches main and smr-swarm/*). The plain job has no context and passes false, so e2e stays off
#                 even if a runner token appears in its environment.
#   --full        the pipeline parameter `full` (a manual run through the API): adds the full suite on any branch.
#   --scan        true only for the setup job of the workflow `setup-scan`, which a scheduled pipeline starts through the
#                 pipeline parameter `security-scan`: the weekly security scan and nothing else. It excludes --e2e true.
#   --changed     a file with the paths that this push changes, one per line (ci/changed-files.sh). Without it, or empty,
#                 the changes are not known and every suite that the branch allows runs.
#   --releasable  true when a commit of the push would make a release (ci/changed-files.sh --releasable). Only main looks at
#                 it. Without it the answer is true.
#
# Environment: CIRCLE_BRANCH, and E2E_RUNNER_TOKEN_LINUX and E2E_RUNNER_TOKEN_WINDOWS (only present with the
# context). Token values are tested for presence and never printed.
#
# Rules (docs/ci.md, "When things run, and the setup gate"):
#   e2e branch   main or smr-swarm/*: the only branches that may use the e2e tokens
#   full-suite   branch main, or --full true (a manual run, or a schedule, that sets the pipeline parameter `full`): the Windows Server 2025
#                jobs and linux-mixed-arch, the two most expensive suites. smr-swarm/* does not get them
#   windows, proxy-image, microvm   the heavy suites: the Windows Server 2022 jobs, the token proxy image jobs and linux-microvm. They run on
#                main and with --full true, and on any other branch only when a changed path is one that the suite reads (suite_path below),
#                or when the changed files are not known. A docs-only change turns them off
#   e2e-linux    --e2e true, an e2e branch, and E2E_RUNNER_TOKEN_LINUX non-empty
#   e2e-windows  the same with E2E_RUNNER_TOKEN_WINDOWS
#   release      branch main and both e2e flags
#   strict       the same condition as release, but a docs-only change does not turn it off: this is the production project, where a missing
#                publishing credential (Docker Hub, GITHUB_TOKEN) must fail the job, not skip it. The jobs get it as REQUIRE_CREDENTIALS
#   publish      branch main, and not docs-only: the jobs that push the token proxy image to Docker Hub (sha-<12> only) run, with the
#                context scalable-machine-runner-dockerhub. No other branch, a pull request included, can reach it. It does not need the
#                e2e tokens (the image of main is published whatever the e2e says), and the release requires the publication
#   docs-only    --changed lists at least one path and every path is documentation (docs/, site/, *.md, but not
#                docs/microvm.md, which linux/tests/microvm.sh reads), --full is false, and on main no commit of the push
#                would make a release (cliff.toml: a `fix(docs):` commit releases, a `docs:` commit does not). It
#                turns full-suite, e2e-linux, e2e-windows and release off: lint and the docs site build still run.
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
  jq -n -c '{"full-suite": false, "windows": false, "proxy-image": false, "microvm": false, "e2e-linux": false, "e2e-windows": false, "release": false, "strict": false, "publish": false, "docs-only": false, "security-scan": true}'
  exit 0
fi

eligible=false
case ${branch} in
  main | smr-swarm/*) eligible=true ;;
esac

full=false
reason="branch ${branch:-<none>} runs lint, builds and local tests, and the heavy suites for the files it changes"
if [ "${branch}" = main ]; then full=true; reason=main; fi
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
strict=false
if [ "${branch}" = main ] && [ "${linux}${windows}" = truetrue ]; then
  release=true
  strict=true
  echo "release:     true (main with both e2e tokens: the release job waits for every other job)" >&2
  echo "strict:      true (a production main: a missing publishing credential fails the job)" >&2
else
  echo "release:     false (only main with both e2e tokens releases)" >&2
  echo "strict:      false (a missing publishing credential skips the publication with a message)" >&2
fi

# The changed paths, one per line (ci/changed-files.sh). Empty when they are not known.
changed=()
if [ -n "${changed_file}" ] && [ -f "${changed_file}" ]; then
  while IFS= read -r path; do
    [ -z "${path}" ] || changed+=("${path}")
  done < "${changed_file}"
fi

# suite_path SUITE PATH: succeeds when the changed path PATH is one that the heavy suite reads or builds. ci/ and .circleci/ are in every suite:
# they are the scripts and the jobs of them all.
suite_path() {
  case $1:$2 in
    windows:windows/* | windows:ci/* | windows:.circleci/* | windows:PSScriptAnalyzerSettings.psd1) return 0 ;;
    proxy-image:proxy/* | proxy-image:ci/* | proxy-image:.circleci/* | proxy-image:windows/tests/*) return 0 ;;
    microvm:linux/stack/* | microvm:linux/tests/* | microvm:docs/microvm.md | microvm:ci/* | microvm:.circleci/*) return 0 ;;
  esac
  return 1
}
# heavy SUITE: prints true or false, and the reason on stderr
heavy() {
  local suite=$1 path
  if [ "${full}" = true ]; then echo "${suite}: true (${reason})" >&2; echo true; return; fi
  if [ "${#changed[@]}" -eq 0 ]; then echo "${suite}: true (the changed files are not known)" >&2; echo true; return; fi
  for path in "${changed[@]}"; do
    if suite_path "${suite}" "${path}"; then echo "${suite}: true (${path} changes)" >&2; echo true; return; fi
  done
  echo "${suite}: false (no changed file is read by this suite)" >&2
  echo false
}
windows_suite=$(heavy windows)
proxy_image=$(heavy proxy-image)
microvm=$(heavy microvm)

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
publish=false
if [ "${docs_only}" = true ]; then
  echo "docs-only:   true (${docs_reason}): the flags above are turned off; lint and the docs site build still run" >&2
  full=false linux=false windows=false release=false windows_suite=false proxy_image=false microvm=false
else
  echo "docs-only:   false (${docs_reason})" >&2
  [ "${branch}" != main ] || publish=true
fi
if [ "${publish}" = true ]; then
  echo "publish:     true (main: the token proxy image is pushed when the context has the Docker Hub credentials)" >&2
else
  echo "publish:     false (only main publishes, and not for a change of documentation only)" >&2
fi

jq -n -c --argjson full "${full}" --argjson win_suite "${windows_suite}" --argjson proxy_image "${proxy_image}" --argjson microvm "${microvm}" \
  --argjson linux "${linux}" --argjson windows "${windows}" --argjson release "${release}" --argjson strict "${strict}" \
  --argjson publish "${publish}" --argjson docs "${docs_only}" \
  '{"full-suite": $full, "windows": $win_suite, "proxy-image": $proxy_image, "microvm": $microvm, "e2e-linux": $linux, "e2e-windows": $windows, "release": $release, "strict": $strict, "publish": $publish, "docs-only": $docs, "security-scan": false}'
