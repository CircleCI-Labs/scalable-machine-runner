#!/bin/sh
# proxy-entrypoint.sh: start the token proxy from the per-node volume that the runner-distributor of this node fills. The stack
# delivers it as a Swarm config (mode 0444 at /proxy-entrypoint.sh) and runs it with sh in a stock alpine image, as uid 65534.
#
# The volume runner-bin is mounted read-only at /opt/machine-runner-swarm: proxy/current is a link to versions/<version>, and
# versions/<version>/SHA256 records the SHA-256 of bin/machine-runner-swarm-proxy. This script waits up to
# MACHINE_RUNNER_SWARM_PROXY_WAIT seconds (default 120) for the link, resolves it ONCE, exits 1 unless the binary matches its record
# (the proxy holds every class token, so a changed binary must not start), and then runs it with the arguments of the service. A failure
# is retried by Swarm after the restart delay of the service.
set -eu

root=/opt/machine-runner-swarm/proxy
die() { echo "proxy-entrypoint: error: $*" >&2; exit 1; }

total=${MACHINE_RUNNER_SWARM_PROXY_WAIT:-120}
case $total in '' | *[!0-9]*) die "MACHINE_RUNNER_SWARM_PROXY_WAIT must be a number of seconds, got '$total'" ;; esac
left=$total
while [ ! -L "$root/current" ] && [ "$left" -gt 0 ]; do
  [ "$left" != "$total" ] || echo "proxy-entrypoint: waiting for the runner-distributor of this node to install the proxy" >&2
  sleep 1
  left=$((left - 1))
done
target=$(readlink "$root/current" 2>/dev/null || true)
case $target in
  versions/*[!0-9A-Za-z._-]* | versions/ | versions/. | versions/..) die "$root/current points to '$target', which is not a version directory" ;;
  versions/*) ;;
  *) die "$root/current is '${target:-missing}': the runner-distributor of this node has not installed the proxy (MACHINE_RUNNER_SWARM_PROXY_VERSION; docker service logs <stack>_runner-distributor)" ;;
esac
dir=$root/$target
bin=$dir/bin/machine-runner-swarm-proxy
[ -x "$bin" ] && [ -f "$dir/SHA256" ] && grep -qx '[0-9a-f]\{64\}  bin/machine-runner-swarm-proxy' "$dir/SHA256" && (cd "$dir" && sha256sum -c SHA256 >/dev/null 2>&1) ||
  die "$bin does not match its SHA-256 record $dir/SHA256: refusing to start (the volume was changed, or the install is incomplete)"
echo "proxy-entrypoint: $(cat "$dir/VERSION" 2>/dev/null || echo "$target") from $dir" >&2
exec "$bin" "$@"
