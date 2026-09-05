#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOP=$(cd "$ROOT/../../.." && pwd)
export C2000_NETCHECK_SOURCE_ONLY=1
source "$ROOT/files/usr/sbin/c2000max-netcheck"
result=$(printf 'lan\t192.168.0.1\t24\nwan\t192.168.0.2\t24\n' | check_overlap)
[[ "$result" == *WARNING* ]] || { echo 'overlap was not detected'; exit 1; }
result=$(printf 'lan\t192.168.0.1\t24\nwan\t10.108.97.224\t8\n' | check_overlap)
[[ -z "$result" ]] || { echo 'non-overlap reported'; exit 1; }
result=$(printf 'lan\t192.168.0.1\t16\nwan\t192.168.66.2\t24\n' | check_overlap)
[[ "$result" == *WARNING* ]] || exit 1
source "$ROOT/files/usr/lib/c2000max/qos-compat.sh"
test_state=$(mktemp -d)
trap 'rm -f "$test_state/eth2.state"; rmdir "$test_state"' EXIT
export C2000MAX_SQM_STATE_DIR="$test_state"
SQM=0
uci() {
	[[ "$1" == -q ]] && shift
	case "$1:$2" in
	 show:sqm) printf "sqm.nr_game=queue\nsqm.nr_game.enabled='%s'\n" "$SQM" ;;
	 get:sqm.nr_game.enabled) echo "$SQM" ;;
	 *) return 1 ;;
	esac
}
source "$ROOT/files/usr/lib/c2000max/port-role.sh"
[[ "$(c2000_effective_fastpath lan mediatek_hnat)" == mediatek_hnat ]]
# Configuration is already disabled while stop-sqm is still tearing down.
touch "$test_state/eth2.state"
[[ "$(c2000_effective_fastpath lan mediatek_hnat)" == disabled ]]
[[ "$(c2000_effective_fastpath wan flow_offloading)" == disabled ]]
rm "$test_state/eth2.state"
[[ "$(c2000_effective_fastpath lan mediatek_hnat)" == mediatek_hnat ]]
SQM=1
[[ "$(c2000_effective_fastpath lan mediatek_hnat)" == disabled ]]
[[ "$(c2000_effective_fastpath wan mediatek_hnat)" == disabled ]]
[[ "$(c2000_effective_fastpath lan flow_offloading)" == disabled ]]
SQM=0
[[ "$(c2000_effective_fastpath wan mediatek_hnat)" == flow_offloading ]]
[[ "$(c2000_effective_fastpath lan mediatek_hnat)" == mediatek_hnat ]]
# Parse every exposed flash partition, not just one label.
awk '
 /partition@[0-9a-f]+ \{/ { inside=1; ro=0; count++ }
 inside && /read-only;/ { ro=1 }
 inside && /};/ { if(!ro) exit 1; inside=0 }
 END { if(count!=5) exit 1 }
' "$TOP/target/linux/mediatek/dts/mt7987a-nradio-c2000-max.dts"
# Extract and execute the entry functions with destructive primitives mocked.
helper="$ROOT/files/usr/sbin/c2000max-boot-official-once"
source <(sed -n '/^status_json() {/,/^}/p; /^arm_once() {/,/^}/p' "$helper")
json_result() { [[ "$1:$2" == 0:0 ]]; }
make_env_config() { echo 'ERROR: entered SPI path' >&2; return 99; }
status_json
if arm_once 1; then echo 'unsafe reboot was accepted'; exit 1; fi
for script in "$ROOT/files/usr/sbin/c2000max-netcheck" "$ROOT/files/usr/sbin/c2000max-sqm-prepare"; do sh -n "$script"; done
echo 'v36.5 overlap, SQM mutual exclusion, restoration and SPI safety tests passed'
