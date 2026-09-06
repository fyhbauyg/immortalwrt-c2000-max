#!/bin/sh
case "$(basename "$0")" in
uci)
	while [ "${1:-}" = -q ]; do shift; done
	[ "${1:-}" = get ] || exit 1
	key=${2:-}
	case "$key" in
		c2000max_nrqos.main.*) key=${key#c2000max_nrqos.main.}; awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); value=$0;found=1} END {if(found) print value; else exit 1}' "$MOCK/config";;
		eqos.config.enabled) [ -f "$MOCK/eqos-on" ] && printf '1\n' || printf '0\n';;
		*) exit 1;;
	esac;;
tc)
	dev=eth2; prev=
	for arg in "$@"; do [ "$prev" != dev ] || dev=$arg; prev=$arg; done
	qdisc="$MOCK/qdisc"; [ "$dev" != ifb-nrqos ] || qdisc="$MOCK/down-qdisc"
	case " $* " in
		*' qdisc show '*|*' -s qdisc show '*)
			cat "$qdisc" 2>/dev/null || :
			case " $* " in *' -s '*) printf ' Sent 1000000 bytes 1000 pkt (dropped 0, overlimits 0 requeues 0)\n';; esac
			[ "$dev" != eth2 ] || cat "$MOCK/ingress" 2>/dev/null || :
			exit 0;;
		*' filter show '*)
			[ ! -e "$MOCK/filter-read-fail" ] || exit 1
			filter_file() {
				if [ "$scoped" = 1 ] && [ ! -e "$MOCK/keep-pref" ]; then
					# Real tc suppresses fields already selected by the command.
					sed 's/ parent ffff: / /g; s/ pref 365 / /g' "$1" 2>/dev/null || :
				else cat "$1" 2>/dev/null || :; fi
			}
			scoped=0; case " $* " in *' pref 365 '*) scoped=1;; esac
			filter_file "$MOCK/filters"
			if [ -f "$MOCK/filter-clock" ] && [ -s "$MOCK/filters" ]; then
				clock=$(cat "$MOCK/filter-clock"); clock=$((clock+1)); printf '%s\n' "$clock" > "$MOCK/filter-clock"
				printf '\tindex 1 ref 1 bind 1 installed %s sec used %s sec firstused %s sec\n\tAction statistics:\n\tSent %s bytes %s pkt (dropped 0, overlimits 0 requeues 0)\n' "$clock" "$clock" "$clock" "$((clock*1400))" "$clock"
			fi
			filter_file "$MOCK/same-pref-filters"
			case " $* " in *' pref 365 '*) :;; *) cat "$MOCK/foreign-filters" 2>/dev/null || :;; esac
			exit 0;;
	esac
	printf '%s\n' "$*" >> "$MOCK/tc.log"
	[ ! -f "$MOCK/tc-fail" ] || exit 1
	if [ -f "$MOCK/fail-match" ] && printf '%s\n' "$*" | grep -Fq "$(cat "$MOCK/fail-match")"; then exit 1; fi
	handle=365:; [ "$dev" != ifb-nrqos ] || handle=366:
	case " $* " in
		*' qdisc add '*|*' qdisc del '*' ingress '*)
			case " $* " in
				*' add '*) [ ! -s "$MOCK/ingress" ] || exit 1; printf 'qdisc ingress ffff: parent ffff:fff1 ----------------\n' > "$MOCK/ingress";;
				*) rm -f "$MOCK/ingress";;
			esac;;
		*' filter add '*)
			# Real C2000MAX tc output: the summary header has no handle; the
			# detailed header identifies the single classifier instance.
			printf 'filter parent ffff: protocol all pref 365 matchall chain 0 \nfilter parent ffff: protocol all pref 365 matchall chain 0 handle 0x1 \n  skip_hw\n  not_in_hw (rule hit 4273)\n\taction order 1: mirred (Egress Redirect to device ifb-nrqos) stolen\n\tindex 1 ref 1 bind 1 installed 8 sec firstused 8 sec\n\tAction statistics:\n\tSent 4433735 bytes 4273 pkt (dropped 0, overlimits 0 requeues 0)\n\tbacklog 0b 0p requeues 0\n' > "$MOCK/filters";;
		*' filter del '*) rm -f "$MOCK/filters";;
		*' qdisc change '*) [ ! -f "$MOCK/tc-fail-change" ] || exit 1; printf 'qdisc cake %s root refcnt 2\n' "$handle" > "$qdisc";;
		*' qdisc replace '*) printf 'qdisc cake %s root refcnt 2\n' "$handle" > "$qdisc";;
		*' qdisc del '*) printf 'qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 4Mb ecn drop_batch 64\n' > "$qdisc";;
		*) exit 1;;
	esac;;
ip)
	case " $* " in *' route show default '*) printf 'default via 10.0.0.1 dev %s proto dhcp\n' "$(cat "$MOCK/default")"; exit 0;; esac
	printf '%s\n' "$*" >> "$MOCK/ip.log"
	if [ -f "$MOCK/fail-match" ] && printf '%s\n' "$*" | grep -Fq "$(cat "$MOCK/fail-match")"; then exit 1; fi
	case " $* " in
		*' link add name ifb-nrqos type ifb '*)
			mkdir "$MOCK/sys/class/net/ifb-nrqos" || exit 1
			printf '99\n' > "$MOCK/sys/class/net/ifb-nrqos/ifindex"
			: > "$MOCK/sys/class/net/ifb-nrqos/ifalias"
			printf 'qdisc noqueue 0: root refcnt 2\n' > "$MOCK/down-qdisc";;
		*' link set dev ifb-nrqos alias '*) shift 5; printf '%s\n' "$1" > "$MOCK/sys/class/net/ifb-nrqos/ifalias";;
		*' link set dev ifb-nrqos up '*)
			test -d "$MOCK/sys/class/net/ifb-nrqos" || exit 1
			printf 'qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 4Mb ecn drop_batch 64\n' > "$MOCK/down-qdisc";;
		*' link del dev ifb-nrqos '*)
			rm -f "$MOCK/sys/class/net/ifb-nrqos/ifalias" "$MOCK/sys/class/net/ifb-nrqos/ifindex" "$MOCK/down-qdisc"
			rmdir "$MOCK/sys/class/net/ifb-nrqos";;
		*) exit 1;;
	esac;;
logger) :;;
nft)
	case "$*" in
		'list tables') [ ! -f "$MOCK/hq-table" ] || printf 'table inet c2000max_nr_hqos\n'; exit 0;;
		'-c -f '*) exit 0;;
		'-f '*) cp "$2" "$MOCK/hq-table";;
		'list table inet '*|'-s list table inet '*) [ -f "$MOCK/hq-table" ] && cat "$MOCK/hq-table";;
		'delete table inet '*) rm "$MOCK/hq-table";;
		*) exit 1;;
	esac;;
mount) printf '/dev/mmcblk0p6 on /rom type squashfs (ro)\n';;
sleep)
	# Match the target BusyBox feature set; accelerate valid integer waits.
	case "${1:-}" in ''|*[!0-9]*) printf 'sleep: invalid number\n' >&2; exit 1;; esac
	/bin/sleep 0.05;;
ping) printf '64 bytes from 223.5.5.5: seq=0 ttl=54 time=20.0 ms\n';;
*) exit 1;;
esac
