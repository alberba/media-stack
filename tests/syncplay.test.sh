#!/usr/bin/env bash
# Tests for automatic web player selection in Jellyfin Android SyncPlay groups.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if command -v node >/dev/null 2>&1; then
  node --test "$REPO/tests/syncplay-web-player.test.cjs"
else
  docker run --rm -v "$REPO:/repo:ro" node:22-alpine \
    node --test /repo/tests/syncplay-web-player.test.cjs
fi
