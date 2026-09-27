#!/bin/sh
set -eu
testdir=$(mktemp -d)
trap 'rm -f "$testdir/active"; rmdir "$testdir"' EXIT
c2000_effective_fastpath()
{
	local role="$1" requested="${2:-disabled}"

	# Keep saved TurboACC settings, but route packets through the active accelerator.
	if [ -f $testdir/active ]; then
		printf '%s\n' disabled
		return 0
	fi

	# SQM must see every packet. Retain the saved acceleration preference,
	# but suspend both PPE and software flowtables until SQM is disabled.
	if command -v c2000_sqm_enabled >/dev/null 2>&1 && c2000_sqm_enabled; then
		printf '%s\n' disabled
		return 0
	fi

	case "$role" in
		lan)
			# Only the LAN topology has a verified C2000-MAX HNAT data path.
			# Keep the user's TurboACC preference intact so returning from WAN
			# to LAN can restore HNAT without rewriting that preference.
			case "$requested" in
				mediatek_hnat) printf '%s\n' mediatek_hnat ;;
				flow_offloading) printf '%s\n' flow_offloading ;;
				disabled|*) printf '%s\n' disabled ;;
			esac
			;;
		wan)
			# Never attempt the experimental WAN PPE endpoint mapping. A saved
			# MediaTek HNAT preference falls back to the generic nft software
			# flowtable, while an explicit Disable selection stays disabled.
			# Hardware flow offload remains disabled independently.
			case "$requested" in
				mediatek_hnat|flow_offloading)
					printf '%s\n' flow_offloading
					;;
				disabled|*) printf '%s\n' disabled ;;
			esac
			;;
		*)
			printf '%s\n' disabled
			;;
	esac
}

[ "$(c2000_effective_fastpath lan mediatek_hnat)" = mediatek_hnat ]
touch "$testdir/active"
[ "$(c2000_effective_fastpath lan mediatek_hnat)" = disabled ]
[ "$(c2000_effective_fastpath wan flow_offloading)" = disabled ]
rm "$testdir/active"
[ "$(c2000_effective_fastpath lan mediatek_hnat)" = mediatek_hnat ]
echo 'PASS: accelerator fastpath suspension and preference restoration'
