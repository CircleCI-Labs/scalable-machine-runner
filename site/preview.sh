#!/usr/bin/env bash
# Build a preview of the docs site that works from any address, for a pull request (docs/ci.md, "Docs site previews").
#
#   site/preview.sh build [DIR]   build the site into DIR (default site/public-preview) and check its links
#   site/preview.sh url           print the address of the preview among the artifacts of this CircleCI job
#
# The production build links to the pages with the path of baseURL (/machine-runner-swarm/...), so it works only there.
# CircleCI serves the artifacts of a job from https://output.circle-artifacts.com/output/job/<job id>/artifacts/<node>/<path>,
# and the job id changes with every run. So the preview is built with relative URLs (a link from docs/x/y.html to the home page
# is ../../index.html) and with uglyURLs, so that a page is a file (docs/ci.html), then every link is made to name a file: a
# server of artifacts does not serve the index.html of a directory, and the menu links to directories (./docs/security). Last,
# the integrity attributes are removed: CircleCI redirects script and style files to storage on another origin, and a browser
# refuses a script with an integrity hash from there. The staged Markdown links to GitHub at the commit (SITE_REF), so a file
# that the pull request adds has a link that works.
#
# The preview needs Hugo, Go (for the theme module) and lychee, like site/check.sh. It is not what GitHub Pages serves:
# `hugo --minify` of the production build is checked by the job as before, and docs-site-publish publishes that.
# Search and the Mermaid diagrams load files with their own script paths: they may not work from the artifacts.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# relink DIR: every relative href and src names a file, and no file carries an integrity hash.
relink() {
  local out=$1 tmp rel dir up
  tmp=$(mktemp -d)
  cat > "${tmp}/relink.awk" << 'EOF'
BEGIN {
  isdir[""] = 1
  while ((getline row < paths) > 0) { split(row, a, "\t"); if (a[1] == "F") isfile[a[2]] = 1; else isdir[a[2]] = 1 }
  close(paths)
}
function normalize(path,   n, parts, kept, i, k, s) {
  n = split(path, parts, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") { if (k == 0) return "../"; k--; continue }
    kept[++k] = parts[i]
  }
  s = ""; for (i = 1; i <= k; i++) s = s (i > 1 ? "/" : "") kept[i]
  return s
}
# A relative link: the file it names, whatever the address of the page. A directory becomes its index.html, a page without
# an extension its .html file.
function fix(url,   frag, i, path, index_file) {
  frag = ""; i = match(url, /[#?]/)
  if (i) { frag = substr(url, i); url = substr(url, 1, i - 1) }
  path = normalize((here == "." ? "" : here "/") url)
  if (path == "../") return url frag
  index_file = (path == "" ? "index.html" : path "/index.html")
  if ((path in isdir) && (index_file in isfile)) return url (url ~ /\/$/ ? "" : "/") "index.html" frag
  if (!(path in isfile) && ((path ".html") in isfile)) { sub(/\/+$/, "", url); return url ".html" frag }
  return url frag
}
{
  line = $0; out = ""
  while (match(line, /(href|src)=("[^"]*"|[^ >"']+)/)) {
    pre = substr(line, 1, RSTART - 1); m = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
    eq = index(m, "="); attr = substr(m, 1, eq); v = substr(m, eq + 1); q = ""
    if (substr(v, 1, 1) == "\"") { q = "\""; v = substr(v, 2, length(v) - 2) }
    if (v == "." || v == ".." || v ~ /^\.\.?\//) v = fix(v)
    out = out pre attr q v q
  }
  print out line
}
EOF
  ( cd "${out}" && { find . -type f | sed 's|^\./|F\t|'; find . -mindepth 1 -type d | sed 's|^\./|D\t|'; } ) > "${tmp}/paths.tsv"
  ( cd "${out}" && find . -name '*.html' -type f | sed 's|^\./||' ) | while IFS= read -r rel; do
    dir=$(dirname "${rel}")
    # The way up to the root from this page, for the url(/fonts/...) of the inline style (Hugo leaves those alone).
    if [ "${dir}" = . ]; then up=./; else up=$(printf '%s/' "${dir}" | sed -E 's|[^/]+/|../|g'); fi
    awk -v paths="${tmp}/paths.tsv" -v here="${dir}" -f "${tmp}/relink.awk" "${out}/${rel}" \
      | sed -E -e 's/ integrity=("[^"]*"|[^ >]+)//g' -e "s#url\\(/([^/)\"'])#url(${up}\\1#g" > "${tmp}/page.html"
    cat "${tmp}/page.html" > "${out}/${rel}"
  done
  rm -rf "${tmp}"
}

build() {
  local out=${1:-${here}/public-preview} rooted
  case "${out}" in /*) ;; *) out="${PWD}/${out}" ;; esac
  command -v hugo > /dev/null || { echo "preview: hugo is not installed" >&2; exit 1; }
  command -v lychee > /dev/null || { echo "preview: lychee is not installed" >&2; exit 1; }
  # The GitHub links of the pages point at this commit, not at main: a file that the pull request adds exists there.
  SITE_REF="${SITE_REF:-${CIRCLE_SHA1:-main}}" "${here}/stage.sh"
  rm -rf "${out}"
  (cd "${here}" && HUGO_RELATIVEURLS=true HUGO_UGLYURLS=true GOFLAGS=-mod=readonly \
    hugo --minify --panicOnWarning --baseURL / --destination "${out}")
  relink "${out}"
  # A link that begins with a slash would break at any address but the root.
  rooted=$(grep -rhoE --include='*.html' '(href|src)=("?)/[^/ >"][^ >"]*' "${out}" | head -n 5 || true)
  if [ -n "${rooted}" ]; then echo "preview: links that begin with a slash (they would break under the artifact path):" >&2; echo "${rooted}" >&2; exit 1; fi
  # Every relative link and anchor names a file of the preview: no directory index to rely on.
  lychee --offline --no-progress --include-fragments=anchor-only --index-files "" "${out}/**/*.html"
  echo "preview: built ${out}"
}

url() {
  : "${CIRCLE_WORKFLOW_JOB_ID:?preview: CIRCLE_WORKFLOW_JOB_ID is not set (run it in a CircleCI job)}"
  echo "https://output.circle-artifacts.com/output/job/${CIRCLE_WORKFLOW_JOB_ID}/artifacts/${CIRCLE_NODE_INDEX:-0}/docs-site-preview/index.html"
}

case "${1:-}" in
  build) build "${2:-}" ;;
  url) url ;;
  *) echo "usage: site/preview.sh build [DIR] | url" >&2; exit 2 ;;
esac
