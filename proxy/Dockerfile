# The token proxy as a container image for Linux: ccilabs/machine-runner-swarm-proxy (docs/install-linux.md, "The token proxy image").
#
#   docker build -t machine-runner-swarm-proxy:dev proxy/
#   docker buildx build --platform linux/amd64,linux/arm64,linux/ppc64le,linux/s390x proxy/
#
# One static Go binary in a distroless static base: CA certificates, a /etc/passwd with the user nobody (65534), no shell and no package
# manager. The image runs as 65534, which is also the owner of the volume that keeps the state (/state). The build stage always runs on the
# build platform and cross-compiles, so a build for another architecture needs no emulation (a run of the result does). The Windows image is
# proxy/Dockerfile.windows.
#
# Build arguments: VERSION is what the proxy reports (-version, and the User-Agent tag of its calls); CI passes sha-<12 characters of the
# commit>. SOURCE_DATE_EPOCH is not an argument here: buildx passes it on, and with rewrite-timestamp it makes the same commit give the same image.
FROM --platform=$BUILDPLATFORM golang:1.27.2@sha256:820153096fda4de6ac1b7194d12e416b7dd8f4e9a33d17e0345b111b945162d8 AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} GOTOOLCHAIN=local \
    go build -trimpath -buildvcs=false -ldflags="-s -w -X main.version=${VERSION}" -o /out/machine-runner-swarm-proxy ./cmd/machine-runner-swarm-proxy \
 && mkdir -p /out/state && chmod 0700 /out/state

FROM gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3
ARG VERSION=dev
ARG REVISION=
LABEL org.opencontainers.image.title="machine-runner-swarm-proxy" \
      org.opencontainers.image.description="The runner token proxy of machine-runner-swarm: it holds the CircleCI resource class tokens, so that runner containers do not" \
      org.opencontainers.image.source="https://github.com/CircleCI-Labs/scalable-machine-runner" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"
COPY --from=build /out/machine-runner-swarm-proxy /machine-runner-swarm-proxy
# A new named volume takes the owner and mode of its mount point: the state volume of the stack files is mounted here, writable by 65534 only.
COPY --from=build --chown=65534:65534 /out/state /state
USER 65534:65534
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 CMD ["/machine-runner-swarm-proxy", "-healthcheck"]
ENTRYPOINT ["/machine-runner-swarm-proxy"]
CMD ["-state-dir", "/state"]
