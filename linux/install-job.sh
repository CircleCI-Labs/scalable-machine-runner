#!/bin/sh
# install-job.sh: install one runner version and point current at it, on the node that runs this container. It is the
# command of a Swarm global job from a small image (Alpine or BusyBox); see docs/operations.md. The job provides:
#   /host-opt                                     a bind mount of the node's /opt (read-write)
#   /circleci-runner-entrypoint                   the entrypoint, from a Swarm config
#   MACHINE_RUNNER_SWARM_VERSION                  the runner version
#   MACHINE_RUNNER_SWARM_SHA256_AMD64 and _ARM64  the SHA-256 of that version's tarballs (checksums.txt of the release)
# The layout and the atomic flip are those of linux/setup.sh --install. A version that is installed already is only switched to.
# shellcheck disable=SC2154  # the MACHINE_RUNNER_SWARM_* variables come from the job
set -eu
case $(uname -m) in
  x86_64) arch=amd64 sha=$MACHINE_RUNNER_SWARM_SHA256_AMD64 ;;
  aarch64) arch=arm64 sha=$MACHINE_RUNNER_SWARM_SHA256_ARM64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
v=$MACHINE_RUNNER_SWARM_VERSION
case $v in [0-9]*[!0-9A-Za-z._-]* | [!0-9]*) echo "invalid version '$v'" >&2; exit 1 ;; esac
d=/host-opt/machine-runner-swarm
t=circleci-runner_linux_$arch.tar.gz
put() { install -m 0755 "$1" "$2.new" && mv -f "$2.new" "$2"; }

if "$d/$v/bin/circleci-runner" --version 2>&1 | grep -qF "version $v"; then
  echo "circleci-runner $v is installed already: switching to it"
else
  echo "downloading circleci-runner $v linux/$arch"
  tmp=$(mktemp -d)
  wget -q -O "$tmp/$t" "https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/$v/$t"
  echo "$sha  $tmp/$t" | sha256sum -c - >/dev/null || { echo "SHA-256 mismatch for $t: refusing to install" >&2; exit 1; }
  tar -xzf "$tmp/$t" -C "$tmp" circleci-runner
  "$tmp/circleci-runner" --version 2>&1 | grep -qF "version $v" || { echo "the downloaded binary does not report version $v" >&2; exit 1; }
  install -d -m 0755 "$d" "$d/$v" "$d/$v/bin"
  put "$tmp/circleci-runner" "$d/$v/bin/circleci-runner"
  rm -rf "$tmp"
fi
put /circleci-runner-entrypoint "$d/$v/bin/circleci-runner-entrypoint"
echo "$v" > "$d/$v/VERSION"
ln -s "$v" "$d/.current.new"
mv -T "$d/.current.new" "$d/current"
echo "[ ok ] /opt/machine-runner-swarm/current -> $v on $(cat /proc/sys/kernel/hostname)"
