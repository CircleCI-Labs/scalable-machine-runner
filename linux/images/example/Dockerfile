# Bring-your-own image: a stock CircleCI convenience image plus the tools your jobs need.
#
# The runner is NOT in this image. The runner-distributor service of the stack keeps it in a per-node volume, which the stack mounts
# read-only at /opt/machine-runner-swarm with the entrypoint (a Swarm config), so nothing here has to be rebuilt when the runner
# version changes. Any image that has sudo or util-linux setpriv works.
#
#   docker build -t registry.example.com/ci/linux-pg:1 linux/images/example
#   # then, in linux/stack/runners.yaml:  image: registry.example.com/ci/linux-pg:1
ARG BASE_IMAGE=cimg/base:2026.10
FROM ${BASE_IMAGE}
USER 0
# hadolint ignore=DL3008  # cimg images track Ubuntu; pin versions if you need exact reproducibility
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client \
 && rm -rf /var/lib/apt/lists/*
# The stack starts the container as root (the entrypoint creates the users). This is the user a plain
# "docker run" of the image gets.
# hadolint ignore=DL3066
USER circleci
