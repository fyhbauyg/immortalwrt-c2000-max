#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$ROOT/feeds/packages/net/sqm-scripts/patches"
cp "$ROOT/scripts/c2000max/sqm-source-v365.patch" \
   "$ROOT/feeds/packages/net/sqm-scripts/patches/100-c2000max-accel-compat.patch"
patch="$ROOT/scripts/c2000max/luci-sqm-v365.patch"
if git -C "$ROOT/feeds/luci" apply --reverse --check "$patch" 2>/dev/null; then
    : # already applied
else
    git -C "$ROOT/feeds/luci" apply --check "$patch"
    git -C "$ROOT/feeds/luci" apply "$patch"
fi
