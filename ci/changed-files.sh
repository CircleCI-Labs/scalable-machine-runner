#!/usr/bin/env bash
# changed-files.sh: the facts about a push that the setup gate path-filters on (ci/setup-gate.sh, docs/ci.md,
# "When things run, and the setup gate"). The setup job runs it after `checkout`.
#
#   ci/changed-files.sh               the paths that the push changes, one per line. Nothing when they are not known.
#   ci/changed-files.sh --releasable  "true" when a commit of the push would make a release (cliff.toml), or when that is
#                                     not known; "false" when none would
#
# Which commits: on main, the commits since the commit of the build that ran before (BASE_REVISION, the pipeline value
# pipeline.git.base_revision), so that a push of several commits is judged as a whole. On every other branch, the commits
# since the merge base with origin/main: the whole pull request, whatever the last push held. A base that cannot be found (the
# first build of a branch, a pipeline started through the API, a base that the clone does not hold, a failed fetch) is
# "not known": the gate then runs everything. The script exits 0 in that case and says why on stderr.
#
# "Would make a release" follows cliff.toml, and is true for more than what it releases, never for less: a conventional commit
# whose type is not one that cliff.toml skips (the pattern is read from the file), or a breaking one ("type!:" or a
# BREAKING CHANGE footer, which cliff.toml lists before it skips anything). A commit that is not conventional (a GitHub merge
# commit) is ignored by cliff.toml, so it is ignored here.
set -euo pipefail

mode=paths
case "${1:-}" in
  "") ;;
  --releasable) mode=releasable ;;
  *) echo "usage: ci/changed-files.sh [--releasable]" >&2; exit 2 ;;
esac

cd "$(git rev-parse --show-toplevel)"
head_rev=$(git rev-parse HEAD)
branch=${CIRCLE_BRANCH:-}

# Prints the base commit, or says why there is none and returns 1.
find_base() {
  local base=${BASE_REVISION:-}
  if [ "${branch}" = main ]; then
    # An unset pipeline value reaches the job as "<nil>".
    [[ "${base}" =~ ^[0-9a-f]{40}$ ]] || { echo "changed-files: no base revision (the first build of the branch, or a pipeline started through the API)" >&2; return 1; }
    git cat-file -e "${base}^{commit}" 2> /dev/null || git fetch --quiet --no-tags origin "${base}" 2> /dev/null || true
    git cat-file -e "${base}^{commit}" 2> /dev/null || { echo "changed-files: the base revision ${base} is not in the clone" >&2; return 1; }
    echo "${base}"
  else
    if [ "$(git rev-parse --is-shallow-repository)" = true ]; then git fetch --quiet --no-tags --unshallow origin 2> /dev/null || true; fi
    git fetch --quiet --no-tags origin '+refs/heads/main:refs/remotes/origin/main' 2> /dev/null || { echo "changed-files: cannot fetch origin/main" >&2; return 1; }
    git merge-base refs/remotes/origin/main "${head_rev}" 2> /dev/null || { echo "changed-files: no merge base with origin/main" >&2; return 1; }
  fi
}

# true when a commit of base..HEAD would make a release.
releasable() {
  local base=$1 skip commit subject body
  local conventional='^[A-Za-z]+(\([^)]*\))?(!)?:'
  skip=$(sed -nE 's/^  \{ message = "(\^\(.*\))", skip = true \},$/\1/p' cliff.toml | head -n 1)
  for commit in $(git rev-list "${base}..${head_rev}"); do
    subject=$(git log -1 --format=%s "${commit}")
    body=$(git log -1 --format=%b "${commit}")
    [[ "${subject}" =~ ${conventional} ]] || continue
    [ -z "${BASH_REMATCH[2]}" ] || return 0
    if grep -Eq '^BREAKING[ -]CHANGE' <<< "${body}"; then return 0; fi
    if [ -n "${skip}" ] && grep -Eq "${skip}" <<< "${subject}"; then continue; fi
    return 0
  done
  return 1
}

if ! base=$(find_base); then
  [ "${mode}" = paths ] || echo true
  exit 0
fi
if [ "${mode}" = releasable ]; then
  if releasable "${base}"; then echo true; else echo false; fi
else
  git -c core.quotepath=false diff --name-only --no-renames "${base}" "${head_rev}"
fi
