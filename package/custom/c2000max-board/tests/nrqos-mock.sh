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
	case " $* " in
		*' qdisc show '*|*' -s qdisc show '*) cat "$MOCK/qdisc"; case " $* " in *' -s '*) printf ' Sent 1000000 bytes 1000 pkt (dropped 0, overlimits 0 requeues 0)\n';; esac; exit 0;;
	esac
	printf '%s\n' "$*" >> "$MOCK/tc.log"
	[ ! -f "$MOCK/tc-fail" ] || exit 1
	case " $* " in
		*' qdisc change '*) [ ! -f "$MOCK/tc-fail-change" ] || exit 1; printf 'qdisc cake 365: root refcnt 2\n' > "$MOCK/qdisc";;
		*' qdisc replace '*) printf 'qdisc cake 365: root refcnt 2\n' > "$MOCK/qdisc";;
		*' qdisc del '*) printf 'qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 4Mb ecn drop_batch 64\n' > "$MOCK/qdisc";;
		*) exit 1;;
	esac;;
ip) printf 'default via 10.0.0.1 dev %s proto dhcp\n' "$(cat "$MOCK/default")";;
logger) :;;
sleep)
	# Match the target BusyBox feature set; accelerate valid integer waits.
	case "${1:-}" in ''|*[!0-9]*) printf 'sleep: invalid number\n' >&2; exit 1;; esac
	/bin/sleep 0.05;;
ping) printf '64 bytes from 223.5.5.5: seq=0 ttl=54 time=20.0 ms\n';;
*) exit 1;;
esac
