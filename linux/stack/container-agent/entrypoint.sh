#!/bin/sh
# The entrypoint of the container agent (a Swarm config of container-mode.yaml). The image is a stock Go image, so nothing is
# built or published: the Go sources of this directory are Swarm configs mounted at /src, and this script compiles them into the
# per-container volume /work and runs the result. A change of a source file renames its config (ci/config-names.sh), which
# updates the service, so the next container builds the new source. The module has no dependencies: the build needs no network.
set -eu
export CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS=-trimpath HOME=/work GOCACHE=/work/cache GOPATH=/work/path TMPDIR=/work/tmp
mkdir -p /work/tmp   # the root file system is read-only, and the compiler needs a temporary directory
cd /src
echo "container-agent: building from /src with $(go version)"
go build -o /work/container-agent . || { echo "container-agent: the build failed" >&2; exit 80; }   # 80: a problem of the setup, as for the runner
exec /work/container-agent
