#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
BIN="$ROOT/files/usr/sbin/c2000max-nrqos"
TMP=$(mktemp -d /tmp/nrqos-hqos-integration.XXXXXX)
cleanup() { [ -z "${pid:-}" ] || kill "$pid" 2>/dev/null || :; case "$TMP" in /tmp/nrqos-hqos-integration.*) rm -rf "$TMP";; esac; }
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/sys/class/net/eth2/device" "$TMP/sys/drivers/cdc_ncm" "$TMP/sys/class/block/mmcblk0/device" "$TMP/sys/kernel/debug/hnat"
ln -s "$TMP/sys/drivers/cdc_ncm" "$TMP/sys/class/net/eth2/device/driver"
for c in tc uci ip logger sleep ping nft mount; do ln -s "$HERE/nrqos-mock.sh" "$TMP/bin/$c"; done
export MOCK="$TMP" PATH="$TMP/bin:$PATH"
export C2000MAX_NRQOS_STATE="$TMP/state" C2000MAX_NRQOS_SYS="$TMP/sys"
export C2000MAX_NRQOS_BOARD="$TMP/board" C2000MAX_NRQOS_COMPAT="$TMP/compat"
export C2000MAX_NRQOS_EQOS_STATE="$TMP/eqos-backend" C2000MAX_NRQOS_ROLE_LOCK="$TMP/role" C2000MAX_NRQOS_HNAT_LOCK="$TMP/hnat"
export C2000MAX_NRQOS_HQ_LIB="$HERE/nrqos-hqos-mock-lib.sh" HQ_TEST_LIB="$ROOT/files/usr/lib/c2000max/nrqos-hqos.sh"
printf 'nradio,c2000-max\n' > "$TMP/board"
printf 'c2000_sqm_enabled() { return 1; }\n' > "$TMP/compat"
printf SD > "$TMP/sys/class/block/mmcblk0/device/type"
printf 'qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 4Mb ecn drop_batch 64\n' > "$TMP/qdisc"
printf eth2 > "$TMP/default"
printf '%s\n' 'enabled=1' 'interface=eth2' 'upload_kbit=130000' 'download_enabled=1' 'download_backend=hqos' 'download_kbit=130000' 'autorate=0' > "$TMP/config"
H="$TMP/sys/kernel/debug/hnat"
for q in 0 60 61 62 63; do printf '0 1 10000 0 0 0 4\n' > "$H/qdma_txq$q"; done
printf '0 wrr 0\n' > "$H/qdma_sch3"
printf enabled > "$H/hook_toggle"
printf 'mode=disabled uplink=disabled downlink=disabled\n' > "$H/qos_toggle"
: > "$H/hnat_entry"
sh "$BIN" start
sh "$BIN" status | jq -e '.active and .download_active and .download_backend=="hqos" and .api_version==3' >/dev/null
test ! -e "$TMP/sys/class/net/ifb-nrqos"
sh "$BIN" stop
test ! -f "$TMP/state/hqos/owner"
grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"

sh "$BIN" run & pid=$!
for n in $(seq 1 100); do [ -f "$TMP/state/owner" ] && break; /bin/sleep .05; done
test -f "$TMP/state/owner"
# Same lock ordering as the EQoS controller: stop another process while the
# caller owns ROLE/HNAT. It must not wait on its own lock through the child.
exec 4<>"$TMP/role" 5<>"$TMP/hnat"
flock -x 4; flock -x 5
touch "$TMP/eqos-on"
timeout 10 env C2000MAX_ACCEL_LOCKS_HELD=1 sh "$BIN" yield-to-eqos
wait "$pid" || :; pid=
flock -u 5; flock -u 4
test ! -f "$TMP/state/hqos/owner"
test ! -f "$TMP/state/down-session"
grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"
grep -q '^mode=disabled ' "$H/qos_toggle"
grep -q 'Device limiter has priority' "$TMP/state/error"
if sh "$BIN" start; then echo 'NR QoS overwrote enabled EQoS' >&2; exit 1; fi
test ! -f "$TMP/state/owner"
rm "$TMP/eqos-on"
sh "$BIN" start
sh "$BIN" stop
echo 'HQoS/CAKE integration passed: start/status/stop, no IFB, EQoS lock-held handoff, refusal while limiter enabled, restart.'
