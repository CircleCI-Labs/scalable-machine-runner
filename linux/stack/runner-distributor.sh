#!/bin/sh
# runner-distributor.sh: keep circleci-runner on this node. It is the command of the runner-distributor service (stack/runners.yaml),
# a global service from the stock alpine image, and arrives as a Swarm config. The service gives it:
#   /opt/machine-runner-swarm                        the per-node volume runner-bin (read-write here, read-only in the runner services)
#   MACHINE_RUNNER_SWARM_RUNNER_VERSION              current (default: CircleCI's manifest) or X.Y.Z (pinned)
#   MACHINE_RUNNER_SWARM_RUNNER_MAJOR                the major version that current may adopt (default 3)
#   MACHINE_RUNNER_SWARM_CHECK_INTERVAL              how often to look again (default 24h; seconds, or a number with s, m, h or d)
#   MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL           where manifest.json and <version>/circleci-runner_linux_<arch>.tar.gz live
#   MACHINE_RUNNER_SWARM_RUNNER_SHA256               optional: acceptable tarball SHA-256 values, separated by commas (every
#                                                    architecture of the fleet), instead of the hash of the manifest
#   MACHINE_RUNNER_SWARM_PROXY_VERSION               the token proxy of this repository's release v<version>; unreleased (a checkout) or empty:
#                                                    no proxy is installed. ci/release.sh pins the default of the stack file to the release
#   MACHINE_RUNNER_SWARM_PROXY_BASE_URL              where <tag>/machine-runner-swarm-proxy_linux_<arch> and <tag>/SHA256SUMS live (default:
#                                                    the GitHub releases of this repository, tag v<version>)
#   MACHINE_RUNNER_SWARM_PROXY_SHA256                optional: acceptable proxy binary SHA-256 values, separated by commas
# It resolves the version, downloads the tarball when versions/<version> is missing or does not match its record, verifies the
# tarball SHA-256, extracts circleci-runner, computes the SHA-256 of the binary and records it in versions/<version>/SHA256, and
# moves the link current to versions/<version> with one atomic rename. Old versions stay (the last 3 that were active), so a
# rollback is a flip. A runner container resolves current once, when it starts, and verifies the binary against the record.
# The token proxy comes the same way into proxy/versions/<version>/bin (the binary of the release, verified against the SHA256SUMS of
# that release, and recorded in proxy/versions/<version>/SHA256), behind its own link proxy/current; the last 2 versions stay.
# shellcheck disable=SC2154  # the MACHINE_RUNNER_SWARM_* variables come from the service
set -eu

root=/opt/machine-runner-swarm
want=${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-current}
major=${MACHINE_RUNNER_SWARM_RUNNER_MAJOR:-3}
interval=${MACHINE_RUNNER_SWARM_CHECK_INTERVAL:-24h}
base=${MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL:-https://circleci-binary-releases.s3.amazonaws.com/circleci-runner}
base=${base%/}
pver=${MACHINE_RUNNER_SWARM_PROXY_VERSION:-}
pbase=${MACHINE_RUNNER_SWARM_PROXY_BASE_URL:-https://github.com/CircleCI-Labs/scalable-machine-runner/releases/download}
pbase=${pbase%/}
keep=3        # versions to keep: the last ones that were active
pkeep=2       # proxy versions to keep
retry=300     # seconds until the next try after a failed check

log() { echo "runner-distributor: $*"; }
die() { log "error: $*" >&2; exit 1; }

case $(uname -m) in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) die "unsupported architecture $(uname -m): amd64 and arm64 only" ;;
esac
tarball=circleci-runner_linux_$arch.tar.gz
asset=machine-runner-swarm-proxy_linux_$arch

case $want in
  current) ;;
  [0-9]*.[0-9]*.[0-9]*) case $want in *[!0-9A-Za-z._-]*) die "invalid version '$want'" ;; esac ;;
  *) die "MACHINE_RUNNER_SWARM_RUNNER_VERSION must be current or a version such as 3.1.12, got '$want'" ;;
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

fetch() { # URL FILE: three tries
  local_try=1
  while :; do
    wget -q -T 60 -O "$2" "$1" && return 0
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

# resolve: sets $ver and $accept (the tarball hashes to accept; empty: any already installed copy is fine)
resolve() {
  accept=$hashes
  if [ "$want" != current ]; then
    ver=$want
    [ -z "$hashes" ] || return 0
    if installed_ok "$ver"; then return 0; fi   # a version that is installed already needs no manifest, so a rollback works offline
  fi
  fetch "$base/manifest.json" "$work/manifest.json" || { log "cannot download $base/manifest.json" >&2; return 1; }
  flatten "$work/manifest.json" > "$work/manifest.flat"
  if [ "$want" = current ]; then
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
  else
    [ -n "$accept" ] || accept=$(sha_of "$ver")
    [ -n "$accept" ] || { log "the manifest has no linux/$arch build for $ver" >&2; return 1; }
  fi
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
  want=$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1; exit }' "$tmp/SHA256SUMS" | tr 'A-F' 'a-f')
  [ -n "$want" ] || { log "SHA256SUMS of v$v lists no $asset" >&2; rm -rf "$tmp"; return 1; }
  if [ -n "$phashes" ]; then
    case " $phashes " in
      *" $want "*) ;;
      *) log "SHA256SUMS of v$v lists $want for $asset, which MACHINE_RUNNER_SWARM_PROXY_SHA256 does not allow: refusing to install" >&2; rm -rf "$tmp"; return 1 ;;
    esac
  fi
  fetch "$pbase/v$v/$asset" "$tmp/bin/machine-runner-swarm-proxy" || { log "cannot download $pbase/v$v/$asset" >&2; rm -rf "$tmp"; return 1; }
  got=$(sha256sum "$tmp/bin/machine-runner-swarm-proxy" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { log "SHA-256 mismatch for $asset v$v: got $got, SHA256SUMS says $want: refusing to install" >&2; rm -rf "$tmp"; return 1; }
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

# proxy_cycle: keep the token proxy of MACHINE_RUNNER_SWARM_PROXY_VERSION. Non-zero: this check failed (the runner is not affected).
proxy_cycle() {
  case $pver in '' | unreleased) return 0 ;; esac
  if proxy_installed_ok "$pver" "$phashes"; then
    log "the token proxy $pver is installed already"
  else
    install_proxy "$pver" || return 1
  fi
  flip "$root/proxy" "$pver" "the token proxy"
  prune "$root/proxy" "$pkeep" "the token proxy"
}

mkdir -p "$root"
rm -rf "$root"/.work.* "$root"/.tmp.* "$root"/proxy/.tmp.*   # what a stopped run left
log "version $want (major $major), check every ${interval}s, from $base"
case $pver in
  '' | unreleased) log "no token proxy is installed: MACHINE_RUNNER_SWARM_PROXY_VERSION is '${pver:-empty}' (a release of this repository, such as 0.3.0)" ;;
  *) log "token proxy $pver from $pbase" ;;
esac
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
