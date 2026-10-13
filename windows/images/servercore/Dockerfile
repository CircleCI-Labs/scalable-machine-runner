# escape=`
#
# BAKED ALTERNATIVE. The default is the stock Server Core image plus a read-only mount of C:\machine-runner-swarm
# (see windows/stack/runners.yaml); use this image when you want one self-contained artifact, for
# example to add tooling on top, or to run on a host that cannot hold
# the C:\machine-runner-swarm directory.
#
# CircleCI machine runner 3 in a Windows Server Core container, at the same paths as the stock
# variant: C:\machine-runner-swarm\bin\circleci-runner.exe and C:\Program Files\Git, with Git on the machine PATH.
# The runner is the ENTRYPOINT, with the same config file path as the stock variant, so the same stack
# keys work: no entrypoint script, no C:\machine-runner-swarm mount and no PATH setting. The token comes from the Swarm
# secret (target circleci_runner_config.yaml), settings from environment variables.
#
# Build (the build context is the windows directory):
#   docker build -f windows/images/servercore/Dockerfile --build-arg WINDOWS_TAG=ltsc2022 `
#     -t machine-runner-swarm-windows-servercore:ltsc2022 windows
#
# WINDOWS_TAG must match the container host for process isolation:
#   Windows Server 2022 host -> ltsc2022
#   Windows Server 2025 host -> ltsc2025 (ltsc2022 also runs process-isolated)
# To pin a monthly patch level pass a tag@digest, for example
#   --build-arg WINDOWS_TAG=ltsc2022@sha256:<index digest>
#
# Runs as ContainerAdministrator, the Server Core default: circleci-runner creates a symbolic link
# when it installs the task agent, which an account without SeCreateSymbolicLinkPrivilege cannot do
# (the runner then retries the download forever and never claims a job).

ARG WINDOWS_TAG=ltsc2022
# Bring your own Server Core based image if you need to (it needs Windows PowerShell 5.1 and tar.exe):
#   --build-arg BASE_IMAGE=mcr.microsoft.com/dotnet/framework/sdk:4.8.1-windowsservercore-ltsc2022
# Nano Server is not supported.
ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:${WINDOWS_TAG}
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ARG WINDOWS_TAG
ARG BASE_IMAGE
# circleci-runner windows/amd64, from https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/manifest.json
ARG RUNNER_VERSION=3.1.12
ARG RUNNER_SHA256=6036674551b510f031a797e7c20a6e09dfa4aef4667532fc64b0194ec4036659
# PortableGit (the same pin as windows/Setup.ps1) and the standalone 7-Zip extractor that unpacks it.
# https://github.com/git-for-windows/git/releases and https://github.com/ip7z/7zip/releases
ARG GIT_VERSION=2.56.0.2
ARG GIT_RELEASE_TAG=v2.56.0.windows.2
ARG GIT_SHA256=075e158ef8e1f0ab80b347e245405d3eca735c2dc88fd8e032e137d0ca61f61b
ARG SEVENZIP_VERSION=26.04
ARG SEVENZIP_SHA256=256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282
# Seconds Windows waits for the processes of the container when it is told to stop (registry value
# WaitToKillServiceTimeout, five seconds by default). Without it every stop, and every rolling update, kills the running
# job after about five seconds. Use at least max_run_time plus the drain margin. See stop-timeout/Dockerfile.
ARG SHUTDOWN_TIMEOUT_SECONDS=18300

LABEL org.opencontainers.image.title="machine-runner-swarm (Windows Server Core, baked)" `
      org.opencontainers.image.description="CircleCI machine runner 3, single-task, one fresh container per job (Docker Swarm)" `
      org.opencontainers.image.source="https://github.com/CircleCI-Labs/scalable-machine-runner" `
      org.opencontainers.image.licenses="MIT" `
      machine-runner-swarm.runner-version="${RUNNER_VERSION}" `
      machine-runner-swarm.git-version="${GIT_VERSION}" `
      machine-runner-swarm.base-image="${BASE_IMAGE}"

SHELL ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Windows account names are not numeric IDs.
# hadolint ignore=DL3066
USER ContainerAdministrator
COPY images/servercore/install-runner.ps1 C:/build/
RUN C:/build/install-runner.ps1 -RunnerVersion $env:RUNNER_VERSION -RunnerSha256 $env:RUNNER_SHA256 `
      -GitVersion $env:GIT_VERSION -GitReleaseTag $env:GIT_RELEASE_TAG -GitSha256 $env:GIT_SHA256 `
      -SevenZipVersion $env:SEVENZIP_VERSION -SevenZipSha256 $env:SEVENZIP_SHA256 -SetMachinePath; `
    Remove-Item -Recurse -Force C:/build; `
    & reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control' /v WaitToKillServiceTimeout /t REG_SZ /d ([string]([int]$env:SHUTDOWN_TIMEOUT_SECONDS * 1000)) /f; `
    if ($LASTEXITCODE -ne 0) { throw 'reg add failed' }

# No HEALTHCHECK: the runner has no health endpoint. Swarm replaces the container when it exits.
ENTRYPOINT ["C:\\machine-runner-swarm\\bin\\circleci-runner.exe", "machine", "--config", "C:\\ProgramData\\Docker\\secrets\\circleci_runner_config.yaml"]
