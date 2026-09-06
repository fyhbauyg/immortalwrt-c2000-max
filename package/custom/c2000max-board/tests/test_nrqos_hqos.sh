#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
TMP=$(mktemp -d /tmp/c2000max-hqos-test.XXXXXX)
cleanup_test() { case "$TMP" in /tmp/c2000max-hqos-test.*) rm -rf "$TMP";; esac; }
trap cleanup_test EXIT
STATE="$TMP/state"; SYS="$TMP/sys"
mkdir -p "$STATE" "$SYS/kernel/debug/hnat" "$SYS/class/block/mmcblk0/device"
printf SD > "$SYS/class/block/mmcblk0/device/type"
export C2000MAX_NRQOS_ROLE_LOCK="$TMP/role.lock" C2000MAX_NRQOS_HNAT_LOCK="$TMP/hnat.lock"
get() { [ "$1" != game_udp_ports ] || printf '%s\n' "${PORTS:-}"; }
uint() { [[ "$1" =~ ^[0-9]{1,8}$ ]]; }
bounded() { uint "$1" && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
error() { printf '%s\n' "$*" > "$TMP/error"; return 1; }
ingress_line() { :; }
conflicts() { [ ! -f "$TMP/eqos" ]; }
mount() { printf '/dev/mmcblk0p6 on /rom type squashfs (ro)\n'; }
. "$ROOT/files/usr/lib/c2000max/nrqos-hqos.sh"
hq_read() {
	local n=$1 q s mi ir ma mr w r en policy rate
	case "$n" in
	 qdma_txq*)
		read -r s mi ir ma mr w r < "$HQ_NODES/$n"
		printf 'scheduler: %s\nhw resv: %s\nsw resv: %s\npacket count: 5\nbytes count: 1000\npacket drop: 0\nmax %s %s %s\nmin %s %s -\n' "$s" "$r" "$r" "$ma" "$mr" "$w" "$mi" "$ir" ;;
	 qdma_sch3)
		read -r en policy rate < "$HQ_NODES/$n"
		printf 'EN Scheduling MAX Queue#\n%s %s %s' "$en" "${policy^^}" "$rate"
		for q in 0 60 61 62 63; do read -r s rest < "$HQ_NODES/qdma_txq$q"; [ "$s" != 3 ] || printf ' %s' "$q"; done
		printf '\n' ;;
	 *) cat "$HQ_NODES/$n" ;;
	esac
}
hq_write() {
	local n=$1 v=$2
	case "$n" in qdma_txq60|qdma_txq61|qdma_txq62|qdma_sch3|qos_toggle|hnat_entry) :;; *) echo "UNSAFE WRITE $n" >&2; exit 99;; esac
	COUNT=$((COUNT+1)); printf '%s %s\n' "$n" "$v" >> "$TMP/writes"
	[ "$COUNT" != "${FAIL_AT:-0}" ] || return 1
	if [ "$n" = qos_toggle ]; then
		case "$v" in 0) v='mode=disabled uplink=disabled downlink=disabled';; '1 downlink') v='mode=hqos uplink=disabled downlink=enabled';; *) exit 98;; esac
	fi
	printf '%s\n' "$v" > "$HQ_NODES/$n"
}
nft() {
	local file=${@: -1}
	case "$*" in
	 'list tables') [ ! -f "$TMP/table" ] || printf 'table inet %s\n' "$HQ_TABLE"; return 0 ;;
	 '-c -f '*) [ "${NFT_FAIL:-}" != check ] ;;
	 '-f '*) [ "${NFT_FAIL:-}" != apply ] || return 1; cp "$file" "$TMP/table" ;;
	 'list table inet '*|'-s list table inet '*) [ -f "$TMP/table" ] && cat "$TMP/table" ;;
	 'delete table inet '*) rm "$TMP/table" ;;
	 *) echo "unexpected nft $*" >&2; return 1 ;;
	esac
}
reset_case() {
	[ ! -f "$HQ_DIR/owner" ] || hq_cleanup "$(cat "$HQ_DIR/owner")" || true
	case "$HQ_DIR" in "$TMP"/*) rm -rf "$HQ_DIR";; esac
	for q in 0 60 61 62 63; do printf '0 1 10000 0 0 0 4\n' > "$HQ_NODES/qdma_txq$q"; done
	printf '0 0 0 0 0 0 4\n' > "$HQ_NODES/qdma_txq61"
	printf '0 wrr 0\n' > "$HQ_NODES/qdma_sch3"
	printf 'mode=disabled uplink=disabled downlink=disabled\n' > "$HQ_NODES/qos_toggle"
	printf 'enabled\n' > "$HQ_NODES/hook_toggle"
	: > "$HQ_NODES/hnat_entry"
	rm -f "$TMP/table" "$TMP/eqos" "$TMP/error"
	: > "$TMP/writes"
	COUNT=0; FAIL_AT=0; NFT_FAIL=; AUTO=0; DOWN_RATE=137777; PORTS='3074 3074 27015'
}
assert() { "$@" || { echo "FAILED: $*" >&2; exit 1; }; }
reset_case
hq_setup token-1
hq_owned
assert test "$(cat "$HQ_DIR/rate")" = 130000
assert test "$(hq_signature qdma_txq62)" = '3 0 0 1 26000 16 4'
assert test "$(hq_bytes)" = 3000
assert grep -Fq 'udp sport { 3074, 27015 }' "$TMP/table"
assert grep -Fq 'meta mark & 0x00800000 != 0 return' "$TMP/table"
assert grep -Fq 'meta mark & 0xffffffc0' "$TMP/table"
assert test "$(hq_signature qdma_txq63)" = '0 1 10000 0 0 0 4'
hq_cleanup old-token
assert test -f "$HQ_DIR/owner"
hq_cleanup token-1
assert test ! -f "$HQ_DIR/owner"
assert test ! -e "$TMP/table"
assert test "$(hq_signature qdma_txq61)" = '0 0 0 0 0 0 4'
assert test "$(hq_signature qdma_sch3)" = '0 wrr 0'
assert test "$(hq_read qos_toggle)" = 'mode=disabled uplink=disabled downlink=disabled'
count=$COUNT; hq_cleanup token-1; assert test "$COUNT" = "$count"

for failure in $(seq 1 8); do
	reset_case; FAIL_AT=$failure
	if hq_setup token-fail; then echo "expected injected failure $failure" >&2; exit 1; fi
	assert test ! -f "$HQ_DIR/owner"
	assert test ! -e "$TMP/table"
	assert test "$(hq_signature qdma_sch3)" = '0 wrr 0'
	assert test "$(hq_read qos_toggle)" = 'mode=disabled uplink=disabled downlink=disabled'
done
for failure in check apply; do
	reset_case; NFT_FAIL=$failure
	if hq_setup token-fail; then exit 1; fi
	assert test ! -f "$HQ_DIR/owner"
	assert test "$(hq_signature qdma_sch3)" = '0 wrr 0'
done
for why in eqos auto foreign-queue foreign-scheduler foreign-table bad-port; do
	reset_case
	case "$why" in
	 eqos) touch "$TMP/eqos";; auto) AUTO=1;;
	 foreign-queue) printf '2 0 0 1 50000 4 1\n' > "$HQ_NODES/qdma_txq60";;
	 foreign-scheduler) printf '1 wrr 50000\n' > "$HQ_NODES/qdma_sch3";;
	 foreign-table) touch "$TMP/table";; bad-port) PORTS='3074; touch /tmp/injection';;
	esac
	if hq_setup denied; then echo "expected refusal: $why"; exit 1; fi
	assert test ! -s "$TMP/writes"
done
reset_case
exec 8<>"$C2000MAX_NRQOS_HNAT_LOCK"; flock -x 8
if hq_setup busy; then exit 1; fi
assert test ! -s "$TMP/writes"
flock -u 8
hq_setup owned
cp "$HQ_NODES/qdma_txq60" "$TMP/q60-copy"
printf '3 0 0 1 80000 8 4\n' > "$HQ_NODES/qdma_txq60"
if hq_owned || hq_cleanup owned; then exit 1; fi
assert test "$(hq_read qos_toggle)" = 'mode=hqos uplink=disabled downlink=enabled'
assert test "$(hq_signature qdma_txq60)" = '3 0 0 1 80000 8 4'
cp "$TMP/q60-copy" "$HQ_NODES/qdma_txq60"
printf '\n# user edit\n' >> "$TMP/table"
if hq_cleanup owned; then exit 1; fi
assert test "$(hq_read qos_toggle)" = 'mode=hqos uplink=disabled downlink=enabled'
cp "$HQ_DIR/rules.nft" "$TMP/table"
hq_cleanup owned
echo 'HQoS tests passed: rates, classification, ownership, locks, all write faults, foreign-resource preservation, exact rollback.'
