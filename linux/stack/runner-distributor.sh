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
#   MACHINE_RUNNER_SWARM_PROXY_VERSION               the token proxy of this repository's release v<version>. unreleased (the default of a
#                                                    checkout, ci/release.sh pins the default of a release bundle) means the latest published
#                                                    release of this repository, looked at again every check interval. Empty: no proxy
#   MACHINE_RUNNER_SWARM_PROXY_BASE_URL              where <tag>/machine-runner-swarm-proxy_linux_<arch> and <tag>/SHA256SUMS live (default:
#                                                    the GitHub releases of this repository, tag v<version>)
#   MACHINE_RUNNER_SWARM_PROXY_LATEST_URL            what unreleased asks for the latest release: JSON with its "tag_name" (default: the
#                                                    GitHub API of this repository, releases/latest)
#   MACHINE_RUNNER_SWARM_PROXY_SHA256                optional: acceptable proxy binary SHA-256 values, separated by commas
# It resolves the version, downloads the tarball when versions/<version> is missing or does not match its record, verifies the
# tarball SHA-256, extracts circleci-runner, computes the SHA-256 of the binary and records it in versions/<version>/SHA256, and
# moves the link current to versions/<version> with one atomic rename. Old versions stay (the last 3 that were active), so a
# rollback is a flip. A runner container resolves current once, when it starts, and verifies the binary against the record.
# The token proxy comes the same way into proxy/versions/<version>/bin (the binary of the release, verified against the SHA256SUMS of
# that release, and recorded in proxy/versions/<version>/SHA256), behind its own link proxy/current; the last 2 versions stay.
#
# With the argument --once it makes one check, installs no proxy, and exits 0 when the runner is installed and current points to it,
# otherwise 1. The entrypoint of a microVM class (MACHINE_RUNNER_SWARM_REQUIRE_MICROVM=true) runs it that way in the container itself,
# where nothing is shared with other jobs, so every job downloads and verifies its own runner (docs/microvm.md).
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
pver=${MACHINE_RUNNER_SWARM_PROXY_VERSION:-}
[ "$once" = false ] || pver=   # one check of the runner only
pbase=${MACHINE_RUNNER_SWARM_PROXY_BASE_URL:-https://github.com/CircleCI-Labs/scalable-machine-runner/releases/download}
pbase=${pbase%/}
platest=${MACHINE_RUNNER_SWARM_PROXY_LATEST_URL:-https://api.github.com/repos/CircleCI-Labs/scalable-machine-runner/releases/latest}
keep=3        # versions to keep: the last ones that were active
pkeep=2       # proxy versions to keep
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
asset=machine-runner-swarm-proxy_linux_$arch

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

phashes=$(printf '%s' "${MACHINE_RUNNER_SWARM_PROXY_SHA256:-}" | tr 'A-F,' 'a-f ')
for h in $phashes; do
  case $h in *[!0-9a-f]*) die "MACHINE_RUNNER_SWARM_PROXY_SHA256 holds a value that is not a SHA-256: $h" ;; esac
  [ ${#h} -eq 64 ] || die "MACHINE_RUNNER_SWARM_PROXY_SHA256 holds a value that is not a SHA-256: $h"
done
case $pver in
  '' | unreleased) ;;
  [0-9]*.[0-9]*.[0-9]*) case $pver in *[!0-9A-Za-z._-]*) die "invalid proxy version '$pver'" ;; esac ;;
  *) die "MACHINE_RUNNER_SWARM_PROXY_VERSION must be a release such as 0.3.0, got '$pver'" ;;
esac

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

# flip DIR VERSION WHAT: DIR/current -> versions/VERSION, atomically, and remember that it was active
flip() {
  if [ "$(readlink "$1/current" 2>/dev/null)" != "versions/$2" ]; then
    ln -s "versions/$2" "$1/.current.$$" && mv -T "$1/.current.$$" "$1/current"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $2" >> "$1/history"
    tail -n 200 "$1/history" > "$1/.history.$$" && mv "$1/.history.$$" "$1/history"
    rel=${1#"$root"}
    rel=${rel#/}
    log "[ ok ] ${rel:+$rel/}current -> versions/$2: $3 $2 linux/$arch"
  fi
}

# prune DIR KEEP WHAT: keep the last KEEP versions of DIR that were active, never the active one
prune() {
  active=$(readlink "$1/current" 2>/dev/null || true)
  keepers=$(awk -v n="$2" '{ a[NR] = $2 } END { for (i = NR; i >= 1; i--) if (!(a[i] in s)) { s[a[i]] = 1; print a[i]; if (++c == n) exit } }' "$1/history" 2>/dev/null || true)
  for d in "$1"/versions/*; do
    [ -d "$d" ] || continue
    old=${d##*/}
    [ "versions/$old" != "$active" ] || continue
    case " $(echo "$keepers" | tr '\n' ' ') " in *" $old "*) continue ;; esac
    log "removing $3 $old (only the last $2 active versions are kept)"
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
  flip "$root" "$ver" circleci-runner
  prune "$root" "$keep" circleci-runner
}

# proxy_installed_ok VERSION [HASHES]: proxy/versions/VERSION is complete and its binary matches its record (and, with HASHES, one of them)
proxy_installed_ok() {
  d=$root/proxy/versions/$1
  [ -x "$d/bin/machine-runner-swarm-proxy" ] && [ -f "$d/SHA256" ] || return 1
  grep -qx '[0-9a-f]\{64\}  bin/machine-runner-swarm-proxy' "$d/SHA256" || return 1
  (cd "$d" && sha256sum -c SHA256 >/dev/null 2>&1) || return 1
  [ -z "${2:-}" ] && return 0
  for h in $2; do [ "$(cut -d' ' -f1 "$d/SHA256")" = "$h" ] && return 0; done
  return 1
}

# install_proxy VERSION: download the release's SHA256SUMS and the binary, check the binary against the line of SHA256SUMS (and against
# MACHINE_RUNNER_SWARM_PROXY_SHA256 when it is set), record it, move it into place
install_proxy() {
  v=$1
  mkdir -p "$root/proxy/versions"
  tmp=$(mktemp -d "$root/proxy/.tmp.XXXXXX")   # same filesystem as proxy/versions/: the final mv is atomic
  mkdir -m 0755 "$tmp/bin"
  log "downloading the token proxy $v linux/$arch from $pbase/v$v"
  fetch "$pbase/v$v/SHA256SUMS" "$tmp/SHA256SUMS" || { log "cannot download $pbase/v$v/SHA256SUMS" >&2; rm -rf "$tmp"; return 1; }
  psum=$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1; exit }' "$tmp/SHA256SUMS" | tr 'A-F' 'a-f')
  [ -n "$psum" ] || { log "SHA256SUMS of v$v lists no $asset" >&2; rm -rf "$tmp"; return 1; }
  if [ -n "$phashes" ]; then
    case " $phashes " in
      *" $psum "*) ;;
      *) log "SHA256SUMS of v$v lists $psum for $asset, which MACHINE_RUNNER_SWARM_PROXY_SHA256 does not allow: refusing to install" >&2; rm -rf "$tmp"; return 1 ;;
    esac
  fi
  fetch "$pbase/v$v/$asset" "$tmp/bin/machine-runner-swarm-proxy" || { log "cannot download $pbase/v$v/$asset" >&2; rm -rf "$tmp"; return 1; }
  got=$(sha256sum "$tmp/bin/machine-runner-swarm-proxy" | cut -d' ' -f1)
  [ "$got" = "$psum" ] || { log "SHA-256 mismatch for $asset v$v: got $got, SHA256SUMS says $psum: refusing to install" >&2; rm -rf "$tmp"; return 1; }
  chmod 0755 "$tmp/bin/machine-runner-swarm-proxy"
  "$tmp/bin/machine-runner-swarm-proxy" -version 2>&1 | grep -qF " $v" ||
    { log "the downloaded proxy does not report version $v: refusing to install" >&2; rm -rf "$tmp"; return 1; }
  rm "$tmp/SHA256SUMS"
  (cd "$tmp" && sha256sum bin/machine-runner-swarm-proxy > SHA256) && echo "$v" > "$tmp/VERSION"
  chown -R 0:0 "$tmp" && chmod 0755 "$tmp" "$tmp/bin"
  rm -rf "$root/proxy/versions/$v"
  mv "$tmp" "$root/proxy/versions/$v"
  log "installed the token proxy $v: binary SHA-256 $(cut -d' ' -f1 "$root/proxy/versions/$v/SHA256")"
}

# proxy_latest: sets $pwant to the version of the latest published release of this repository (what unreleased means)
proxy_latest() {
  pwant=
  if ! fetch "$platest" "$work/latest.json"; then
    log "error: the token proxy is not installed: MACHINE_RUNNER_SWARM_PROXY_VERSION is unreleased (a checkout of this repository), which means its latest published release, and $platest returns none. Either this repository has published no release yet, or GitHub is not reachable. Use the bundle of a release, or set MACHINE_RUNNER_SWARM_PROXY_VERSION to a release such as 0.3.0" >&2
    return 1
  fi
  tag=$(grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$work/latest.json" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
  case $tag in
    v[0-9]*.[0-9]*.[0-9]*) case $tag in *[!0-9A-Za-z._-]*) tag= ;; esac ;;
    *) tag= ;;
  esac
  [ -n "$tag" ] || { log "error: $platest names no release tag of the form v0.3.0: the token proxy is not installed" >&2; return 1; }
  pwant=${tag#v}
}

# proxy_cycle: keep the token proxy of MACHINE_RUNNER_SWARM_PROXY_VERSION. Non-zero: this check failed (the runner is not affected).
proxy_cycle() {
  pwant=$pver
  case $pver in
    '') return 0 ;;
    unreleased) proxy_latest || return 1 ;;
  esac
  if proxy_installed_ok "$pwant" "$phashes"; then
    log "the token proxy $pwant is installed already"
  else
    install_proxy "$pwant" || return 1
  fi
  flip "$root/proxy" "$pwant" "the token proxy"
  prune "$root/proxy" "$pkeep" "the token proxy"
}

mkdir -p "$root"
rm -rf "$root"/.work.* "$root"/.tmp.* "$root"/proxy/.tmp.*   # what a stopped run left
case $kind in
  exact) log "version $want (an exact pin: it never changes by itself, and the manifest is asked only when it is not installed), check every ${interval}s, from $base" ;;
  minor | major) log "version $want (floating: the newest $want.x of the manifest), check every ${interval}s, from $base" ;;
  current) log "version current (floating: CircleCI's current, within major $major), check every ${interval}s, from $base" ;;
esac
case $pver in
  '') [ "$once" = true ] || log "no token proxy is installed: MACHINE_RUNNER_SWARM_PROXY_VERSION is empty" ;;
  unreleased) log "token proxy: the latest published release of this repository (unreleased), looked at every ${interval}s: $platest" ;;
  *) log "token proxy $pver from $pbase" ;;
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
  if ! proxy_cycle; then   # a failure here does not touch the runner
    log "the token proxy is not installed or not up to date; the next check is in ${retry}s" >&2
    wait_for=$retry
  fi
  rm -rf "$work"
  sleep "$wait_for" &
  wait $!
done
