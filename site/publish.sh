#!/usr/bin/env bash
# Publish the built site (site/public) to the gh-pages branch (docs/ci.md, "Docs site").
#
#   GITHUB_TOKEN=... site/publish.sh
#
# The branch holds only generated files: every publication replaces them all, so a deleted page disappears, and it
# adds .nojekyll, so that GitHub Pages serves the files as they are. The first run creates the branch without a
# parent (an orphan). Nothing is published without GITHUB_TOKEN, and nothing is pushed when the site did not change.
# The commit message carries [skip ci]: a push to gh-pages must not start a pipeline.
#
# Environment:
#   GITHUB_TOKEN     from the context scalable-machine-runner-docs (a fine-grained token with Contents: write).
#                    Passed to git through GIT_ASKPASS, so that it is neither on a command line nor in a URL.
#   PUBLISH_REMOTE   the remote (default: the GitHub repository of the CircleCI project)
#   PUBLISH_BRANCH   the branch (default: gh-pages)
#   REQUIRE_CREDENTIALS   true or 1 on a production main (the setup gate): a missing GITHUB_TOKEN fails the job instead of skipping the publication
#
# Never run this with `set -x`: GITHUB_TOKEN is in the environment.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
branch="${PUBLISH_BRANCH:-gh-pages}"
remote="${PUBLISH_REMOTE:-https://github.com/${CIRCLE_PROJECT_USERNAME:-}/${CIRCLE_PROJECT_REPONAME:-}.git}"
sha="${CIRCLE_SHA1:-$(git -C "${here}" rev-parse HEAD)}"

[ -f "${here}/public/index.html" ] || { echo "publish: no site in ${here}/public: run hugo first" >&2; exit 1; }
if [ -z "${GITHUB_TOKEN:-}" ]; then
  case "${REQUIRE_CREDENTIALS:-}" in
    1 | true) echo "publish: GITHUB_TOKEN is not set (context scalable-machine-runner-docs), and this pipeline must publish (REQUIRE_CREDENTIALS=${REQUIRE_CREDENTIALS})" >&2; exit 1 ;;
  esac
  echo "publish: skipped: GITHUB_TOKEN is not set (context scalable-machine-runner-docs). The site was built and checked only."
  exit 0
fi
case "${remote}" in
  https://github.com//*) echo "publish: set PUBLISH_REMOTE outside CircleCI" >&2; exit 1 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
printf '#!/bin/sh\necho "${GITHUB_TOKEN}"\n' > "${tmp}/askpass"
chmod 700 "${tmp}/askpass"
export GIT_ASKPASS="${tmp}/askpass" GIT_TERMINAL_PROMPT=0
# Git asks the helper for the user name too, but a user name in the URL (https only) answers that question.
case "${remote}" in https://*) remote="https://x-access-token@${remote#https://}" ;; esac

git init -q -b "${branch}" "${tmp}/work"
cd "${tmp}/work"
git config user.name "CircleCI docs publisher"
git config user.email "docs-publish@circleci.invalid"
# Commit the bytes as built: the pages carry integrity hashes of their scripts, so a line ending that git
# converted (core.autocrlf in a global config, a .gitattributes file) would make the browser refuse a script.
git config core.autocrlf false
git config core.safecrlf false
git config core.attributesFile /dev/null
# 0: the branch exists, 2: it does not, anything else: the remote cannot be read (a bad token, for example).
rc=0
git ls-remote --exit-code --heads "${remote}" "${branch}" > /dev/null || rc=$?
case "${rc}" in
  0)
    git fetch -q --depth 1 "${remote}" "${branch}"
    git reset -q --soft FETCH_HEAD
    echo "publish: ${branch} exists: adding a commit" ;;
  2) echo "publish: ${branch} does not exist: creating it as an orphan" ;;
  *) echo "publish: cannot read the remote (git exit code ${rc})" >&2; exit 1 ;;
esac
# The working tree is empty here and the index too, so the new files replace the old ones: a deleted page disappears.
cp -R "${here}/public/." .
touch .nojekyll
git add -A
if git diff --cached --quiet; then
  echo "publish: the site did not change: nothing to publish"
  exit 0
fi
git commit -q -m "docs: publish the site of ${sha} [skip ci]"
git push -q "${remote}" "HEAD:refs/heads/${branch}"
echo "publish: pushed ${branch} (site of ${sha})"
