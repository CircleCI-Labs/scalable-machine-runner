#!/usr/bin/env bash
# Check the links and the heading anchors of the built site (site/public) with lychee, offline (docs/ci.md, "Docs site").
#
#   site/stage.sh && (cd site && hugo --minify) && site/check.sh
#
# The site links to its own pages with the path of baseURL (/scalable-machine-runner/...), so the output is copied
# below that path of a temporary root, which lychee uses as the root of absolute links. External URLs are not fetched.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -f "${here}/public/index.html" ] || { echo "check: no site in ${here}/public: run hugo first" >&2; exit 1; }
command -v lychee > /dev/null || { echo "check: lychee is not installed" >&2; exit 1; }

# /scalable-machine-runner/ from baseURL: https://circleci-labs.github.io/scalable-machine-runner/
prefix=$(sed -n 's|^baseURL:[[:space:]]*https\{0,1\}://[^/[:space:]]*\(/.*\)$|\1|p' "${here}/hugo.yaml")
prefix="${prefix:-/}"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}${prefix}"
cp -R "${here}/public/." "${tmp}${prefix}"

# --index-files: a link to a directory is checked against its index.html, anchors included.
lychee --offline --no-progress --include-fragments=anchor-only --index-files index.html \
  --root-dir "${tmp}" "${tmp}${prefix}**/*.html"
