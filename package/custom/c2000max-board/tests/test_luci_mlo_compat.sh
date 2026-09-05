#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
TOP="$(CDPATH= cd "$ROOT/../../.." && pwd)"
NETWORK="$TOP/feeds/luci/modules/luci-compat/luasrc/model/network.lua"
PATCH="$TOP/scripts/c2000max/luci-compat-mlo-list-device.patch"
WORKFLOW="$TOP/.github/workflows/c2000max-one-shot-build.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq 'local devices = type(s.device) == "table" and s.device or { s.device }' "$PATCH" ||
	fail 'durable luci-compat patch does not normalize MLO list devices'
grep -Fq 'for _, device in ipairs(devices) do' "$PATCH" ||
	fail 'durable luci-compat patch does not enumerate MLO member radios'
grep -Fq 'luci-compat-mlo-list-device.patch' "$WORKFLOW" ||
	fail 'build workflow does not apply the MLO luci-compat patch'

if [ -f "$NETWORK" ]; then
	grep -Fq 'local devices = type(s.device) == "table" and s.device or { s.device }' "$NETWORK" ||
		fail 'applied luci-compat network model cannot handle an MLO device list'
	grep -Fq 'for _, device in ipairs(devices) do' "$NETWORK" ||
		fail 'applied luci-compat network model does not enumerate MLO member radios'
	if sed -n '/-- find wifi interfaces/,/return ifaces/p' "$NETWORK" | grep -Fq 'num[s.device]'; then
		fail 'applied luci-compat network model still indexes a table as a device name'
	fi
	if command -v luac >/dev/null 2>&1; then
		luac -p "$NETWORK"
	fi
fi

echo 'C2000MAX MLO luci-compat list-device tests passed'
