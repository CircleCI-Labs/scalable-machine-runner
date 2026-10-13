# escape=`
#
# EXAMPLE: bring your own image. How a team adds its tooling on top of STOCK Server Core: this one adds Node.js
# from the official zip, pinned by version and SHA-256. Copy it, swap the tool, keep the pattern:
#   1. start FROM the stock Server Core image of your host's tag (the build must match the host);
#   2. download a PINNED release and verify its SHA-256 before using it;
#   3. install it in a fixed directory, and add that directory to PATH in the stack file (the stack sets PATH in full,
#      see windows/stack/custom-image.yaml): the image holds the tool, and the host provides the runner and Git;
#   4. check that it runs. Do not change USER (the runner needs ContainerAdministrator) or ENTRYPOINT.
#
# Build it (the build context is the windows directory):
#   docker build -f windows/images/example/Dockerfile --build-arg WINDOWS_TAG=ltsc2022 `
#     -t machine-runner-swarm-windows-example:ltsc2022 windows
#
# It is the windows-custom service in windows/stack/custom-image.yaml, an optional overlay file: deploy it with
#   docker stack deploy -c windows/stack/runners.yaml -c windows/stack/custom-image.yaml runners
# Push the image to a registry that every Windows node can pull from. Rebuild it when the base image or the tool changes.

ARG WINDOWS_TAG=ltsc2022
ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:${WINDOWS_TAG}
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

# https://nodejs.org/dist/v24.21.0/SHASUMS256.txt (node-v24.21.0-win-x64.zip)
ARG NODE_VERSION=24.21.0
ARG NODE_SHA256=158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541

LABEL org.opencontainers.image.title="machine-runner-swarm (Windows Server Core, example with Node.js)" `
      machine-runner-swarm.node-version="${NODE_VERSION}"

SHELL ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# The base image already runs as ContainerAdministrator, which the runner needs (symbolic links).
# hadolint ignore=DL3066
USER ContainerAdministrator
RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; `
    $zip = 'C:/node.zip'; `
    Invoke-WebRequest -UseBasicParsing -Uri ('https://nodejs.org/dist/v{0}/node-v{0}-win-x64.zip' -f $env:NODE_VERSION) -OutFile $zip; `
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant() -ne $env:NODE_SHA256) { throw 'SHA-256 mismatch for the Node.js download' }; `
    Expand-Archive -LiteralPath $zip -DestinationPath C:/; `
    Move-Item -LiteralPath ('C:/node-v{0}-win-x64' -f $env:NODE_VERSION) -Destination 'C:/Program Files/nodejs'; `
    Remove-Item -LiteralPath $zip; `
    [Environment]::SetEnvironmentVariable('Path', ([Environment]::GetEnvironmentVariable('Path', 'Machine') + ';C:\Program Files\nodejs'), 'Machine'); `
    & 'C:/Program Files/nodejs/node.exe' --version
