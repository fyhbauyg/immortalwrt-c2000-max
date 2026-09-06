#!/bin/sh
# Test-only text-backed QDMA register adapter; never installed in a firmware.
[ -n "${MOCK:-}" ] && [ -n "${HQ_TEST_LIB:-}" ] || exit 99
. "$HQ_TEST_LIB"
hq_read() {
	local n=$1 q s mi ir ma mr w r en policy rate rest
	case "$n" in
	 qdma_txq*)
		read -r s mi ir ma mr w r < "$HQ_NODES/$n"
		printf 'scheduler: %s\nhw resv: %s\nsw resv: %s\nbytes count: 1000\nmax %s %s %s\nmin %s %s -\n' "$s" "$r" "$r" "$ma" "$mr" "$w" "$mi" "$ir" ;;
	 qdma_sch3)
		read -r en policy rate < "$HQ_NODES/$n"
		printf 'EN Scheduling MAX Queue#\n%s %s %s' "$en" "$policy" "$rate"
		for q in 0 60 61 62 63; do read -r s rest < "$HQ_NODES/qdma_txq$q"; [ "$s" != 3 ] || printf ' %s' "$q"; done
		printf '\n' ;;
	 *) cat "$HQ_NODES/$n" ;;
	esac
}
hq_write() {
	local n=$1 v=$2
	case "$n" in qdma_txq60|qdma_txq61|qdma_txq62|qdma_sch3|qos_toggle|hnat_entry) :;; *) exit 99;; esac
	printf '%s %s\n' "$n" "$v" >> "$MOCK/hq-writes"
	if [ "$n" = qos_toggle ]; then
		case "$v" in 0) v='mode=disabled uplink=disabled downlink=disabled';; '1 downlink') v='mode=hqos uplink=disabled downlink=enabled';; *) exit 98;; esac
	fi
	printf '%s\n' "$v" > "$HQ_NODES/$n"
}
