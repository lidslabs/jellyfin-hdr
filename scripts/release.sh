#!/usr/bin/env bash
# Cut a release: regen patches, validate, tag, push.
# Bump VERSION and (if needed) UPSTREAM_VERSION + JELLYFIN_REF BEFORE running.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree dirty. Commit pin file changes first." >&2
    git status --short >&2
    exit 1
fi

LIDSLABS_VERSION="$(cat VERSION)"
UPSTREAM_VERSION="$(cat UPSTREAM_VERSION)"
TAG="v${LIDSLABS_VERSION}+jellyfin-${UPSTREAM_VERSION}"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "ERROR: tag $TAG already exists. Bump VERSION." >&2
    exit 1
fi

echo "==> Regenerating patches from fork"
./scripts/regen-patches.sh

if [[ -n "$(git status --porcelain patches/)" ]]; then
    echo "==> patches/ differs from committed state - staging changes"
    git add patches/
    git commit -m "Regenerate patches for ${TAG}"
fi

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "Release $TAG"

echo "==> Pushing main + tag"
git push origin main
git push origin "$TAG"

echo
echo "Done. GHA will build and publish:"
echo "  ghcr.io/lidslabs/jellyfin-hdr:${TAG//+/-}"
echo "  ghcr.io/lidslabs/jellyfin-hdr:latest"
echo
echo "Watch:  https://github.com/lidslabs/jellyfin-hdr/actions"
