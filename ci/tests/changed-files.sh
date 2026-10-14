#!/usr/bin/env bash
# changed-files.sh test: ci/changed-files.sh on throwaway repositories (a bare "origin" and a clone), for the cases that the
# docs-only decision of the setup gate depends on: which commits count on main and on a branch, a push of several commits,
# a base that is not known, a shallow clone, and which commit types would make a release (it follows cliff.toml).
# Needs git and bash; no network.
#
# Usage: ci/tests/changed-files.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
script=$repo/ci/changed-files.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
failed=0
rows=0

# fresh: a new origin with main at C0 (cliff.toml, docs/a.md, ci/x.sh) and a clone of it in $tmp/work
fresh() {
  rm -rf "$tmp/origin.git" "$tmp/work"
  git init -q --bare -b main "$tmp/origin.git"
  git clone -q "file://$tmp/origin.git" "$tmp/work" 2> /dev/null
  git -C "$tmp/work" checkout -q -b main
  mkdir -p "$tmp/work/docs" "$tmp/work/ci"
  cp "$repo/cliff.toml" "$tmp/work/cliff.toml"
  echo a > "$tmp/work/docs/a.md"
  echo x > "$tmp/work/ci/x.sh"
  git -C "$tmp/work" add -A
  git -C "$tmp/work" commit -q -m "feat: the first commit"
  git -C "$tmp/work" push -q origin main
  c0=$(git -C "$tmp/work" rev-parse HEAD)
}
# commit FILE MESSAGE...: change FILE and commit it with the message (one -m for each argument)
commit() {
  local file=$1 args=() m; shift
  for m in "$@"; do args+=(-m "$m"); done
  mkdir -p "$(dirname "$tmp/work/$file")"
  echo "$RANDOM" >> "$tmp/work/$file"
  git -C "$tmp/work" add -A
  git -C "$tmp/work" commit -q "${args[@]}"
}
# facts BRANCH BASE: the paths (joined by a space) and the releasable answer of the clone, as the setup job asks for them
facts() {
  local branch=$1 base=$2
  paths=$(cd "$tmp/work" && CIRCLE_BRANCH=$branch BASE_REVISION=$base "$script" 2> "$tmp/err" | tr '\n' ' ' | sed 's/ $//')
  releasable=$(cd "$tmp/work" && CIRCLE_BRANCH=$branch BASE_REVISION=$base "$script" --releasable 2> /dev/null)
}
# check NAME WANT_PATHS WANT_RELEASABLE
check() {
  rows=$((rows + 1))
  if [ "$paths" = "$2" ] && [ "$releasable" = "$3" ]; then echo "ok   $1: paths '$paths', releasable $releasable"
  else echo "FAIL $1: paths '$paths' releasable $releasable; want '$2' $3"; failed=$((failed + 1)); fi
}

fresh; commit docs/a.md "docs: update a"
facts main "$c0"; check "main: one docs commit" "docs/a.md" false

fresh; commit ci/x.sh "fix: change the script"; commit docs/b.md "docs: add b"
facts main "$c0"; check "main: a push of two commits is judged as a whole" "ci/x.sh docs/b.md" true

fresh; commit docs/a.md "fix(docs): correct a command"
facts main "$c0"; check "main: fix(docs) touches only docs and releases" "docs/a.md" true

fresh; commit docs/a.md "feat(docs): a new page"
facts main "$c0"; check "main: feat(docs) releases" "docs/a.md" true

for subject in "ci(deps): update CI images" "chore: tidy" "test: more" "refactor: x" "style: y" "build: z" "docs(site): nav" "Merge pull request #3 from a/b"; do
  fresh; commit docs/a.md "$subject"
  facts main "$c0"; check "main: '$subject' makes no release" "docs/a.md" false
done
for subject in "perf: faster" "revert: undo" "wip: something" "docs!: rename a page" "ci(deps)!: drop a tool"; do
  fresh; commit docs/a.md "$subject"
  facts main "$c0"; check "main: '$subject' makes a release" "docs/a.md" true
done
fresh; commit docs/a.md "docs: change a" "BREAKING CHANGE: the layout of the docs changed"
facts main "$c0"; check "main: a BREAKING CHANGE footer makes a release" "docs/a.md" true

fresh; commit docs/a.md "docs: update a"
facts main "<nil>"; check "main: no base revision (an unset pipeline value)" "" true
facts main ""; check "main: an empty base revision" "" true
facts main "0000000000000000000000000000000000000000"; check "main: a base that the clone does not hold" "" true

# a branch: the whole pull request, from the merge base with origin/main, not what main did meanwhile
fresh
git -C "$tmp/work" checkout -q -b feature/x
commit docs/a.md "docs: on the branch"
git -C "$tmp/work" push -q origin feature/x
git -C "$tmp/work" checkout -q main; commit ci/y.sh "fix: main moves on"; git -C "$tmp/work" push -q origin main
git -C "$tmp/work" checkout -q feature/x
facts feature/x ""; check "branch: only the commits of the branch" "docs/a.md" false
commit ci/x.sh "ci: and a script"
facts feature/x ""; check "branch: a later push does not hide an earlier one" "ci/x.sh docs/a.md" false
git -C "$tmp/work" push -q origin feature/x
# the same in a shallow clone, as the checkout step may make it
rm -rf "$tmp/work"; git clone -q --depth 1 --branch feature/x "file://$tmp/origin.git" "$tmp/work" 2> /dev/null
facts feature/x ""; check "branch, shallow clone" "ci/x.sh docs/a.md" false

# a branch that has nothing of its own, and a bad invocation
fresh; git -C "$tmp/work" checkout -q -b feature/empty
facts feature/empty ""; check "branch: no commit of its own" "" false
rows=$((rows + 1))
if (cd "$tmp/work" && "$script" --bogus > /dev/null 2>&1); then echo "FAIL a bad option was accepted"; failed=$((failed + 1)); else echo "ok   a bad option is rejected"; fi

echo "RESULT test=changed-files rows=${rows} failed=${failed}"
if [ "$failed" -eq 0 ]; then echo "PASS (${rows} rows)"; else echo "FAIL: ${failed} row(s)"; exit 1; fi
