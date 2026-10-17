#!/usr/bin/env bash
# Post, or update, ONE comment with the link to the docs preview on the pull request of this build (docs/ci.md,
# "Docs site previews"). It is optional and it never fails the job.
#
#   site/preview-comment.sh
#
# The job docs-site-comment runs it, and no other job does: it is the one job with the context scalable-machine-runner-pr-comments, so
# the token is in no step of the docs build. The build job (docs-site-build) hands the address over in a workspace.
#
# Environment:
#   GITHUB_PR_COMMENT_TOKEN   from the context scalable-machine-runner-pr-comments (a fine-grained token with Pull requests:
#                             read and write, for this repository only). Without it the script does nothing and says nothing.
#   CIRCLE_PULL_REQUEST       the pull request of the build (CircleCI sets it when the branch has one). Without it, no comment.
#   PREVIEW_DIR               a directory with preview-url.txt and job-url.txt, written by the job that built the preview. Without it the
#                             address is the one of this job (site/preview.sh url), for a run in the job that built it
#   CIRCLE_PROJECT_USERNAME, CIRCLE_PROJECT_REPONAME, CIRCLE_SHA1, CIRCLE_BUILD_URL, CIRCLE_WORKFLOW_JOB_ID
#   GITHUB_API_URL            the API (default https://api.github.com), for the test
#
# The comment carries a hidden marker. The script lists the comments of the pull request, updates the first one that has
# the marker, and creates one only when there is none, so a pull request never gets a second comment. The token goes to curl
# through a configuration on its standard input, so it is on no command line and in no log. Never run this with `set -x`.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
marker='<!-- machine-runner-swarm-docs-preview -->'
api=${GITHUB_API_URL:-https://api.github.com}

[ -n "${GITHUB_PR_COMMENT_TOKEN:-}" ] || exit 0
if ! [[ "${CIRCLE_PULL_REQUEST:-}" =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+)$ ]]; then
  echo "preview comment: this build has no pull request, so no comment"
  exit 0
fi
repo=${BASH_REMATCH[1]}
number=${BASH_REMATCH[2]}
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

skip() { echo "preview comment: skipped ($*)"; exit 0; }

# gh_api METHOD PATH [JSON-FILE]: the response on stdout; a failing call prints curl's one-line error, not the token.
gh_api() {
  local method=$1 path=$2 data=${3:-}
  local args=(--silent --show-error --fail --max-time 30 --request "${method}" --config -
    --header 'Accept: application/vnd.github+json' --header 'X-GitHub-Api-Version: 2022-11-28')
  if [ -n "${data}" ]; then args+=(--header 'Content-Type: application/json' --data "@${data}"); fi
  printf 'header = "Authorization: Bearer %s"\n' "${GITHUB_PR_COMMENT_TOKEN}" | curl "${args[@]}" "${api}${path}"
}

if [ -n "${PREVIEW_DIR:-}" ]; then
  preview=$(cat "${PREVIEW_DIR}/preview-url.txt" 2> /dev/null) && [ -n "${preview}" ] || skip "no preview address in ${PREVIEW_DIR}"
  build_job=$(cat "${PREVIEW_DIR}/job-url.txt" 2> /dev/null || true)
else
  preview=$("${here}/preview.sh" url) || skip "no preview address"
  build_job=${CIRCLE_BUILD_URL:-}
fi
sha=${CIRCLE_SHA1:-unknown}
jq -n --arg marker "${marker}" --arg url "${preview}" --arg sha "${sha:0:7}" --arg job "${build_job}" \
  '{body: ($marker + "\n**Docs preview** of " + $sha + ": " + $url + "\n\nBuilt by the CircleCI job " + $job +
    ". The artifacts expire (30 days by default), and the link needs access to the CircleCI project. Search and the diagrams may not work from the artifacts.")}' \
  > "${tmp}/body.json"

# The comment that this script made before: the first one with the marker (up to 500 comments are looked at).
existing=""
for page in 1 2 3 4 5; do
  gh_api GET "/repos/${repo}/issues/${number}/comments?per_page=100&page=${page}" > "${tmp}/page.json" 2> "${tmp}/err" \
    || skip "cannot list the comments: $(cut -c1-120 "${tmp}/err")"
  existing=$(jq -r --arg marker "${marker}" '[.[] | select(.body | contains($marker)) | .id] | first // empty' "${tmp}/page.json")
  if [ -n "${existing}" ] || [ "$(jq length "${tmp}/page.json")" -lt 100 ]; then break; fi
done

if [ -n "${existing}" ] && gh_api PATCH "/repos/${repo}/issues/comments/${existing}" "${tmp}/body.json" > /dev/null 2> "${tmp}/err"; then
  echo "preview comment: updated comment ${existing} on pull request ${number}"
  exit 0
fi
[ -z "${existing}" ] || echo "preview comment: cannot update comment ${existing} ($(cut -c1-120 "${tmp}/err")), posting a new one"
gh_api POST "/repos/${repo}/issues/${number}/comments" "${tmp}/body.json" > /dev/null 2> "${tmp}/err" \
  || skip "cannot post the comment: $(cut -c1-120 "${tmp}/err")"
echo "preview comment: posted on pull request ${number}"
