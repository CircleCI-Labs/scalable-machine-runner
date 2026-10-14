#!/bin/sh
# runner-distributor.sh: keep circleci-runner on this node. It is the command of the runner-distributor service (stack/runners.yaml),
# a global service from the stock alpine image, and arrives as a Swarm config. The service gives it:
#   /opt/machine-runner-swarm                        the per-node volume runner-bin (read-write here, read-only in the runner services)
#   MACHINE_RUNNER_SWARM_RUNNER_VERSION              what to run. An exact version such as 3.1.13 is a pin and never changes by itself (the
#                                                    default of the stack file: the newest version that this repository's CI tests). A
#                                                    floating value is resolved from CircleCI's manifest and looked at again every
#                                                    check interval: 3.1 (the newest 3.1.x), 3 (the newest 3.x.y) or current (CircleCI's current)
#   MACHINE_RUNNER_SWARM_RUNNER_MAJOR                the major version that current may adopt (default 3)
#   MACHINE_RUNNER_SWARM_CHECK_INTERVAL              how often to look again (default 24h; seconds, or a number with s, m, h or d). A floating
#                                                    version asks the manifest again; an exact pin only verifies its installed copy
#   MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL           where manifest.json and <version>/circleci-runner_linux_<arch>.tar.gz live
#   MACHINE_RUNNER_SWARM_RUNNER_SHA256               optional: acceptable tarball SHA-256 values, separated by commas (every
#                                                    architecture of the fleet), instead of the hash of the manifest
# It resolves the version, downloads the tarball when versions/<version> is missing or does not match its record, verifies the
# tarball SHA-256, extracts circleci-runner, computes the SHA-256 of the binary and records it in versions/<version>/SHA256, and
# moves the link current to versions/<version> with one atomic rename. Old versions stay (the last 3 that were active), so a
# rollback is a flip. A runner container resolves current once, when it starts, and verifies the binary against the record.
#
# With the argument --once it makes one check and exits 0 when the runner is installed and current points to it, otherwise 1.
# The entrypoint of a microVM class (MACHINE_RUNNER_SWARM_REQUIRE_MICROVM=true) runs it that way in the container itself, where nothing is shared with other jobs, so every job downloads and verifies its own runner (docs/microvm.md).
# shellcheck disable=SC2154  # the MACHINE_RUNNER_SWARM_* variables come from the service
set -eu

once=false
case ${1:-} in
  '') ;;
  --once) once=true ;;
  *) echo "runner-distributor: error: usage: runner-distributor.sh [--once]" >&2; exit 2 ;;
esac
root=/opt/machine-runner-swarm
want=${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-}
major=${MACHINE_RUNNER_SWARM_RUNNER_MAJOR:-3}
interval=${MACHINE_RUNNER_SWARM_CHECK_INTERVAL:-24h}
base=${MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL:-https://circleci-binary-releases.s3.amazonaws.com/circleci-runner}
base=${base%/}
keep=3        # versions to keep: the last ones that were active
retry=300     # seconds until the next try after a failed check

log() { echo "runner-distributor: $*"; }
die() { log "error: $*" >&2; exit 1; }

case $(uname -m) in   # the architectures of CircleCI's manifest for Linux
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  ppc64le) arch=ppc64le ;;
  s390x) arch=s390x ;;
  *) die "unsupported architecture $(uname -m): amd64, arm64, ppc64le and s390x only" ;;
esac
tarball=circleci-runner_linux_$arch.tar.gz

# What MACHINE_RUNNER_SWARM_RUNNER_VERSION asks for: exact (a pin), minor (3.1: the newest 3.1.x), major (3: the newest 3.x.y) or current.
[ -n "$want" ] || die "MACHINE_RUNNER_SWARM_RUNNER_VERSION is empty: set an exact version such as 3.1.13, a floating one (3.1, 3, current)"
case $want in
  current) kind=current ;;
  [0-9]*.[0-9]*.[0-9]*) kind=exact; case $want in *[!0-9A-Za-z._-]*) die "invalid version '$want'" ;; esac ;;
  [0-9]*.[0-9]*) kind=minor ;;
  [0-9]*) kind=major ;;
  *) die "MACHINE_RUNNER_SWARM_RUNNER_VERSION must be an exact version such as 3.1.13, or 3.1, 3 or current, got '$want'" ;;
esac
case $kind in
  minor) case $want in *[!0-9.]* | *..* | *.) die "MACHINE_RUNNER_SWARM_RUNNER_VERSION must be 3.1 (digits and one dot) or an exact version, got '$want'" ;; esac ;;
  major) case $want in *[!0-9]*) die "MACHINE_RUNNER_SWARM_RUNNER_VERSION must be 3 (digits only) or an exact version, got '$want'" ;; esac ;;
esac
case $major in '' | *[!0-9]*) die "MACHINE_RUNNER_SWARM_RUNNER_MAJOR must be a number, got '$major'" ;; esac
n=$interval
u=s
case $interval in *[smhd]) u=${interval#"${n%?}"}; n=${n%?} ;; esac
case $n in '' | *[!0-9]*) die "MACHINE_RUNNER_SWARM_CHECK_INTERVAL must be a number of seconds or a number with s, m, h or d, got '$interval'" ;; esac
case $u in m) n=$((n * 60)) ;; h) n=$((n * 3600)) ;; d) n=$((n * 86400)) ;; esac
interval=$n
[ "$interval" -ge 1 ] || die "MACHINE_RUNNER_SWARM_CHECK_INTERVAL must be at least 1 second"
[ "$retry" -le "$interval" ] || retry=$interval
hashes=$(printf '%s' "${MACHINE_RUNNER_SWARM_RUNNER_SHA256:-}" | tr 'A-F,' 'a-f ')
for h in $hashes; do
  case $h in *[!0-9a-f]*) die "MACHINE_RUNNER_SWARM_RUNNER_SHA256 holds a value that is not a SHA-256: $h" ;; esac
  [ ${#h} -eq 64 ] || die "MACHINE_RUNNER_SWARM_RUNNER_SHA256 holds a value that is not a SHA-256: $h"
done

fetch() { # URL FILE: three tries (wget, or curl in an image that has no wget)
  local_try=1
  while :; do
    if command -v wget >/dev/null 2>&1; then wget -q -T 60 -O "$2" "$1" && return 0; else curl -fsSL --connect-timeout 60 --max-time 900 -o "$2" "$1" && return 0; fi
    [ "$local_try" -lt 3 ] || return 1
    sleep "$local_try"
    local_try=$((local_try + 1))
  done
}

# Flatten manifest.json to lines "releases/<version>/<os>/<arch>/<field> <value>", whatever its layout.
flatten() {
  tr -s '[:space:]' ' ' < "$1" | awk '{
    s = $0
    while (match(s, /"([^"\\]|\\.)*"|[][{}:,]|[^][{}:," ]+/)) {
      t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      if (t == "{" || t == "[") { d++; k[d] = key; key = ""; hv = 0 }
      else if (t == "}" || t == "]") { d--; key = ""; hv = 0 }
      else if (t == ":") { key = last; hv = 1 }
      else if (t == ",") { key = ""; hv = 0 }
      else {
        v = t
        if (substr(v, 1, 1) == "\"") v = substr(v, 2, length(v) - 2)
        if (hv) { p = ""; for (i = 1; i <= d; i++) if (k[i] != "") p = p "/" k[i]; print substr(p "/" key, 2) " " v; hv = 0 }
        last = v
      }
    }
  }'
}

work=
cleanup() { [ -z "$work" ] || rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 0' TERM INT

# sha_of VERSION: the SHA-256 that the manifest lists for this node's tarball
sha_of() { sed -n "s|^releases/$1/linux/$arch/sha256 ||p" "$work/manifest.flat" | head -n 1; }

# installed_ok VERSION [HASHES]: versions/VERSION is complete, its binary matches its record, and (with HASHES) its tarball was one of them
installed_ok() {
  d=$root/versions/$1
  [ -x "$d/bin/circleci-runner" ] && [ -f "$d/SHA256" ] || return 1
  grep -qx '[0-9a-f]\{64\}  bin/circleci-runner' "$d/SHA256" || return 1
  (cd "$d" && sha256sum -c SHA256 >/dev/null 2>&1) || return 1
  [ -z "${2:-}" ] && return 0
  [ -f "$d/TARBALL" ] || return 1
  for h in $2; do [ "$(cut -d' ' -f1 "$d/TARBALL")" = "$h" ] && return 0; done
  return 1
}

# install_version VERSION HASHES: download into a temporary directory next to versions/, verify, record, move into place
install_version() {
  v=$1
  mkdir -p "$root/versions"
  tmp=$(mktemp -d "$root/.tmp.XXXXXX")   # same filesystem as versions/: the final mv is atomic
  mkdir -m 0755 "$tmp/bin"
  log "downloading circleci-runner $v linux/$arch"
  fetch "$base/$v/$tarball" "$tmp/$tarball" || { log "cannot download $base/$v/$tarball" >&2; rm -rf "$tmp"; return 1; }
  got=$(sha256sum "$tmp/$tarball" | cut -d' ' -f1)
  case " $2 " in
    *" $got "*) ;;
    *) log "SHA-256 mismatch for $tarball $v: got $got, wanted $2: refusing to install" >&2; rm -rf "$tmp"; return 1 ;;
  esac
  echo "$got  $tarball" > "$tmp/TARBALL"
  tar -xzf "$tmp/$tarball" -C "$tmp/bin" circleci-runner || { log "$tarball has no circleci-runner" >&2; rm -rf "$tmp"; return 1; }
  rm "$tmp/$tarball"
  chmod 0755 "$tmp/bin/circleci-runner"
  "$tmp/bin/circleci-runner" --version 2>&1 | grep -qF "version $v" ||
    { log "the downloaded binary does not report version $v: refusing to install" >&2; rm -rf "$tmp"; return 1; }
  (cd "$tmp" && sha256sum bin/circleci-runner > SHA256) && echo "$v" > "$tmp/VERSION"
  chown -R 0:0 "$tmp" && chmod 0755 "$tmp" "$tmp/bin"
  rm -rf "$root/versions/$v"
  mv "$tmp" "$root/versions/$v"
  log "installed circleci-runner $v: binary SHA-256 $(cut -d' ' -f1 "$root/versions/$v/SHA256")"
}

# flip VERSION: current -> versions/VERSION, atomically, and remember that it was active
flip() {
  if [ "$(readlink "$root/current" 2>/dev/null)" != "versions/$1" ]; then
    ln -s "versions/$1" "$root/.current.$$" && mv -T "$root/.current.$$" "$root/current"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >> "$root/history"
    tail -n 200 "$root/history" > "$root/.history.$$" && mv "$root/.history.$$" "$root/history"
    log "[ ok ] current -> versions/$1: circleci-runner $1 linux/$arch"
  fi
}

# prune: keep the last $keep versions that were active, never the active one
prune() {
  active=$(readlink "$root/current" 2>/dev/null || true)
  keepers=$(awk -v n="$keep" '{ a[NR] = $2 } END { for (i = NR; i >= 1; i--) if (!(a[i] in s)) { s[a[i]] = 1; print a[i]; if (++c == n) exit } }' "$root/history" 2>/dev/null || true)
  for d in "$root"/versions/*; do
    [ -d "$d" ] || continue
    old=${d##*/}
    [ "versions/$old" != "$active" ] || continue
    case " $(echo "$keepers" | tr '\n' ' ') " in *" $old "*) continue ;; esac
    log "removing circleci-runner $old (only the last $keep active versions are kept)"
    rm -rf "$d"
  done
}

# newest REGEX: the highest version of the manifest whose linux/$arch build has a SHA-256 and whose name matches the (basic) regular expression
newest() {
  sed -n "s|^releases/\($1\)/linux/$arch/sha256 .*|\1|p" "$work/manifest.flat" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

# resolve: sets $ver and $accept (the tarball hashes to accept; empty: any already installed copy is fine)
resolve() {
  accept=$hashes
  if [ "$kind" = exact ]; then   # a pin: a copy that is installed and verified needs no manifest, so a rollback works offline
    ver=$want
    [ -z "$hashes" ] || return 0
    if installed_ok "$ver"; then return 0; fi
  fi
  fetch "$base/manifest.json" "$work/manifest.json" || { log "cannot download $base/manifest.json" >&2; return 1; }
  flatten "$work/manifest.json" > "$work/manifest.flat"
  case $kind in
    exact)
      [ -n "$accept" ] || accept=$(sha_of "$ver")
      [ -n "$accept" ] || { log "the manifest has no linux/$arch build for $ver" >&2; return 1; }
      ;;
    minor | major)   # the newest release of a line: 3.1 is the newest 3.1.x, 3 the newest 3.x.y
      if [ "$kind" = minor ]; then line="$(echo "$want" | sed 's/\./\\./g')\.[0-9][0-9]*"; else line="$want\.[0-9][0-9]*\.[0-9][0-9]*"; fi
      ver=$(newest "$line")
      [ -n "$ver" ] || { log "the manifest has no linux/$arch release in $want.x" >&2; return 1; }
      [ -n "$accept" ] || accept=$(sha_of "$ver")
      ;;
    current)
      cur=$(sha_of current)
      [ -n "$cur" ] || { log "the manifest has no linux/$arch build for current" >&2; return 1; }
      ver=$(sed -n "s|^releases/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)/linux/$arch/sha256 $cur\$|\1|p" "$work/manifest.flat" |
        sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
      [ -n "$ver" ] || { log "current has SHA-256 $cur, which no versioned release of the manifest has: not adopting it" >&2; return 1; }
      if [ "${ver%%.*}" != "$major" ]; then
        log "current is $ver (major ${ver%%.*}), not $major: not adopting it (MACHINE_RUNNER_SWARM_RUNNER_MAJOR)"
        ver=
        return 0
      fi
      [ -n "$accept" ] || accept=$cur
      ;;
  esac
}

# cycle: one look at the manifest. Non-zero: this check failed.
cycle() {
  work=$(mktemp -d "$root/.work.XXXXXX")   # inside the volume: the root file system of the service is read-only
  ver=
  accept=
  resolve || return 1
  if [ -z "$ver" ]; then   # current is a major version we do not follow
    [ -L "$root/current" ] || { log "no runner is installed and current is not a major $major release" >&2; return 1; }
    return 0
  fi
  if installed_ok "$ver" "$accept"; then
    log "circleci-runner $ver is installed already"
  else
    install_version "$ver" "$accept" || return 1
  fi
  flip "$ver"
  prune
}

mkdir -p "$root"
rm -rf "$root"/.work.* "$root"/.tmp.*   # what a stopped run left
case $kind in
  exact) log "version $want (an exact pin: it never changes by itself, and the manifest is asked only when it is not installed), check every ${interval}s, from $base" ;;
  minor | major) log "version $want (floating: the newest $want.x of the manifest), check every ${interval}s, from $base" ;;
  current) log "version current (floating: CircleCI's current, within major $major), check every ${interval}s, from $base" ;;
esac
if [ "$once" = true ]; then
  cycle || exit 1
  exit 0
fi
while :; do
  wait_for=$interval
  if ! cycle; then
    [ -L "$root/current" ] || exit 1   # nothing to run yet: the restart policy tries again
    log "keeping circleci-runner $(readlink "$root/current"); the next check is in ${retry}s"
    wait_for=$retry
  fi
  rm -rf "$work"
  sleep "$wait_for" &
  wait $!
done
