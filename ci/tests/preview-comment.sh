#!/usr/bin/env bash
# site/preview-comment.sh test: against a fake `curl` that answers like the GitHub API. Checks that nothing happens without
# the token or a pull request, that the first run creates ONE comment, that a later run updates it, that a failed update
# falls back to a new comment, that a failed call never fails the job, and that the token reaches curl only through its
# standard input and never the output. Needs only bash and jq.
#
# Usage: ci/tests/preview-comment.sh
set -euo pipefail
script=$(cd "$(dirname "$0")/../.." && pwd)/site/preview-comment.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
sentinel=SENTINEL-TOKEN-0123456789abcdef

# The fake curl: log "METHOD URL" and the body, answer from $FAKE_GET (comments list) or with an id, fail when FAKE_FAIL names the method.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET data=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    --request) method=${args[i + 1]} ;;
    --data) data=${args[i + 1]#@} ;;
  esac
done
url=${args[${#args[@]} - 1]}
config=$(cat)   # the configuration of the token arrives on stdin
case $config in *"Authorization: Bearer $EXPECT_TOKEN"*) auth=token ;; *) auth=none ;; esac
echo "$method $url auth=$auth" >> "$FAKE_LOG"
for a in "${args[@]}"; do case $a in *"$EXPECT_TOKEN"*) echo "TOKEN ON THE COMMAND LINE" >> "$FAKE_LOG" ;; esac; done
[ -z "$data" ] || cp "$data" "$FAKE_LOG.body.$method"
if [ "${FAKE_FAIL:-}" = "$method" ]; then echo "curl: (22) The requested URL returned error: 403" >&2; exit 22; fi
case $method in
  GET) case $url in *page=1) cat "$FAKE_GET" ;; *) echo '[]' ;; esac ;;
  *) echo '{"id": 99}' ;;
esac
EOF
chmod +x "$tmp/bin/curl"

export PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" FAKE_GET="$tmp/comments.json" EXPECT_TOKEN=$sentinel
export CIRCLE_PROJECT_USERNAME=o CIRCLE_PROJECT_REPONAME=r CIRCLE_SHA1=0123456789abcdef0123456789abcdef01234567
export CIRCLE_BUILD_URL=https://circleci.com/gh/o/r/42 CIRCLE_WORKFLOW_JOB_ID=3df8fe81-1066-4a7b-9843-bad46ff42b65
export GITHUB_API_URL=https://api.example.invalid
pr=https://github.com/o/r/pull/12

failed=0
rows=0
# run NAME WANT_EXIT WANT_LOG TOKEN PR  (the log is "METHOD path" lines, in order)
run() {
  local name=$1 want_rc=$2 want_log=$3 token=$4 prurl=$5 rc=0 got
  rows=$((rows + 1))
  : > "$FAKE_LOG"; rm -f "$FAKE_LOG".body.*
  GITHUB_PR_COMMENT_TOKEN=$token CIRCLE_PULL_REQUEST=$prurl "$script" > "$tmp/out" 2>&1 || rc=$?
  got=$(sed -e "s|^\([A-Z]*\) $GITHUB_API_URL|\1 |" -e 's| auth=token$||' "$FAKE_LOG" | grep -v '^$' || true)
  if [ "$rc" != "$want_rc" ] || [ "$got" != "$want_log" ]; then
    echo "FAIL ${name}: exit ${rc} (want ${want_rc}); calls:"; echo "$got"; echo "want:"; echo "$want_log"; cat "$tmp/out"; failed=$((failed + 1))
  elif grep -q "$sentinel" "$tmp/out" "$FAKE_LOG"; then
    echo "FAIL ${name}: the token reached the output or a command line"; failed=$((failed + 1))
  elif grep -q 'auth=none' "$FAKE_LOG"; then
    echo "FAIL ${name}: a call went out without the token on stdin"; failed=$((failed + 1))
  else
    echo "ok   ${name}"
  fi
}
list='GET /repos/o/r/issues/12/comments?per_page=100&page=1'
post='POST /repos/o/r/issues/12/comments'

echo '[]' > "$FAKE_GET"
run "no token: silent, no call" 0 "" "" "$pr"
[ ! -s "$tmp/out" ] || { echo "FAIL no token: the script printed something"; failed=$((failed + 1)); }
run "a build with no pull request" 0 "" "$sentinel" ""
run "not a pull request address" 0 "" "$sentinel" "https://example.com/o/r/pull/12"
run "no comment yet: one is posted" 0 "$list
$post" "$sentinel" "$pr"
body=$(jq -r .body "$FAKE_LOG.body.POST")
rows=$((rows + 1))
if grep -qF '<!-- machine-runner-swarm-docs-preview -->' <<< "$body" \
  && grep -qF 'https://output.circle-artifacts.com/output/job/3df8fe81-1066-4a7b-9843-bad46ff42b65/artifacts/0/docs-site-preview/index.html' <<< "$body" \
  && grep -qF '0123456' <<< "$body"; then
  echo "ok   the comment has the marker, the address and the commit"
else
  echo "FAIL the comment body: $body"; failed=$((failed + 1))
fi

# the address comes from the job that built the preview (docs-site-comment is a job of its own)
echo '[]' > "$FAKE_GET"
mkdir "$tmp/preview"
echo "https://output.circle-artifacts.com/output/job/aaaa/artifacts/0/docs-site-preview/index.html" > "$tmp/preview/preview-url.txt"
echo "https://circleci.com/gh/o/r/41" > "$tmp/preview/job-url.txt"
PREVIEW_DIR="$tmp/preview" run "the address of the build job is the one in the comment" 0 "$list
$post" "$sentinel" "$pr"
body=$(jq -r .body "$FAKE_LOG.body.POST")
rows=$((rows + 1))
if grep -qF 'job/aaaa/artifacts/0/docs-site-preview/index.html' <<< "$body" && grep -qF 'https://circleci.com/gh/o/r/41' <<< "$body" && ! grep -qF '3df8fe81' <<< "$body"; then
  echo "ok   the comment names the build job, not the comment job"
else
  echo "FAIL the comment body: $body"; failed=$((failed + 1))
fi
PREVIEW_DIR="$tmp/nonexistent" run "no preview address in the directory: skipped, nothing is posted" 0 "" "$sentinel" "$pr"

echo '[{"id": 7, "body": "an ordinary comment"}, {"id": 555, "body": "<!-- machine-runner-swarm-docs-preview -->\nold"}, {"id": 556, "body": "<!-- machine-runner-swarm-docs-preview -->\nolder"}]' > "$FAKE_GET"
run "a comment with the marker exists: it is updated, nothing is posted" 0 "$list
PATCH /repos/o/r/issues/comments/555" "$sentinel" "$pr"
FAKE_FAIL=PATCH run "the update fails: a new comment is posted" 0 "$list
PATCH /repos/o/r/issues/comments/555
$post" "$sentinel" "$pr"
unset FAKE_FAIL

echo '[{"id": 7, "body": "an ordinary comment"}]' > "$FAKE_GET"
FAKE_FAIL=GET run "the list fails: skipped, nothing is posted, the job is green" 0 "$list" "$sentinel" "$pr"
FAKE_FAIL=POST run "the post fails: skipped, the job is green" 0 "$list
$post" "$sentinel" "$pr"
unset FAKE_FAIL

echo "RESULT test=preview-comment rows=${rows} failed=${failed}"
if [ "$failed" -eq 0 ]; then echo "PASS (${rows} rows)"; else echo "FAIL: ${failed} row(s)"; exit 1; fi
