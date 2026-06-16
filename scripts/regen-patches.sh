#!/usr/bin/env bash
# Regenerate patches/ from the pinned commit in the lidslabs/jellyfin fork.
# Run from the build repo root after bumping JELLYFIN_REF.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FORK_DIR="${FORK_DIR:-$HOME/dev/jellyfin}"
JELLYFIN_REF="$(cat JELLYFIN_REF)"
UPSTREAM_VERSION="$(cat UPSTREAM_VERSION)"

if [[ ! -d "$FORK_DIR/.git" ]]; then
    echo "ERROR: $FORK_DIR is not a git checkout. Set FORK_DIR env var to point at your fork." >&2
    exit 1
fi

echo "Regenerating patches:"
echo "  Fork checkout:    $FORK_DIR"
echo "  Upstream version: $UPSTREAM_VERSION"
echo "  Pinned commit:    $JELLYFIN_REF"
echo

if ! git -C "$FORK_DIR" cat-file -e "${JELLYFIN_REF}^{commit}" 2>/dev/null; then
    echo "ERROR: commit $JELLYFIN_REF not found in $FORK_DIR" >&2
    echo "Run: git -C $FORK_DIR fetch origin" >&2
    exit 1
fi

if ! git -C "$FORK_DIR" cat-file -e "v${UPSTREAM_VERSION}^{commit}" 2>/dev/null; then
    echo "ERROR: tag $UPSTREAM_VERSION not found in $FORK_DIR" >&2
    echo "Run: git -C $FORK_DIR fetch upstream --tags" >&2
    exit 1
fi

rm -rf patches/
mkdir -p patches/

git -C "$FORK_DIR" format-patch \
    "v${UPSTREAM_VERSION}..${JELLYFIN_REF}" \
    --output-directory "$REPO_ROOT/patches" \
    > /dev/null

COUNT="$(ls patches/ | wc -l)"
echo "Generated $COUNT patch file(s) in patches/"
ls -la patches/
