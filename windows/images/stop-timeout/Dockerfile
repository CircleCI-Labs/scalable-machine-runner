# escape=`
#
# STOCK Windows Server Core plus ONE registry value: how long Windows waits for the processes of a container
# when the container is told to stop, so that a running job can finish. Use it as the image of the stock-image
# services in windows/stack/*.yaml (they still mount C:\smr and Git); the baked image has the same value built in.
#
# Why: HCS shuts a Server Core container down by sending CTRL_SHUTDOWN_EVENT and then waits for
# HKLM\SYSTEM\CurrentControlSet\Control\WaitToKillServiceTimeout, five seconds by default, before it kills the
# processes. Whatever "docker stop -t" or stop_grace_period says, a stock Server Core container ends about five
# seconds after the stop (exit code 3221225786, 0xC000013A), and so does the job running in it. The runner drains
# on the event, but only if the container is allowed to live while it does. Nano Server is not affected, and
# containerd's hcsshim works around it (hcsshim PR 1416); the Docker engine's own runtime does not.
# How to use it, and what to do on the plain image: docs/images.md ("Windows: the stop-timeout image") and
# docs/operations.md ("Windows drain").
#
# Build (the build context is this directory):
#   docker build -f windows/images/stop-timeout/Dockerfile --build-arg WINDOWS_TAG=ltsc2022 `
#     -t registry.example.com/ci/servercore-stop:ltsc2022 windows/images/stop-timeout
#
# The value is in seconds; use at least max_run_time plus the drain margin (stop_grace_period in the stack file).

ARG WINDOWS_TAG=ltsc2022
ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:${WINDOWS_TAG}
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ARG SHUTDOWN_TIMEOUT_SECONDS=18300

SHELL ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# reg add changes one value. Do NOT use New-Item -Force on an existing registry key: it replaces the key and
# deletes everything in it (doing that to the cexecsvc service key stops the container from starting).
RUN & reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control' /v WaitToKillServiceTimeout /t REG_SZ /d ([string]([int]$env:SHUTDOWN_TIMEOUT_SECONDS * 1000)) /f; `
    if ($LASTEXITCODE -ne 0) { throw 'reg add failed' }
