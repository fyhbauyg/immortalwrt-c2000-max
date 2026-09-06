#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../../.." && pwd)
INIT=${1:-$TOP/package/mtk/applications/luci-app-eqos-mtk/root/etc/init.d/eqos}
source <(sed -n '/^c2000_eqos_yield_nrqos() {/,/^}/p; /^eqos_stop_service_locked() {/,/^}/p' "$INIT")
ACTIVE=1; EQ_ACTIVE=0; FAIL=0; STALE=0; CALLS=0
C2000_NRQOS_BIN=fake_nr
c2000_nrqos_active() { [ "$ACTIVE" = 1 ]; }
eqos_runtime_active() { [ "$EQ_ACTIVE" = 1 ]; }
fake_nr() {
	[ "$1" = yield-to-eqos ] || return 1
	CALLS=$((CALLS+1))
	[ "$FAIL" = 0 ] || return 1
	[ "$STALE" = 1 ] || ACTIVE=0
}
c2000_eqos_yield_nrqos
test "$ACTIVE:$CALLS" = 0:1
c2000_eqos_yield_nrqos
test "$CALLS" = 1
ACTIVE=1; FAIL=1
if c2000_eqos_yield_nrqos >/dev/null 2>&1; then exit 1; fi
test "$ACTIVE" = 1
FAIL=0; STALE=1
if c2000_eqos_yield_nrqos >/dev/null 2>&1; then exit 1; fi
test "$ACTIVE" = 1
eqos() { echo 'UNSAFE EQoS RESET' >&2; exit 99; }
eqos_stop_service_locked
EQ_ACTIVE=1
if eqos_stop_service_locked >/dev/null 2>&1; then exit 1; fi
echo 'EQoS priority tests passed: successful handoff, no-op, failed/stale stop refusal, inactive limiter preserves NR hardware.'
