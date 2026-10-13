#!/bin/sh
# runner-distributor.sh: keep the pinned circleci-runner on this node. Draft: the command of the runner-distributor service
# (stack/distributor.yaml), a global service from a stock Alpine image. It gets this file as a Swarm config, and:
#   /opt/machine-runner-swarm                     the per-node volume runner-bin (read-write here, read-only in the runners)
#   MACHINE_RUNNER_SWARM_RUNNER_VERSION           the runner version
#   MACHINE_RUNNER_SWARM_RUNNER_SHA256_AMD64/_ARM64   SHA-256 of the circleci-runner BINARY in that version's tarball
# It downloads the runner when versions/<version> is missing or its binary does not match the pin, verifies the SHA-256, then moves
# the link current to versions/<version> with one atomic rename, and idles. Old versions stay, so a rollback is only a flip.
# shellcheck disable=SC2154  # the MACHINE_RUNNER_SWARM_* variables come from the service
set -eu
root=/opt/machine-runner-swarm
v=${MACHINE_RUNNER_SWARM_RUNNER_VERSION:?}
base=${MACHINE_RUNNER_SWARM_DOWNLOAD_BASE_URL:-https://circleci-binary-releases.s3.amazonaws.com/circleci-runner}
case $(uname -m) in
  x86_64) arch=amd64 pin=${MACHINE_RUNNER_SWARM_RUNNER_SHA256_AMD64:?} ;;
  aarch64) arch=arm64 pin=${MACHINE_RUNNER_SWARM_RUNNER_SHA256_ARM64:?} ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
case $v in [0-9]*[!0-9A-Za-z._-]* | [!0-9]*) echo "invalid version '$v'" >&2; exit 1 ;; esac
sha() { sha256sum "$1" | cut -d' ' -f1; }

if [ -x "$root/versions/$v/bin/circleci-runner" ] && [ "$(sha "$root/versions/$v/bin/circleci-runner")" = "$pin" ]; then
  echo "circleci-runner $v is installed already: switching to it"
else
  echo "downloading circleci-runner $v linux/$arch"
  rm -rf "$root"/.tmp.* && mkdir -p "$root/versions" && tmp=$(mktemp -d "$root/.tmp.XXXXXX")   # same filesystem as versions/: mv is atomic
  mkdir -m 0755 "$tmp/bin"
  wget -q -O "$tmp/runner.tar.gz" "$base/$v/circleci-runner_linux_$arch.tar.gz"
  tar -xzf "$tmp/runner.tar.gz" -C "$tmp/bin" circleci-runner
  [ "$(sha "$tmp/bin/circleci-runner")" = "$pin" ] || { echo "SHA-256 mismatch for circleci-runner $v linux/$arch: refusing to install" >&2; rm -rf "$tmp"; exit 1; }
  rm "$tmp/runner.tar.gz"
  chown -R 0:0 "$tmp" && chmod 0755 "$tmp" "$tmp/bin/circleci-runner"
  rm -rf "$root/versions/$v" && mv "$tmp" "$root/versions/$v"
fi
ln -s "versions/$v" "$root/.current.$$" && mv -T "$root/.current.$$" "$root/current"
echo "[ ok ] current -> versions/$v: circleci-runner $v linux/$arch"

trap 'exit 0' TERM INT
while :; do sleep 3600 & wait $!; done
