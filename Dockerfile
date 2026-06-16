# syntax=docker/dockerfile:1.7
#
# lidslabs/jellyfin-hdr - HDR-preserving Jellyfin transcode build
#
# Builds patched Jellyfin DLLs by cloning the upstream tag in UPSTREAM_VERSION
# and applying patches from ./patches/ (generated from the lidslabs/jellyfin
# fork at the commit pinned in ./JELLYFIN_REF). The build needs ONLY this
# repo; the fork is the dev workflow tool, the patches are the build input.
#
# Build is driven by GitHub Actions on tag push - do not invoke directly.
# Build args (with defaults that match committed pin files):
#   UPSTREAM_VERSION  jellyfin upstream version, no 'v' prefix (e.g. 10.11.10)
#   JELLYFIN_REF      commit SHA in lidslabs/jellyfin recorded for provenance
#   DOTNET_VERSION    .NET SDK major version (Jellyfin 10.11 uses 9.0)

ARG UPSTREAM_VERSION=10.11.10
ARG JELLYFIN_REF=unknown
ARG DOTNET_VERSION=9.0

# ============================================================
# Stage 1: build patched DLLs from upstream source + ./patches/
# ============================================================
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION}-bookworm-slim AS builder

ARG UPSTREAM_VERSION
ARG JELLYFIN_REF
WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Clone upstream at the exact released tag the patches target. If upstream
# retroactively rewrites a tag (rare), or our patches are out of sync with
# the pinned tag, the `git am` below will fail loudly.
RUN git clone --depth 1 --branch v${UPSTREAM_VERSION} \
        https://github.com/jellyfin/jellyfin.git . \
    && git log -1 --pretty=format:"Upstream tag: v${UPSTREAM_VERSION}%nUpstream commit: %H%nLidslabs commit: ${JELLYFIN_REF}%nBuilt: %ai%n" \
       > /BUILD_INFO

# Apply lidslabs patches via git am. Patches were generated with format-patch
# from the lidslabs/jellyfin fork - git am preserves author and message.
COPY patches/ /tmp/patches/
RUN git config user.email "build@lidslabs" \
    && git config user.name  "lidslabs-build" \
    && git am /tmp/patches/*.patch \
    && rm -rf /tmp/patches

# Publish the full server. Analyzers and debug symbols disabled to cut ~30s.
RUN dotnet publish Jellyfin.Server/Jellyfin.Server.csproj \
        -c Release \
        -p:RunAnalyzers=false \
        -p:DebugType=none \
        -p:DebugSymbols=false \
        -o /publish

# ============================================================
# Stage 2: overlay patched DLLs onto the official runtime image
# ============================================================
FROM jellyfin/jellyfin:${UPSTREAM_VERSION}

ARG UPSTREAM_VERSION
ARG JELLYFIN_REF

LABEL org.opencontainers.image.title="jellyfin-hdr"
LABEL org.opencontainers.image.description="Jellyfin with HDR-preserving NVENC transcode (lidslabs custom)"
LABEL org.opencontainers.image.source="https://github.com/lidslabs/jellyfin-hdr"
LABEL org.opencontainers.image.documentation="https://github.com/lidslabs/jellyfin-hdr/blob/main/README.md"
LABEL org.opencontainers.image.licenses="GPL-2.0-only"
LABEL org.opencontainers.image.version="${UPSTREAM_VERSION}"
LABEL org.lidslabs.jellyfin.upstream-version="${UPSTREAM_VERSION}"
LABEL org.lidslabs.jellyfin.fork-commit="${JELLYFIN_REF}"

# Provenance record - inspect with:
#   docker run --rm ghcr.io/lidslabs/jellyfin-hdr:VERSION cat /BUILD_INFO
COPY --from=builder /BUILD_INFO /BUILD_INFO

# Overlay the two assemblies containing our patched code onto the official
# runtime image. Built against the same upstream tag, so the rest of the
# base image's Jellyfin DLLs remain binary-compatible with our overlaid pair.
COPY --from=builder /publish/MediaBrowser.Controller.dll /jellyfin/MediaBrowser.Controller.dll
COPY --from=builder /publish/Jellyfin.Api.dll            /jellyfin/Jellyfin.Api.dll

# HDR transcode is opt-in via env. Default is stock Jellyfin behavior.
ENV JELLYFIN_ALLOW_HDR_TRANSCODE=0
