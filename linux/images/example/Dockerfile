# Bring-your-own image: a stock CircleCI convenience image plus the tools your jobs need.
#
# The runner is NOT in this image. The host's /opt/machine-runner-swarm/current (the runner and circleci-runner-entrypoint, installed by
# linux/setup.sh) is mounted read-only at /opt/machine-runner-swarm, so nothing here has to be rebuilt when
# the runner version changes. Any image that has sudo or util-linux setpriv works.
#
#   docker build -t registry.example.com/ci/linux-pg:1 linux/images/example
#   # then, in linux/stack/runners.yaml:  image: registry.example.com/ci/linux-pg:1
#
# Fully baked variant (target "baked"): the runner and the entrypoint are inside the image, for hosts
# where /opt/machine-runner-swarm cannot be mounted. Build it from the repository root; setup.sh downloads the runner
# and verifies its SHA-256 exactly as it does on a host. Services still use
# entrypoint: ["/opt/machine-runner-swarm/bin/circleci-runner-entrypoint"] and need no /opt/machine-runner-swarm mount.
#
#   docker build -f linux/images/example/Dockerfile --target baked -t registry.example.com/ci/linux-pg:1-baked .
ARG BASE_IMAGE=cimg/base:2026.10
FROM ${BASE_IMAGE} AS tools
USER 0
# hadolint ignore=DL3008  # cimg images track Ubuntu; pin versions if you need exact reproducibility
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client \
 && rm -rf /var/lib/apt/lists/*
# The stack starts the container as root (the entrypoint creates the users). This is the user a plain
# "docker run" of the image gets.
# hadolint ignore=DL3066
USER circleci

FROM tools AS baked
ARG RUNNER_VERSION=3.1.12
USER 0
COPY linux/setup.sh /tmp/swarm/setup.sh
COPY linux/entrypoint/circleci-runner-entrypoint /tmp/swarm/entrypoint/circleci-runner-entrypoint
# setup.sh installs into <prefix>/<version>; the image holds that directory as /opt/machine-runner-swarm, the layout of the mount.
RUN bash /tmp/swarm/setup.sh --install --version "${RUNNER_VERSION}" --prefix /tmp/swarm-install \
 && mv "/tmp/swarm-install/${RUNNER_VERSION}" /opt/machine-runner-swarm \
 && rm -rf /tmp/swarm /tmp/swarm-install
# hadolint ignore=DL3066
USER circleci

# The default target: the image on its own, with the host mount.
FROM tools
