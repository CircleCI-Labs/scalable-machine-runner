# escape=`
#
# EXAMPLE: bring your own image. How a team adds its tooling on top of the baked runner image
# (windows/images/servercore): this one adds Node.js from the official zip, pinned by version and SHA-256.
# Copy it, swap the tool, keep the pattern:
#   1. start FROM the baked image, which has the runner as its ENTRYPOINT and Git on PATH;
#   2. download a PINNED release and verify its SHA-256 before using it;
#   3. put the tool on the machine PATH (the stack file sets no PATH for a baked image);
#   4. check that it runs. Do not change USER (the runner needs ContainerAdministrator) or ENTRYPOINT.
#
# Build the baked image first, then this one (the build context is the windows directory):
#   docker build -f windows/images/servercore/Dockerfile --build-arg WINDOWS_TAG=ltsc2022 `
#     -t smr-windows-servercore:ltsc2022 windows
#   docker build -f windows/images/example/Dockerfile `
#     --build-arg BASE_IMAGE=smr-windows-servercore:ltsc2022 -t smr-windows-example:ltsc2022 windows
#
# It is the windows-custom service in windows/stack/custom-image.yaml, an optional overlay file: deploy it with
#   docker stack deploy -c windows/stack/runners.yaml -c windows/stack/custom-image.yaml smr
# Push the image to a registry that every Windows node can pull from. Rebuild it when the base image or the tool changes.

ARG BASE_IMAGE=smr-windows-servercore:ltsc2022
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

# https://nodejs.org/dist/v24.21.0/SHASUMS256.txt (node-v24.21.0-win-x64.zip)
ARG NODE_VERSION=24.21.0
ARG NODE_SHA256=158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541

LABEL org.opencontainers.image.title="scalable-machine-runner (Windows Server Core, example with Node.js)" `
      com.circleci.smr.node-version="${NODE_VERSION}"

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
