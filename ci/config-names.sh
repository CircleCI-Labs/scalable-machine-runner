#!/bin/sh
# config-names.sh: keep the names of the Swarm configs of the stack files in step with their content.
#
# A Swarm config is immutable: "docker stack deploy" cannot change the content of a config that exists, and a service keeps the old
# file when the name stays. So every config of the stack files that carries a file of this repository (the entrypoint, the
# distributor scripts) is named after its content: name: machine-runner-swarm-<what>-<first 12 hex digits of the file's SHA-256>.
# A changed file gets a new name, "docker stack deploy" creates the new config and updates the services that use it, and an
# unchanged file keeps its name, so a redeploy changes nothing. Nobody decides when to bump a number.
#
#   ci/config-names.sh           check: exit 1 and say which name is stale (lint-stack, linux/tests/stack-config.sh and ci/release.sh run it)
#   ci/config-names.sh --write   rewrite the stale names in place (run it after changing one of these files)
#
# The file is hashed as it is in the checkout (.gitattributes keeps these files LF on every platform). POSIX sh: it runs in the
# Docker CLI image of the lint-stack job and on a developer's machine.
set -eu
mode=check
case ${1:-} in "") ;; --write) mode='write' ;; *) echo "usage: ci/config-names.sh [--write]" >&2; exit 2 ;; esac
root=$(cd "$(dirname "$0")/.." && pwd)
list=$(mktemp)
trap 'rm -f "$list"' EXIT
for stack in "$root"/linux/stack/*.yaml "$root"/windows/stack/*.yaml; do
  [ -f "$stack" ] || continue
  # lines like:   entrypoint: {name: machine-runner-swarm-entrypoint-0123456789ab, file: circleci-runner-entrypoint}
  grep -E 'name: machine-runner-swarm-[a-z0-9-]+-[0-9a-f]{12}, file: ' "$stack" > "$list.lines" || true
  while IFS= read -r line; do
    name=$(printf '%s\n' "$line" | sed -E 's/.*name: (machine-runner-swarm-[a-z0-9-]+-[0-9a-f]{12}), file: .*/\1/')
    file=$(printf '%s\n' "$line" | sed -E 's/.*, file: ([^ ,}]+).*/\1/')
    [ -f "$(dirname "$stack")/$file" ] || { echo "${stack#"$root"/}: $name: $file does not exist" >&2; exit 1; }
    echo "$name ${name%-*}-$(sha256sum "$(dirname "$stack")/$file" | cut -c1-12) ${stack#"$root"/} $file" >> "$list"
  done < "$list.lines"
  rm -f "$list.lines"
done
[ -s "$list" ] || { echo "no content-named config found in the stack files" >&2; exit 1; }
stale=0
while read -r name want stack file; do
  [ "$name" != "$want" ] || continue
  stale=$((stale + 1))
  if [ "$mode" = write ]; then
    sed -i "s/$name, file: /$want, file: /" "$root/$stack"
    echo "$stack: $name -> $want ($file changed)"
  else
    echo "$stack: config $name is stale for $file, it should be $want (run ci/config-names.sh --write)" >&2
  fi
done < "$list"
echo "config names: $(wc -l < "$list") checked, $stale stale"
[ "$mode" = write ] || [ "$stale" -eq 0 ]
