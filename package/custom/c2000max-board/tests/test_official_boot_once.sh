#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/files/usr/sbin/c2000max-boot-official-once"
sh -n "$HELPER"
LEGACY="$ROOT/files/usr/lib/c2000max/official-return-tf"
sh -n "$LEGACY"
# A SPI read-only release must not contain a reachable or dormant write path.
if grep -Eq '(^|[[:space:]])(fw_setenv|mount|mtd|dd|reboot|/sbin/reboot)[[:space:]]' "$HELPER" "$LEGACY"; then
 echo 'FAIL: legacy flash writer remains in one-shot helper'; exit 1
fi
if sh "$LEGACY"; then echo 'FAIL: legacy return script accepted'; exit 1; fi
bash "$ROOT/tests/test_v365_safety.sh"
echo 'Official boot is safely disabled in the read-only SPI release'
