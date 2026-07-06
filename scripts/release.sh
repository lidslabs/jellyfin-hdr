#!/usr/bin/env bash
# Cut a release: regen patches, validate, tag, push.
# Bump VERSION and (if needed) UPSTREAM_VERSION + JELLYFIN_REF BEFORE running.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" && "$CURRENT_BRANCH" != release/* ]]; then
    echo "ERROR: releases are cut from main or a release/* branch, but HEAD is '$CURRENT_BRANCH'." >&2
    echo "Cut pre-release RCs from release/<ver>; land on main for the final :latest release." >&2
    exit 1
fi

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

if [[ ! "$TAG" =~ -(rc|alpha|beta|dev)\. ]]; then
    if [[ "$CURRENT_BRANCH" != "main" ]]; then
        echo "ERROR: normal releases (:latest) must be cut from main, not '$CURRENT_BRANCH'." >&2
        echo "Merge release/* into main first, then cut the final tag from main." >&2
        exit 1
    fi
    echo "==> $TAG is a NORMAL release (will appear as 'Latest' on GitHub)."
    read -r -p "==> Continue? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted. Bump VERSION to e.g. ${LIDSLABS_VERSION%-*}-rc.1 for a pre-release." >&2
        exit 0
    fi
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

echo "==> Pushing $CURRENT_BRANCH + tag"
git push origin "$CURRENT_BRANCH"
git push origin "$TAG"

echo
echo "Done. GHA will build and publish:"
echo "  ghcr.io/lidslabs/jellyfin-hdr:${TAG//+/-}"
echo "  ghcr.io/lidslabs/jellyfin-hdr:latest"
echo
echo "Watch:  https://github.com/lidslabs/jellyfin-hdr/actions"
