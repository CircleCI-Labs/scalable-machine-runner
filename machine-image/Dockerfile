# Utilize CircleCI's Runner image which has the runner agent already installed
FROM circleci/runner-agent:machine-3

# Install any packages you need
RUN sudo apt-get update; \
    sudo apt-get install --no-install-recommends -y \
        python3