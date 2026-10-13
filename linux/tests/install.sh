#!/usr/bin/env bash
# install.sh: linux/setup.sh --install in a throw-away root container (the host is not touched).
# Needs network access to the CircleCI release bucket. Checks:
#   - the pinned version is downloaded, verified (SHA-256, --version) and installed into <prefix>/<version>,
#     root-owned, nothing in <prefix> writable by group or others, and <prefix>/current links to it
#   - a second run is idempotent (no download) and refreshes a changed entrypoint
#   - a wrong SHA-256 is refused and installs nothing
#   - another version needs --sha256 (taken here from that release's checksums.txt), installs side by side and
#     flips current to it; installing the first version again only flips back (a rollback, without a download)
#   - a non-root user is refused
#   - the function can be sourced and called on its own
#
# Usage: install.sh        Env: SWARM_TEST_CIMG_IMAGE (default cimg/base:2026.10)
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
image=${SWARM_TEST_CIMG_IMAGE:-cimg/base:2026.10}

out=$(docker run --rm --user 0 -v "$repo:/src:ro" "$image" bash -c '
set -uo pipefail
cd /src
r() { echo "RESULT test=install $*"; }
fail() { echo "FAIL: $*"; exit 1; }
perms_ok() { [ -z "$(find "$1" ! -type l \( ! -user root -o -perm /022 \))" ]; }

bash linux/setup.sh --install --prefix /opt/machine-runner-swarm > /tmp/first.log 2>&1 || { cat /tmp/first.log; fail "first install"; }
cur=/opt/machine-runner-swarm/current
ver=$(/opt/machine-runner-swarm/3.1.12/bin/circleci-runner --version | head -n 1)
perms_ok /opt/machine-runner-swarm || fail "files in /opt/machine-runner-swarm are not root-owned or are group/world writable"
[ "$(stat -c "%a %U" /opt/machine-runner-swarm/3.1.12/bin/circleci-runner)" = "755 root" ] || fail "runner mode"
[ "$(cat /opt/machine-runner-swarm/3.1.12/VERSION)" = 3.1.12 ] || fail "VERSION file"
[ -L $cur ] && [ "$(readlink $cur)" = 3.1.12 ] || fail "current is not a link to 3.1.12"
[ "$(cat $cur/VERSION)" = 3.1.12 ] && [ -x $cur/bin/circleci-runner-entrypoint ] || fail "nothing behind the current link"
r step=install version=\"$ver\" owner=root mode=755 writable_by_others=no current=3.1.12

bash linux/setup.sh --install --prefix /opt/machine-runner-swarm > /tmp/second.log 2>&1 || fail "second install"
! grep -q downloading /tmp/second.log || fail "second run downloaded again"
r step=idempotent downloaded_again=no

cp -r linux /tmp/linux2 && echo "# changed" >> /tmp/linux2/entrypoint/circleci-runner-entrypoint
bash /tmp/linux2/setup.sh --install --prefix /opt/machine-runner-swarm > /dev/null 2>&1 || fail "entrypoint refresh"
tail -n 1 $cur/bin/circleci-runner-entrypoint | grep -q "# changed" || fail "the entrypoint was not refreshed"
r step=entrypoint_refresh updated=yes

rm -rf /tmp/bad
bash linux/setup.sh --install --prefix /tmp/bad --sha256 0000000000000000000000000000000000000000000000000000000000000000 > /tmp/bad.log 2>&1 && fail "a wrong SHA-256 was accepted"
grep -q "SHA-256 mismatch" /tmp/bad.log || fail "no mismatch message"
[ ! -e /tmp/bad/3.1.12/bin/circleci-runner ] && [ ! -e /tmp/bad/current ] || fail "the runner was installed despite the mismatch"
r step=wrong_sha256 refused=yes installed=no

bash linux/setup.sh --install --prefix /opt/machine-runner-swarm --version 3.1.11 > /tmp/v311.log 2>&1 && fail "a version without a pinned SHA-256 was accepted"
grep -q "no pinned SHA-256" /tmp/v311.log || fail "no message about the missing SHA-256"
[ "$(readlink $cur)" = 3.1.12 ] || fail "a refused install moved current"
sha=$(curl -fsSL https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/3.1.11/checksums.txt | awk "\$2 == \"circleci-runner_linux_amd64.tar.gz\" { print \$1 }")
bash linux/setup.sh --install --prefix /opt/machine-runner-swarm --version 3.1.11 --sha256 "$sha" > /tmp/v311.log 2>&1 || { cat /tmp/v311.log; fail "3.1.11 with its SHA-256"; }
$cur/bin/circleci-runner --version | grep -q "version 3.1.11" || fail "3.1.11 is not behind current"
/opt/machine-runner-swarm/3.1.12/bin/circleci-runner --version | grep -q "version 3.1.12" || fail "3.1.12 did not stay installed"
perms_ok /opt/machine-runner-swarm || fail "two versions: a file is not root-owned or is group/world writable"
r step=other_version version=3.1.11 needs_sha256=yes side_by_side=yes current=3.1.11

bash linux/setup.sh --install --prefix /opt/machine-runner-swarm > /tmp/back.log 2>&1 || fail "rollback to 3.1.12"
! grep -q downloading /tmp/back.log || fail "the rollback downloaded again"
[ "$(readlink $cur)" = 3.1.12 ] && [ "$(cat $cur/VERSION)" = 3.1.12 ] || fail "current did not flip back to 3.1.12"
[ -x /opt/machine-runner-swarm/3.1.11/bin/circleci-runner ] || fail "3.1.11 was removed by the rollback"
r step=rollback version=3.1.12 downloaded_again=no current=3.1.12

useradd -m tester
su -s /bin/bash tester -c "bash /src/linux/setup.sh --install --prefix /tmp/nonroot" > /tmp/nonroot.log 2>&1 && fail "a non-root install was accepted"
grep -q "needs root" /tmp/nonroot.log || fail "no root message"
r step=non_root refused=yes

bash -c ". linux/setup.sh; swarm_install_runner 3.1.12 /tmp/sourced >/dev/null 2>&1 && echo called" | grep -q called || fail "sourced call"
[ -x /tmp/sourced/current/bin/circleci-runner-entrypoint ] || fail "sourced call installed nothing"
r step=sourced_function ok=yes
echo ALLOK
' 2>&1) || { printf '%s\n' "$out"; echo "FAIL: install test"; exit 1; }
printf '%s\n' "$out" | grep -E '^(RESULT|FAIL)'
grep -q '^ALLOK$' <<< "$out" || { printf '%s\n' "$out"; echo "FAIL: install test did not finish"; exit 1; }
echo "PASS (verified download, root-owned install, idempotent, wrong checksum refused, other versions need --sha256, side by side with a rollback)"
