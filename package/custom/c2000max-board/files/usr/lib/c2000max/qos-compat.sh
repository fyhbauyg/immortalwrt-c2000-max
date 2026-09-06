#!/bin/sh

# The optional NR shaper owns this single root handle; it does not request
# disabling HNAT and must never be included in c2000_sqm_enabled().
c2000_nrqos_active()
{
	[ -f /var/run/c2000max-nrqos/hqos/owner ] && return 0
	tc qdisc show dev eth2 2>/dev/null | grep -q '^qdisc cake 365: root' && return 0
	# Also protect a partially stopped pair: SQM must wait for the owned IFB
	# redirect to be removed even if the upload root was already replaced.
	[ -f /var/run/c2000max-nrqos/down-session ] && return 0
	tc qdisc show dev ifb-nrqos 2>/dev/null | grep -q '^qdisc cake 366: root'
}

# Do not config_load here: callers can be iterating EQoS or network sections.
c2000_sqm_enabled()
{
	local section state
	# LuCI/procd may reload acceleration before SQM has removed its old
	# qdiscs. Keep offload and EQoS suspended until teardown finishes too.
	for state in "${C2000MAX_SQM_STATE_DIR:-/var/run/sqm}"/*.state; do
		[ ! -f "$state" ] || return 0
	done
	for section in $(uci -q show sqm 2>/dev/null |
		sed -n 's/^sqm\.\([^.=]*\)=queue$/\1/p'); do
		case "$(uci -q get "sqm.$section.enabled")" in
			1|on|true|yes) return 0 ;;
		esac
	done
	return 1
}
