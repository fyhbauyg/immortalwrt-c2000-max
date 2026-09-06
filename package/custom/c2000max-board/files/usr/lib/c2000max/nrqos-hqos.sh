#!/bin/sh
# Optional USB-NR downstream QDMA owner. Never writes firmware/MTD/bootenv.
# Keep this separate from the proven CAKE backend. EQoS always has priority.
HQ_DIR="$STATE/hqos"
HQ_NODES="$SYS/kernel/debug/hnat"
HQ_TABLE=c2000max_nr_hqos
HQ_LOCKED=0

hq_lock() {
	[ "$HQ_LOCKED" != 1 ] || return 0
	[ "${C2000MAX_ACCEL_LOCKS_HELD:-0}" != 1 ] || return 0
	exec 6<>"${C2000MAX_NRQOS_ROLE_LOCK:-/var/lock/c2000max-port-role.lock}" || return 1
	exec 7<>"${C2000MAX_NRQOS_HNAT_LOCK:-/var/lock/c2000max-hnat.lock}" || return 1
	flock -n -x 6 || return 1
	flock -n -x 7 || { flock -u 6; return 1; }
	HQ_LOCKED=1
}
hq_unlock() {
	[ "$HQ_LOCKED" != 1 ] || { flock -u 7; flock -u 6; HQ_LOCKED=0; }
}
hq_read() { cat "$HQ_NODES/$1" 2>/dev/null; }
hq_write() { printf '%s' "$2" > "$HQ_NODES/$1"; }
hq_signature() {
	case "$1" in
		qdma_txq*) hq_read "$1" | awk '
			/^scheduler:/{s=$2; ns++} /^hw resv:/{h=$3; nh++} /^sw resv:/{w=$3; nw++}
			/^max /{ma=$2; mr=$3; wt=$4; nx++} /^min /{mi=$2; ir=$3; nn++}
			END {if(ns!=1||nh!=1||nw!=1||nx!=1||nn!=1||h!=w) exit 1;
			print s,mi,ir,ma,mr,wt,h}' ;;
		qdma_sch3) hq_read "$1" | awk 'NR==2 {if(NF<3)exit 1; $2=tolower($2); print; ok=1} END {if(!ok)exit 1}' ;;
		qos_toggle) hq_read "$1" ;;
		*) return 1 ;;
	esac
}
hq_table_sig() { nft -s list table inet "$HQ_TABLE" 2>/dev/null | sha256sum | awk '{print $1}'; }
hq_table_absent() {
	local tables
	tables=$(nft list tables 2>/dev/null) || return 1
	! printf '%s\n' "$tables" | grep -Fxq "table inet $HQ_TABLE"
}
hq_round_rate() {
	# The hardware represents rate as a 7-bit mantissa times 10^exponent.
	# Quantize explicitly so readback matches; never round above the cap.
	local r=$1 e=1
	while [ "$r" -gt 127 ]; do r=$((r / 10)); e=$((e * 10)); done
	printf '%s\n' "$((r * e))"
}
hq_ports() {
	local p n=0 seen=' '
	HQ_PORTS=
	for p in $(get game_udp_ports); do
		bounded "$p" 1 65535 || { error 'Game UDP ports must be individual integers 1..65535'; return 1; }
		case " $seen " in *" $p "*) continue;; esac
		n=$((n+1)); [ "$n" -le 32 ] || { error 'At most 32 game UDP ports are supported'; return 1; }
		seen="$seen$p "; HQ_PORTS="${HQ_PORTS:+$HQ_PORTS, }$p"
	done
}
hq_rules() {
	# No DSCP trust, no conntrack mark writes, no all-UDP priority heuristic.
	# Priority matches explicit server ports, not client ephemeral ports.
	printf 'table inet %s {\n comment "c2000max-nrqos-hqos-v1";\n' "$HQ_TABLE"
	printf ' chain downstream {\n type filter hook forward priority -140; policy accept;\n'
	printf ' iifname != "eth2" return\n oifname != "br-lan" return\n'
	printf ' meta mark & 0x00800000 != 0 return\n'
	if [ -n "$HQ_PORTS" ]; then
		printf ' udp sport { %s } counter meta mark set (meta mark & 0xffffffc0) | 62 return\n' "$HQ_PORTS"
	fi
	printf ' meta l4proto { icmp, ipv6-icmp } counter meta mark set (meta mark & 0xffffffc0) | 62 return\n'
	printf ' tcp sport { 80, 443 } counter meta mark set (meta mark & 0xffffffc0) | 61 return\n'
	printf ' udp sport 443 counter meta mark set (meta mark & 0xffffffc0) | 61 return\n'
	printf ' counter meta mark set (meta mark & 0xffffffc0) | 60\n }\n}\n'
}
hq_flush() {
	# Invalidate accelerator bindings only; do not delete connection/NAT state.
	local c
	if [ -x /usr/sbin/c2000max-traffic ]; then
		C2000MAX_ACCEL_LOCKS_HELD=1 /usr/sbin/c2000max-traffic mib-sync >/dev/null 2>&1 || :
	fi
	for c in 3 5 7; do hq_write hnat_entry "$c -1" || return 1; done
}
hq_check_nodes() {
	local node
	[ "$(hq_read hook_toggle)" = enabled ] || { error 'Hardware download requires active MediaTek HNAT'; return 1; }
	for node in qdma_sch3 qdma_txq0 qdma_txq60 qdma_txq61 qdma_txq62 qdma_txq63 qos_toggle hnat_entry; do
		[ -e "$HQ_NODES/$node" ] || { error "Required HQoS node is missing: $node"; return 1; }
	done
	[ ! -e "$HQ_NODES/qdma_txq64" ] || { error 'Unexpected QDMA layout; no hardware changes made'; return 1; }
}
hq_preflight() {
	[ "$AUTO" = 0 ] || { error 'Hardware download currently supports fixed rates only; disable autorate'; return 1; }
	[ "$(cat "$SYS/class/block/mmcblk0/device/type" 2>/dev/null)" = SD ] &&
		mount | grep -q '^/dev/mmcblk0p6 on /rom ' || { error 'Hardware QoS is restricted to the TF-card system'; return 1; }
	hq_check_nodes && hq_ports || return 1
	[ ! -e "$HQ_DIR/owner" ] || { error 'Previous HQoS session needs cleanup; restart the service'; return 1; }
	[ ! -e "$SYS/class/net/ifb-nrqos" ] && [ -z "$(ingress_line)" ] || { error 'Ingress/IFB is occupied; stop the previous download backend first'; return 1; }
	[ "$(hq_read qos_toggle)" = 'mode=disabled uplink=disabled downlink=disabled' ] || { error 'Hardware queues are owned by another service'; return 1; }
	[ "$(hq_signature qdma_sch3)" = '0 wrr 0' ] || { error 'QDMA scheduler 3 is not idle'; return 1; }
	local q v
	for q in 60 61 62; do
		v=$(hq_signature "qdma_txq$q") || return 1
		case "$v" in '0 1 10000 0 0 0 4'|'0 0 0 0 0 0 4') :;; *) error "QDMA queue $q has foreign settings"; return 1;; esac
	done
	hq_table_absent || { error 'Hardware classifier exists or nftables cannot be inspected'; return 1; }
}
hq_owned() {
	local node expected
	[ -f "$HQ_DIR/active" ] && [ -s "$HQ_DIR/owner" ] || return 1
	[ "$(hq_read hook_toggle)" = enabled ] || return 1
	for node in qdma_sch3 qdma_txq60 qdma_txq61 qdma_txq62 qos_toggle; do
		expected=$(cat "$HQ_DIR/$node.expected" 2>/dev/null)
		[ -n "$expected" ] && [ "$(hq_signature "$node")" = "$expected" ] || return 1
	done
	nft list table inet "$HQ_TABLE" >/dev/null 2>&1 || return 1
	[ "$(hq_table_sig)" = "$(cat "$HQ_DIR/table.sig" 2>/dev/null)" ]
}
hq_cleanup_locked() {
	local token=$1 node current old expected foreign=0 table
	[ -f "$HQ_DIR/owner" ] || return 0
	[ "$(cat "$HQ_DIR/owner")" = "$token" ] || return 0
	# Audit the entire hardware transaction before touching global mode. A
	# competing owner may use the same toggle value with different queues.
	for node in qos_toggle qdma_sch3 qdma_txq60 qdma_txq61 qdma_txq62; do
		[ -f "$HQ_DIR/$node.before" ] || continue
		old=$(cat "$HQ_DIR/$node.before"); expected=$(cat "$HQ_DIR/$node.expected" 2>/dev/null)
		current=$(hq_signature "$node") || { foreign=1; continue; }
		[ "$current" != "$old" ] && [ "$current" != "$expected" ] || continue
		if [ "$node" != qdma_sch3 ] || ! printf '%s\n' "$current" | grep -Eq '^0 wrr 0( 60)?( 61)?( 62)?$'; then foreign=1; fi
	done
	if [ "$foreign" != 0 ]; then error 'HQoS resources changed externally; recovery journal retained, global mode not overwritten'; return 1; fi
	# Remove only our unchanged private table, never one edited by another app.
	if nft list table inet "$HQ_TABLE" >/dev/null 2>&1; then
		if [ -s "$HQ_DIR/table.sig" ] && [ "$(hq_table_sig)" = "$(cat "$HQ_DIR/table.sig")" ]; then
			nft delete table inet "$HQ_TABLE" || foreign=1
		else foreign=1; fi
	elif ! hq_table_absent; then
		foreign=1
	fi
	if [ "$foreign" != 0 ]; then error 'Hardware classifier changed externally; its queues were not overwritten'; return 1; fi
	# Restore only values matching our journal (or already equal to baseline).
	# The scheduler signature includes assigned QIDs, guarding foreign users.
	for node in qos_toggle qdma_sch3 qdma_txq60 qdma_txq61 qdma_txq62; do
		[ -f "$HQ_DIR/$node.before" ] || continue
		old=$(cat "$HQ_DIR/$node.before"); expected=$(cat "$HQ_DIR/$node.expected" 2>/dev/null)
		current=$(hq_signature "$node") || { foreign=1; continue; }
		if [ "$current" = "$old" ]; then continue; fi
		if [ "$current" != "$expected" ]; then
			# During partial setup, queues may already have moved before the
			# scheduler is enabled. Only our three reserved QIDs are allowed.
			if [ "$node" != qdma_sch3 ] || ! printf '%s\n' "$current" | grep -Eq '^0 wrr 0( 60)?( 61)?( 62)?$'; then
				foreign=1; continue
			fi
		fi
		case "$node" in
			qos_toggle) hq_write "$node" 0 || foreign=1 ;;
			qdma_sch3) hq_write "$node" '0 wrr 0' || foreign=1 ;;
			*) hq_write "$node" "$old" || foreign=1 ;;
		esac
	done
	hq_flush || foreign=1
	if [ "$foreign" != 0 ]; then error 'HQoS cleanup found changed/unreadable resources; retained recovery journal, no foreign settings overwritten'; return 1; fi
	rm -f "$HQ_DIR/owner" "$HQ_DIR/active" "$HQ_DIR"/*.before "$HQ_DIR"/*.expected "$HQ_DIR/table.sig" "$HQ_DIR/rules.nft" "$HQ_DIR/rate"
	rmdir "$HQ_DIR" 2>/dev/null || :
}
hq_cleanup() {
	[ -f "$HQ_DIR/owner" ] || return 0
	hq_lock || { error 'Acceleration controller busy; HQoS recovery retained'; return 1; }
	hq_cleanup_locked "$1"; local rc=$?
	hq_unlock; return "$rc"
}
hq_setup_locked() {
	local token=$1 node q cap prio value rc=0
	# Repeat all guards while holding ROLE -> HNAT. Preflight alone is racy.
	conflicts && hq_preflight || return 1
	cap=$(hq_round_rate "$DOWN_RATE"); prio=$(hq_round_rate "$((cap / 5))")
	[ "$prio" -ge 1 ] || prio=1
	mkdir -p "$HQ_DIR" || return 1
	hq_rules > "$HQ_DIR/rules.nft"
	nft -c -f "$HQ_DIR/rules.nft" || { error 'Hardware classifier validation failed'; return 1; }
	for node in qdma_sch3 qdma_txq60 qdma_txq61 qdma_txq62 qos_toggle; do
		hq_signature "$node" > "$HQ_DIR/$node.before" || return 1
	done
	printf '%s\n' "$token" > "$HQ_DIR/owner"
	printf '1 wrr %s 60 61 62\n' "$cap" > "$HQ_DIR/qdma_sch3.expected"
	printf 'mode=hqos uplink=disabled downlink=enabled\n' > "$HQ_DIR/qos_toggle.expected"
	printf '3 0 0 1 %s 8 4\n' "$cap" > "$HQ_DIR/qdma_txq60.expected"
	printf '3 0 0 1 %s 2 4\n' "$cap" > "$HQ_DIR/qdma_txq61.expected"
	printf '3 0 0 1 %s 16 4\n' "$prio" > "$HQ_DIR/qdma_txq62.expected"
	for q in 60 61 62; do
		hq_write "qdma_txq$q" "$(cat "$HQ_DIR/qdma_txq$q.expected")" || { rc=1; break; }
	done
	[ "$rc" != 0 ] || hq_write qdma_sch3 "1 wrr $cap" || rc=1
	if [ "$rc" = 0 ]; then
		nft -f "$HQ_DIR/rules.nft" || rc=1
		if [ "$rc" = 0 ]; then hq_table_sig > "$HQ_DIR/table.sig"; fi
	fi
	[ "$rc" != 0 ] || hq_write qos_toggle '1 downlink' || rc=1
	[ "$rc" != 0 ] || hq_flush || rc=1
	printf '%s\n' "$cap" > "$HQ_DIR/rate"
	if [ "$rc" = 0 ]; then
		: > "$HQ_DIR/active"
		hq_owned || rc=1
	fi
	if [ "$rc" != 0 ]; then
		hq_cleanup_locked "$token" || :
		error 'Hardware download setup/readback failed; check recovery status before retrying'
		return 1
	fi
}
hq_setup() {
	hq_lock || { error 'Acceleration controller busy; no hardware changes made'; return 1; }
	hq_setup_locked "$1"; local rc=$?
	hq_unlock; return "$rc"
}
hq_bytes() {
	local q
	for q in 60 61 62; do hq_read "qdma_txq$q"; done |
		awk '/^bytes count:/ {sum+=$3;n++} END{if(n!=3)exit 1; printf "%.0f\n",sum}'
}
