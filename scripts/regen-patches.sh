#!/usr/bin/env bash
# Regenerate patches/ from the lidslabs/jellyfin fork.
#
# Two modes:
#   1. Dev loop (auto-pin) - pass a fork ref to pin + regenerate in one step:
#        ./scripts/regen-patches.sh lidslabs/force-hevc-clients
#      Resolves the ref in the fork, writes its SHA to JELLYFIN_REF, then regenerates.
#   2. Reproducible - no argument, use the committed JELLYFIN_REF as-is:
#        ./scripts/regen-patches.sh
#      This is the mode release.sh uses; a release never re-resolves a branch.
#
# FORK_DIR defaults to the sibling ../jellyfin checkout (lidslabs repos layout).
# Override with FORK_DIR=/path/to/fork to point elsewhere.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FORK_DIR="${FORK_DIR:-$(cd "$REPO_ROOT/../jellyfin" 2>/dev/null && pwd || true)}"
FORK_REF="${1:-${FORK_REF:-}}"
UPSTREAM_VERSION="$(cat UPSTREAM_VERSION)"

if [[ -z "$FORK_DIR" || ! -d "$FORK_DIR/.git" ]]; then
    echo "ERROR: fork checkout not found at '${FORK_DIR:-<unset>}'." >&2
    echo "Expected the lidslabs/jellyfin fork as a sibling (../jellyfin)." >&2
    echo "Set FORK_DIR=/path/to/jellyfin to override." >&2
    exit 1
fi

# Mode 1: auto-pin JELLYFIN_REF from a fork ref (dev-loop convenience only).
if [[ -n "$FORK_REF" ]]; then
    if ! NEW_REF="$(git -C "$FORK_DIR" rev-parse --verify "${FORK_REF}^{commit}" 2>/dev/null)"; then
        echo "ERROR: ref '$FORK_REF' not found in $FORK_DIR" >&2
        echo "Run: git -C $FORK_DIR fetch origin" >&2
        exit 1
    fi
    OLD_REF="$(cat JELLYFIN_REF 2>/dev/null || echo '<none>')"
    echo "$NEW_REF" > JELLYFIN_REF
    echo "Pinned JELLYFIN_REF from ref '$FORK_REF':"
    echo "  old: $OLD_REF"
    echo "  new: $NEW_REF"
    echo
fi

JELLYFIN_REF="$(cat JELLYFIN_REF)"

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
    echo "ERROR: tag v$UPSTREAM_VERSION not found in $FORK_DIR" >&2
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
