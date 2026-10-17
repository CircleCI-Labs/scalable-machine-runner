#!/usr/bin/env bash
# bundle-links.sh test: ci/bundle-links.py on a throwaway repository, then on this one. The release bundle leaves out the pages and the directories that are
# for maintainers, and the pages that it ships link to them: the script must turn those links into links to GitHub at the tag, and leave every other link
# alone. Needs bash, git and python3; no network, no secret.
#
# Usage: ci/tests/bundle-links.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script=${here}/../bundle-links.py
repo_root=$(cd "${here}/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
failed=0
rows=0
gh=https://github.com/o/r/blob/v1.2.3
tree=https://github.com/o/r/tree/v1.2.3

ok() { rows=$((rows + 1)); echo "ok   $1"; }
bad() { rows=$((rows + 1)); failed=$((failed + 1)); echo "FAIL $1"; }
has() { # NAME FILE TEXT
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1: '$3' is not in $2"; fi
}
hasnt() { # NAME FILE TEXT
  if grep -qF -- "$3" "$2"; then bad "$1: '$3' is in $2"; else ok "$1"; fi
}

# --- a throwaway repository ----------------------------------------------------------------------------------------------------------------
fx=${work}/fx
mkdir -p "${fx}/docs" "${fx}/linux/tests" "${fx}/ci"
cd "${fx}"
git init -q .
git config user.email t@example.invalid
git config user.name t
cat > README.md <<'EOF'
# Readme

See [the pipeline](docs/ci.md#pinned-versions), [the guide](docs/guide.md#steps), [contributing](CONTRIBUTING.md), [the scripts](ci), [the scripts again](ci/),
[a test](linux/tests/a.sh), [the changelog](CHANGELOG.md), [the version](VERSION), [the site](https://example.com/docs/ci.md), [mail](mailto:a@b.c) and [here](#top).

[ref]: docs/ci.md "a title"
[ref2]: docs/guide.md

```markdown
[not a link of this file](docs/ci.md)
```
EOF
cat > docs/guide.md <<'EOF'
# Guide

Back to [the readme](../README.md), on to [ci](ci.md), [releasing](releasing.md#how), [tests](../linux/tests/a.sh), [a directory](../linux/tests/) and [the
anchor](#steps). An [image](img/x.png).
EOF
echo '# ci' > docs/ci.md
echo '# releasing' > docs/releasing.md
echo '# contributing' > CONTRIBUTING.md
echo '# changelog of the repository' > CHANGELOG.md
echo 'echo a' > linux/tests/a.sh
echo 'echo b' > ci/b.sh
mkdir -p docs/img && echo png > docs/img/x.png
git add -A
git commit -q -m init
spec=(README.md docs ':(exclude)docs/ci.md' ':(exclude)docs/releasing.md')

run() { python3 "${script}" --repo o/r --tag v1.2.3 --out "${work}/out" --extra VERSION --extra CHANGELOG.md -- "$@" > "${work}/changed" 2> "${work}/err"; }

run "${spec[@]}" || { echo "FAIL: the script failed"; cat "${work}/err"; exit 1; }
readme=${work}/out/README.md
guide=${work}/out/docs/guide.md
has "README: a link to an excluded page"     "${readme}" "](${gh}/docs/ci.md#pinned-versions)"
has "README: a link to a page that ships"    "${readme}" "](docs/guide.md#steps)"
has "README: CONTRIBUTING.md is left out"    "${readme}" "](${gh}/CONTRIBUTING.md)"
has "README: a directory (no slash)"         "${readme}" "[the scripts](${tree}/ci)"
has "README: a directory (slash)"            "${readme}" "[the scripts again](${tree}/ci/)"
has "README: a test script"                  "${readme}" "](${gh}/linux/tests/a.sh)"
has "README: CHANGELOG.md is an extra, kept" "${readme}" "](CHANGELOG.md)"
has "README: VERSION is an extra, kept"      "${readme}" "](VERSION)"
has "README: an absolute link is kept"       "${readme}" "](https://example.com/docs/ci.md)"
has "README: mailto is kept"                 "${readme}" "](mailto:a@b.c)"
has "README: an anchor is kept"              "${readme}" "](#top)"
has "README: a reference definition, with a title" "${readme}" "[ref]: ${gh}/docs/ci.md \"a title\""
has "README: a reference definition that ships"    "${readme}" "[ref2]: docs/guide.md"
has "README: a fenced code block is not touched"   "${readme}" "[not a link of this file](docs/ci.md)"
has "guide: a link back to a page that ships" "${guide}" "](../README.md)"
has "guide: ci.md next to it is excluded"     "${guide}" "](${gh}/docs/ci.md)"
has "guide: releasing.md with an anchor"      "${guide}" "](${gh}/docs/releasing.md#how)"
has "guide: a test from docs/"                "${guide}" "](${gh}/linux/tests/a.sh)"
has "guide: a directory from docs/"           "${guide}" "](${tree}/linux/tests/)"
has "guide: an image that ships is kept"      "${guide}" "](img/x.png)"
hasnt "guide: no link to a page that is left out is relative" "${guide}" "](ci.md)"
[ "$(LC_ALL=C sort "${work}/changed" | paste -sd' ' -)" = "README.md docs/guide.md" ] && ok "the changed files are listed" || bad "the changed files: $(LC_ALL=C sort "${work}/changed" | paste -sd' ' -)"
# a file with nothing to change is not written
rm -rf "${work}/out"
echo '# plain' > "${fx}/docs/plain.md"; git add -A; git commit -q -m plain
run "${spec[@]}" || { echo "FAIL: the script failed (2)"; exit 1; }
[ ! -e "${work}/out/docs/plain.md" ] && ok "a page with no link to change is not written" || bad "docs/plain.md was written"

# a link to a file that exists nowhere is an error, and says which
rm -rf "${work}/out"
echo 'See [nothing](missing.md).' > "${fx}/docs/dead.md"; git add -A; git commit -q -m dead
if run "${spec[@]}"; then bad "a dead link was accepted"; elif grep -q 'docs/dead.md: the link missing.md names docs/missing.md' "${work}/err"; then ok "a dead link is reported and fails"; else bad "the error: $(cat "${work}/err")"; fi

# --- this repository: no relative link of the bundle is left dead ---------------------------------------------------------------------------
cd "${repo_root}"
spec_repo=(README.md LICENSE SECURITY.md docs examples linux windows ':(exclude)linux/tests' ':(exclude)windows/tests' ':(exclude)docs/ci.md' ':(exclude)docs/releasing.md')
rm -rf "${work}/out"
if run "${spec_repo[@]}"; then ok "this repository: every relative link of the bundle is in it or at GitHub ($(wc -l < "${work}/changed") files rewritten)"; else bad "this repository: $(cat "${work}/err")"; fi

echo "RESULT test=bundle-links rows=${rows} failed=${failed}"
[ "${failed}" -eq 0 ] || exit 1
echo "PASS (the links of the release bundle)"
