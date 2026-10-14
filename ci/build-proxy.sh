#!/usr/bin/env bash
# Build the token proxy (proxy/) as static binaries: the proxy-test job, which checks that every platform builds and hands the windows/amd64
# binary to the Windows image (proxy/Dockerfile.windows, ci/Build-ProxyImage.ps1). The Linux image builds the proxy itself, in its Dockerfile,
# with the same flags.
#
#   ci/build-proxy.sh OUT_DIR [VERSION [TARGET...]]
#   ci/build-proxy.sh --list
#
# TARGET is GOOS/GOARCH (default: every platform of CircleCI's runner manifest: linux amd64, arm64, ppc64le and s390x, and windows amd64 and
# arm64). Each build is written to OUT_DIR/machine-runner-swarm-proxy_<os>_<arch>, and VERSION (default dev) is what the proxy reports
# (-version, and the User-Agent tag of its calls). --list prints those file names, one for each default target. It uses the Go on PATH, and
# without one a pinned golang container.
set -euo pipefail

default_targets=(linux/amd64 linux/arm64 linux/ppc64le linux/s390x windows/amd64 windows/arm64)
if [[ ${1:-} == --list ]]; then
  for t in "${default_targets[@]}"; do echo "machine-runner-swarm-proxy_${t%/*}_${t#*/}"; done
  exit 0
fi

out=${1:?usage: ci/build-proxy.sh OUT_DIR [VERSION [TARGET...]] | --list}
version=${2:-dev}
shift $(($# < 2 ? $# : 2))
targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=("${default_targets[@]}")
src=$(cd "$(dirname "$0")/../proxy" && pwd)
go_image=${PROXY_GO_IMAGE:-golang:1.27.2@sha256:820153096fda4de6ac1b7194d12e416b7dd8f4e9a33d17e0345b111b945162d8}
mkdir -p "$out"
out=$(cd "$out" && pwd)

for t in "${targets[@]}"; do
  os=${t%/*}
  arch=${t#*/}
  name=machine-runner-swarm-proxy_${os}_${arch}
  flags=(-trimpath -buildvcs=false "-ldflags=-s -w -X main.version=$version" -o "$out/$name" ./cmd/machine-runner-swarm-proxy)
  if command -v go > /dev/null; then
    (cd "$src" && CGO_ENABLED=0 GOOS=$os GOARCH=$arch GOTOOLCHAIN=local go build "${flags[@]}")
  else
    docker run --rm -u "$(id -u):$(id -g)" -v "$src:/src:ro" -v "$out:$out" -w /src \
      -e CGO_ENABLED=0 -e "GOOS=$os" -e "GOARCH=$arch" -e GOTOOLCHAIN=local -e GOCACHE=/tmp/gocache -e HOME=/tmp \
      "$go_image" go build "${flags[@]}"
  fi
  echo "built $out/$name"
done
