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
# NVEncC engine pin (see the nvencc stage below); bump version + sha256 together.
ARG NVENCC_VERSION=9.19
ARG NVENCC_DEB_SHA256=46242e060e0ffb90de1541d75081fb78a4ccb9611d4167eadf3d762f2f227d38

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
    && { \
        echo "Upstream tag: v${UPSTREAM_VERSION}"; \
        echo "Upstream commit: $(git rev-parse HEAD)"; \
        echo "Lidslabs commit: ${JELLYFIN_REF}"; \
        echo "Built: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"; \
       } > /BUILD_INFO

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
# Stage 1b: fetch + verify the rigaya NVEncC binary
# ============================================================
# NVEncC is the DV-preserving transcode engine the v0.4.0 pipeline shells out to
# (DV Profile 7->8.1 RPU copy, honest --master-display relabel) - things stock
# jellyfin-ffmpeg cannot do. The published amd64 .deb is a single statically
# linked binary; its ONLY external runtime dependency is libcuda.so.1, which the
# NVIDIA container runtime injects at container start (exactly as it does for
# jellyfin-ffmpeg's CUDA path - no extra image packages needed). Max glibc symbol
# required is 2.30, so it runs on the bookworm-based runtime image (glibc 2.36).
# Pinned by version + sha256 (declared global at the top) so CI builds are
# reproducible.
FROM debian:bookworm-slim AS nvencc
ARG NVENCC_VERSION
ARG NVENCC_DEB_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fSL -o /tmp/nvencc.deb \
        "https://github.com/rigaya/NVEnc/releases/download/${NVENCC_VERSION}/nvencc_${NVENCC_VERSION}_amd64.deb" \
    && echo "${NVENCC_DEB_SHA256}  /tmp/nvencc.deb" | sha256sum -c - \
    && dpkg-deb -x /tmp/nvencc.deb /nvencc-root \
    && test -x /nvencc-root/usr/bin/nvencc

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

# Bake the DV-preserving NVEncC engine (see the nvencc stage). The binary is
# inert until the transcode path shells out to it (gated on
# LIDSLABS_TRANSCODE_NVENCC); libcuda.so.1 comes from the NVIDIA container
# runtime. World-executable so the non-root run user (1000:1000) can launch it.
COPY --from=nvencc --chmod=755 /nvencc-root/usr/bin/nvencc /usr/bin/nvencc

# HDR transcode is opt-in via env. Default is stock Jellyfin behavior.
ENV LIDSLABS_ALLOW_HDR_TRANSCODE=0

# Persist the CUDA JIT (PTX->cubin) compile cache. The base image gives a
# non-root run user (e.g. user: 1000:1000) HOME=/, which is not writable, so the
# NVIDIA driver cannot write its default ~/.nv/ComputeCache. On GPU architectures
# newer than the cubins bundled in jellyfin-ffmpeg (e.g. Blackwell / sm_120), the
# scale_cuda kernel is then JIT-compiled from PTX on EVERY ffmpeg launch, adding
# ~6s of black-screen warmup to every transcode start. Pointing the cache at the
# persistent /config volume makes that compile happen once, ever (survives
# restarts). The cache is ~6 MB, write-once - no meaningful disk wear. Operators
# with a read-only /config can override CUDA_CACHE_PATH. Pure perf fix, always on.
ENV CUDA_CACHE_PATH=/config/.cudacache
