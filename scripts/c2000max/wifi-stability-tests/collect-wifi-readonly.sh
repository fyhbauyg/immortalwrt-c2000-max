#!/bin/sh
# One bounded snapshot. No debug writes, UCI commits, service reloads or traffic.
# Run by SSH; keep output private because station MAC/IP addresses are included.
set -u
board=$(cat /tmp/sysinfo/board_name 2>/dev/null)
[ "$board" = nradio,c2000-max ] || { echo 'Not C2000MAX; stopped.' >&2; exit 2; }
command -v timeout >/dev/null 2>&1 || { echo 'timeout required' >&2; exit 2; }
bounded() { timeout 3 "$@"; }
echo 'C2000MAX Wi-Fi read-only snapshot 2026-09-12'
date -u
uname -a
cat /etc/openwrt_release /proc/uptime /proc/loadavg 2>/dev/null
cat /usr/share/c2000max-wifi-experimental/README.txt 2>/dev/null
for fw in /lib/firmware/WIFI_RAM_CODE_MT7993_1_1.bin /lib/firmware/WIFI_MT7993_PATCH_MCU_1_1_hdr.bin; do
    [ ! -f "$fw" ] || sha256sum "$fw"
done
# Strict whitelist. Do not expose SSID/password/key, SIM identifiers or tokens.
uci -q show wireless | grep -E '\.(channel|htmode|encryption|ieee80211w|disabled|type)='
for attr in /sys/module/mt7993/parameters/rro_mode /sys/module/mt7993/parameters/option_type; do
    [ ! -r "$attr" ] || { echo "$attr"; cat "$attr"; }
done
cat /proc/net/dev /proc/net/softnet_stat /proc/stat
grep -E '^(MemAvailable|MemFree|Slab|SUnreclaim):' /proc/meminfo
bounded tc -s qdisc show 2>/dev/null
for path in /sys/class/net/*; do
    dev=${path##*/}
    case "$dev" in
        ra[0-9]*|rai[0-9]*|rax[0-9]*|wlan[0-9]*)
            echo "STATION $dev (RX = client upload to AP)"
            bounded iw dev "$dev" station dump 2>/dev/null
            ;;
    esac
done
echo 'Kernel fault/recovery markers (not a full log)'
dmesg 2>/dev/null |
    grep -Ei 'mt799|WaitWM|ADDBA|DELBA|SER|WDMA|WED|reorder|ba_free|rcu_|RCU |Call Trace|WATCHDOG|out of memory|alloc.*fail|dma.*error|Polling.*timeout' |
    grep -Eiv 'GTK|IGTK|BIGTK|PTK|passphrase|password|psk|key material' | tail -n 100
echo 'END'
