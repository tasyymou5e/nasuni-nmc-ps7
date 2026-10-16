# syntax=docker/dockerfile:1
# Nasuni.Nmc container image: PowerShell 7.4 LTS on Azure Linux 3.0 (amd64 and arm64).
#
# Targets:
#   runtime  dashboard + MCP server (no tests, no demo)          docker build --target runtime
#   demo     runtime + fake NMC + sample data (development only)  docker build --target demo
#   test     runs every build gate (parse, lint, Pester) on Linux docker build --target test
#
# FIPS: the container uses the HOST kernel. On a FIPS-mode Linux host (fips=1) Azure Linux's OpenSSL
# runs its FIPS provider and Test-NasuniFipsHost passes; Docker Desktop's VM is not FIPS, so only
# the demo/test targets (which set the development override) run there.

ARG TARGETARCH
FROM mcr.microsoft.com/powershell:7.4-azurelinux-3.0 AS base-amd64
FROM mcr.microsoft.com/powershell:7.4-azurelinux-3.0-arm64 AS base-arm64

FROM base-${TARGETARCH} AS runtime
ENV POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    NASUNI_CONTAINER=1 \
    HOME=/home/nasuni \
    PSModuleAnalysisCachePath=/tmp/ps-module-cache.clixml
# Pinned dependency (the version the test suite was verified with). TODO(roadmap#13): mirror internally.
RUN pwsh -NoLogo -NoProfile -Command \
      "Set-PSResourceRepository -Name PSGallery -Trusted; Install-PSResource -Name Pode -Version 2.14.1 -Scope AllUsers -Quiet; Get-Module -ListAvailable Pode | Select-Object Name, Version | Out-String" \
 && mkdir -p /app /home/nasuni /var/lib/nasuni /etc/nasuni \
 && chown -R 10001:10001 /home/nasuni /var/lib/nasuni
WORKDIR /app
COPY --chown=root:root src/ /app/src/
COPY --chown=root:root docker/entrypoint.ps1 /app/docker/entrypoint.ps1
COPY --chown=root:root LICENSE README.md /app/
# Non-root, fixed uid so volume permissions are predictable.
USER 10001:10001
EXPOSE 8443
ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "/app/docker/entrypoint.ps1"]
CMD ["dashboard"]

FROM runtime AS demo
USER root
COPY --chown=root:root tools/ /app/tools/
COPY --chown=root:root tests/LocalTlsServer.ps1 /app/tests/LocalTlsServer.ps1
USER 10001:10001
ENV NASUNI_ALLOW_NON_FIPS_HOST=1 \
    NASUNI_ENVIRONMENT=Demo
EXPOSE 8765
CMD ["demo"]

FROM runtime AS test
USER root
RUN pwsh -NoLogo -NoProfile -Command \
      "Install-PSResource -Name Pester -Version 6.1.0 -Scope AllUsers -Quiet; Install-PSResource -Name PSScriptAnalyzer -Version 1.25.0 -Scope AllUsers -Quiet"
COPY . /app/
RUN chown -R 10001:10001 /app
USER 10001:10001
ENV NASUNI_ALLOW_NON_FIPS_HOST=1
RUN pwsh -NoLogo -NoProfile -Command "./build/build.ps1"
