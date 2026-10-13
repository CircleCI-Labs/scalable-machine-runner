#!/usr/bin/env bash
# Stage the repository's Markdown as the Hugo content of the docs site (docs/ci.md, "Docs site").
#
#   site/stage.sh        writes site/content/ (generated, not tracked); then "hugo server" or "hugo --minify" in site/
#
# The Markdown sources are never changed. The pages are the files that site/nav.txt lists, and README.md,
# which becomes the home page. For every page this script
#   - maps the page-title and page-description front matter keys to title and description, and every other
#     page-* key to params (a page without front matter takes its first heading as the title),
#   - removes the first level-one heading, because the theme prints the title,
#   - adds weight and linkTitle from the order and the labels in nav.txt,
#   - rewrites the relative links: a link to another page of the site points to that page, and a link to
#     anything else in the repository (../examples/..., ../.circleci/...) becomes a GitHub blob or tree URL,
# and it writes the _index.md files of the sidebar groups and of the documentation root.
#
# Environment:
#   SITE_REPO_URL   the repository URL for the GitHub links (default: the GitHub link of the menu in hugo.yaml)
#   SITE_REF        the branch or tag of those links (default: main)
#   STAGE_LENIENT=1 report a page that nav.txt misses, or lists but does not find, as a warning, not an error
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(git -C "${here}" rev-parse --show-toplevel)
content="${here}/content"
ref="${SITE_REF:-main}"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

say() { printf 'stage: %s\n' "$*"; }
warn() { printf 'stage: warning: %s\n' "$*" >&2; }
die() { printf 'stage: error: %s\n' "$*" >&2; exit 1; }
# problem MESSAGE: an error, or a warning with STAGE_LENIENT=1
problem() { if [ "${STAGE_LENIENT:-0}" = 1 ]; then warn "$*"; else printf 'stage: error: %s\n' "$*" >&2; failed=1; fi; }
failed=0

# The repository URL of the GitHub links: the GitHub link of the menu in hugo.yaml.
repo="${SITE_REPO_URL:-$(sed -n 's|^[[:space:]]*url:[[:space:]]*\(https://github.com/[^[:space:]]*\)[[:space:]]*$|\1|p' "${here}/hugo.yaml" | head -n 1)}"
repo="${repo%/}"
[ -n "${repo}" ] || die "no GitHub URL in the menu of hugo.yaml: set SITE_REPO_URL"

# nav.txt -> nav.tsv, fields separated by "|": kind (G group, P page), path or slug, label or title,
# destination (without extension), weight, group slug
awk -F'|' '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  /^[ \t]*(#|$)/ { next }
  /^==/ {
    title = trim(substr($0, 3)); group = ""
    if (title != "") {
      group = tolower(title); gsub(/[^a-z0-9]+/, "-", group); gsub(/^-|-$/, "", group)
      top++; printf "G|%s|%s|docs/%s|%d|\n", group, title, group, top * 10
      pages = 0
    }
    next
  }
  {
    path = trim($1); label = trim($2); stem = path; sub(/^.*\//, "", stem); sub(/\.md$/, "", stem); stem = tolower(stem)
    if (group == "") { top++; w = top * 10; dest = "docs/" stem } else { pages++; w = pages * 10; dest = "docs/" group "/" stem }
    printf "P|%s|%s|%s|%d|%s\n", path, label, dest, w, group
  }
' "${here}/nav.txt" > "${tmp}/nav.tsv"

# Every listed page must exist, and every docs page must be listed.
while IFS='|' read -r kind path _; do
  [ "${kind}" = P ] || continue
  [ -f "${root}/${path}" ] || problem "nav.txt lists ${path}, which does not exist"
done < "${tmp}/nav.tsv"
for f in "${root}"/docs/*.md; do
  rel="docs/${f##*/}"
  awk -F'|' -v p="${rel}" '$1 == "P" && $2 == p { found = 1 } END { exit !found }' "${tmp}/nav.tsv" \
    || problem "${rel} is not listed in site/nav.txt, so it would be missing from the site"
done
[ "${failed}" = 0 ] || die "fix site/nav.txt (see its header)"

# Where every page goes (README.md is the home page), and every file and directory the links may point to.
{ printf 'README.md\t_index\n'; awk -F'|' '$1 == "P" { printf "%s\t%s\n", $2, $4 }' "${tmp}/nav.tsv"; } > "${tmp}/map.tsv"
git -C "${root}" ls-files | awk '
  { print "F\t" $0; n = split($0, a, "/"); d = ""; for (i = 1; i < n; i++) { d = d (i > 1 ? "/" : "") a[i]; seen[d] = 1 } }
  END { for (d in seen) print "D\t" d }' > "${tmp}/paths.tsv"

# The transformation of one page: stage MARKDOWN-FILE DESTINATION WEIGHT LABEL
transform() {
  awk -v src="$1" -v dest="$2" -v weight="$3" -v label="$4" -v repo="${repo}" -v ref="${ref}" \
    -v mapfile="${tmp}/map.tsv" -v pathsfile="${tmp}/paths.tsv" -v manifest="${tmp}/pages.tsv" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function unquote(s) { if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2); return s }
    function yq(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
    function dirname(p) { if (p !~ /\//) return ""; sub(/\/[^\/]*$/, "", p); return p }
    function normalize(path,   n, parts, out, i, k, s) {
      n = split(path, parts, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == "..") { if (k == 0) return "../"; k--; continue }
        out[++k] = parts[i]
      }
      s = ""; for (i = 1; i <= k; i++) s = s (i > 1 ? "/" : "") out[i]
      return s
    }
    # A link target: a page of the site -> its place in the site, anything else in the repository -> GitHub.
    function rewrite(url,   frag, i, rp, base) {
      if (url == "" || url ~ /^[A-Za-z][A-Za-z0-9+.-]*:/ || url ~ /^[#\/<]/) return url
      frag = ""; i = index(url, "#")
      if (i) { frag = substr(url, i); url = substr(url, 1, i - 1) }
      base = dirname(src)
      rp = normalize((base == "" ? "" : base "/") url)
      if (rp == "../") { print "stage: warning: " src ": link leaves the repository: " url > "/dev/stderr"; return url frag }
      if (rp == "README.md") return "/" frag
      if (rp in pages) return "/" pages[rp] ".md" frag
      if (rp == "") return repo "/tree/" ref
      if (rp in isdir) return repo "/tree/" ref "/" rp frag
      if (!(rp in isfile)) print "stage: warning: " src ": link to a file that git does not track: " url > "/dev/stderr"
      return repo "/blob/" ref "/" rp frag
    }
    function fixlinks(s,   out, pre, inner, dst, rest, sp, after) {
      out = ""
      while (match(s, /\]\([^)]*\)/)) {
        pre = substr(s, 1, RSTART - 1); inner = substr(s, RSTART + 2, RLENGTH - 3); after = substr(s, RSTART + RLENGTH)
        sp = index(inner, " ")
        if (sp) { dst = substr(inner, 1, sp - 1); rest = substr(inner, sp) } else { dst = inner; rest = "" }
        out = out pre "](" rewrite(dst) rest ")"
        s = after
      }
      return out s
    }
    # A line outside code fences: links outside of code spans only.
    function fixline(s,   n, parts, i, out) {
      if (index(s, "](") == 0) return s
      n = split(s, parts, "`"); out = ""
      for (i = 1; i <= n; i++) out = out (i > 1 ? "`" : "") (i % 2 == 1 ? fixlinks(parts[i]) : parts[i])
      return out
    }
    BEGIN {
      while ((getline line < mapfile) > 0) { split(line, a, "\t"); pages[a[1]] = a[2] }
      while ((getline line < pathsfile) > 0) { split(line, a, "\t"); if (a[1] == "F") isfile[a[2]] = 1; else isdir[a[2]] = 1 }
      lines = 0; infm = 0; infence = 0; h1done = 0; skipblank = 0; params = ""; extra = ""
    }
    NR == 1 && $0 == "---" { infm = 1; next }
    infm {
      if ($0 == "---") { infm = 0; next }
      if (match($0, /^[A-Za-z][A-Za-z0-9_-]*:/)) {
        key = substr($0, 1, RLENGTH - 1); val = trim(substr($0, RLENGTH + 1))
        if (key == "page-title") title = unquote(val)
        else if (key == "page-description") description = unquote(val)
        else if (key ~ /^page-/) params = params "  " substr(key, 6) ": " yq(unquote(val)) "\n"
        else extra = extra $0 "\n"
      } else extra = extra $0 "\n"
      next
    }
    {
      if (skipblank) { skipblank = 0; if ($0 ~ /^[ \t]*$/) next }
      if (lines == 0 && $0 ~ /^[ \t]*$/) next
      if (match($0, /^ *(```+|~~~+)/)) {
        mk = $0; sub(/^ */, "", mk); ch = substr(mk, 1, 1); len = 0
        while (substr(mk, len + 1, 1) == ch) len++
        if (!infence) { infence = 1; fch = ch; flen = len }
        else if (ch == fch && len >= flen && mk ~ /^(`+|~+)[ \t]*$/) infence = 0
        body[++lines] = $0; next
      }
      if (infence) { body[++lines] = $0; next }
      if (!h1done && $0 ~ /^# /) {
        h1done = 1; skipblank = 1; h1 = substr($0, 3); gsub(/`/, "", h1); next
      }
      body[++lines] = fixline($0)
    }
    END {
      if (title == "") title = h1
      if (title == "") print "stage: warning: " src ": no title" > "/dev/stderr"
      print "---"
      print "title: " yq(title)
      if (label != "") print "linkTitle: " yq(label)
      if (description != "") print "description: " yq(description)
      if (weight != "") print "weight: " weight
      if (params != "") { print "params:"; printf "%s", params }
      printf "%s", extra
      print "---"; print ""
      for (i = 1; i <= lines; i++) print body[i]
      printf "%s\t%s\t%s\n", dest, (label != "" ? label : title), description >> manifest
    }
  ' "${root}/$1"
}

rm -rf "${content}"
mkdir -p "${content}/docs"
: > "${tmp}/pages.tsv"

transform README.md _index "" "" > "${content}/_index.md"
while IFS='|' read -r kind path label dest weight _; do
  [ "${kind}" = P ] || continue
  mkdir -p "${content}/$(dirname "${dest}")"
  transform "${path}" "${dest}" "${weight}" "${label}" > "${content}/${dest}.md"
done < "${tmp}/nav.tsv"

# The index pages: one for each group and one for the documentation root, each with a list of its pages.
# list GROUP: the pages of a group (GROUP empty: the top-level pages), as Markdown bullets.
list() {
  awk -F'|' -v g="$1" -v pagesfile="${tmp}/pages.tsv" '
    BEGIN { while ((getline line < pagesfile) > 0) { split(line, a, "\t"); title[a[1]] = a[2]; desc[a[1]] = a[3] } }
    $1 == "P" && $6 == g {
      printf "- [%s](/%s.md)", ($3 != "" ? $3 : title[$4]), $4
      if (desc[$4] != "") printf ": %s", desc[$4]
      printf "\n"
    }' "${tmp}/nav.tsv"
}
{
  printf -- '---\ntitle: Documentation\n---\n\n'
  while IFS='|' read -r kind slug title _; do
    case "${kind}" in
      G) printf '## %s\n\n' "${title}"; list "${slug}"; printf '\n' ;;
    esac
  done < "${tmp}/nav.tsv"
  top=$(list "")
  if [ -n "${top}" ]; then printf '## More\n\n%s\n' "${top}"; fi
} > "${content}/docs/_index.md"
while IFS='|' read -r kind slug title dest weight _; do
  [ "${kind}" = G ] || continue
  mkdir -p "${content}/${dest}"
  printf -- '---\ntitle: "%s"\nweight: %s\n---\n\n' "${title}" "${weight}" > "${content}/${dest}/_index.md"
  list "${slug}" >> "${content}/${dest}/_index.md"
done < "${tmp}/nav.tsv"

say "staged $(find "${content}" -name '*.md' | wc -l) Markdown files in ${content#"${root}"/} (repository ${repo}, ref ${ref})"
