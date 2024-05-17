# Utilize any base image
FROM ubuntu:24.04

# Switch to root for installing needed packages
USER root

# Install CircleCI Registry and circleci-runner package
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl ca-certificates \
    && curl -s https://packagecloud.io/install/repositories/circleci/runner/script.deb.sh?any=true -o /tmp/script.deb.sh \
    && bash /tmp/script.deb.sh \
    && rm -f /tmp/script.deb.sh \
    && apt-get install --no-install-recommends -y circleci-runner \
    && rm -rf /var/lib/apt/lists/*

# Switch circleci user to run the CircleCI Runner
USER circleci

CMD ["/usr/bin/circleci-runner", "machine", "-c", "/etc/circleci-runner/circleci-runner-config.yaml"]