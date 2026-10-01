#!/bin/sh
# Temporary, scoped NAT6 comparison. No UCI, AT or service changes.
set -e
section="${1:-2_1}"
pc="${2:-}"
case "$section" in ''|*[!A-Za-z0-9_]*) echo 'Invalid modem section' >&2; exit 1 ;; esac
case "$pc" in *[!0-9A-Fa-f:]*) echo 'Invalid PC IPv6 address' >&2; exit 1 ;; esac
if [ -n "$pc" ]; then
    case "$pc" in [23]*:*) ;; *) echo 'Use the current public PC IPv6 address' >&2; exit 1 ;; esac
fi
[ "$(id -u)" = 0 ] || { echo 'Run as root' >&2; exit 1; }
[ "$(cat /tmp/sysinfo/board_name)" = nradio,c2000-max ] || { echo 'Wrong board' >&2; exit 1; }
[ "$(uci -q get "qmodem.$section")" = modem-device ] || exit 1
case "$(uci -q get "qmodem.$section.name")" in simcom_sim8260g-m2|sim8260g-m2) ;; *) echo 'Wrong modem model' >&2; exit 1 ;; esac
for command in nft jq ubus ip ping tar sha256sum; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
existing=$(nft list tables)
if printf '%s\n' "$existing" | awk '$1 == "table" && $2 == "ip6" && $3 ~ /^c2000max_s8260_probe_/ {found=1} END {exit !found}'; then
    echo 'Another NAT6 probe is active; wait 90 seconds before retrying.' >&2
    exit 1
fi
alias=$(uci -q get "qmodem.$section.alias" || true)
wan6="${alias:-$section}v6"
case "$wan6" in *[!A-Za-z0-9_.-]*) echo 'Invalid WAN6 alias' >&2; exit 1 ;; esac
umask 077
stamp="$(date +%Y%m%d-%H%M%S)-$$"
out="/tmp/sim8260-nat6-$stamp"
mkdir "$out"
table="c2000max_s8260_probe_$(date +%s)_$$"
owned=0
capture_pids=''
finish() {
    rc=$?
    trap - 0 1 2 15
    for pid in $capture_pids; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
    if [ "$owned" = 1 ]; then
        nft -a list table ip6 "$table" > "$out/nat6-final.txt" 2>&1 || true
        if nft list table ip6 "$table" >/dev/null 2>&1; then
            if nft delete table ip6 "$table"; then
                echo 'Temporary NAT6 rules removed.'
            else
                echo "Removal failed. Run: nft delete table ip6 $table" >&2
                rc=1
            fi
        else
            echo 'Temporary NAT6 table is already absent.'
        fi
    fi
    nft list tables > "$out/tables-after.txt" 2>&1 || true
    ubus call "network.interface.$wan6" status > "$out/wan6-after.txt" 2>&1 || true
    sha256sum /etc/config/dhcp /etc/config/network /etc/config/qmodem /etc/config/firewall > "$out/config-hashes-after.txt" 2>&1 || true
    if tar -czf "$out.tar.gz" -C /tmp "${out##*/}"; then
        chmod 600 "$out.tar.gz"
        echo "Diagnostic archive: $out.tar.gz"
    else
        rc=1
    fi
    exit "$rc"
}
trap finish 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15
ubus call "network.interface.$wan6" status > "$out/wan6-before.txt"
jq -e '.up == true' "$out/wan6-before.txt" >/dev/null || { echo 'WAN6 is not up' >&2; exit 1; }
wan=$(jq -r '.l3_device // .device // empty' "$out/wan6-before.txt")
wan_address=$(jq -r '(."ipv6-address" // []) | map(select((.address | startswith("2") or startswith("3")) and ((.preferred // 1) > 0))) | .[0].address // empty' "$out/wan6-before.txt")
case "$wan" in ''|*[!A-Za-z0-9_.:-]*) echo 'Invalid WAN device' >&2; exit 1 ;; esac
case "$wan_address" in ''|*[!0-9A-Fa-f:]*) echo 'No public WAN IPv6 address' >&2; exit 1 ;; esac
[ -d "/sys/class/net/$wan" ] || exit 1
matched=0
for device in $(uci -q get "qmodem.$section.network"); do [ "$wan" != "$device" ] || matched=1; done
[ "$matched" = 1 ] || { echo 'WAN6 is not the selected modem network device' >&2; exit 1; }
lan=$(uci -q get network.lan.device || true)
[ -n "$lan" ] || lan=br-lan
case "$lan" in *[!A-Za-z0-9_.:-]*) echo 'Invalid LAN device' >&2; exit 1 ;; esac
lan_address=$(ip -6 -o address show dev "$lan" scope global | awk '$4 ~ /^[23]/ && $0 !~ /deprecated|tentative|dadfailed/ {split($4,a,"/"); print a[1]; exit}')
case "$lan_address" in ''|*[!0-9A-Fa-f:]*) echo 'No public LAN IPv6 address' >&2; exit 1 ;; esac
[ "$lan_address" != "$wan_address" ] || exit 1
[ "$pc" != "$wan_address" ] || { echo 'PC address equals the router WAN address' >&2; exit 1; }
{
    date; uptime
    echo "section=$section wan6=$wan6 wan=$wan lan=$lan pc=$pc"
    echo "WAN_source=$wan_address LAN_source=$lan_address"
    uci -q show "dhcp.$wan6" || true
    for key in ra dhcpv6 ndp ra_slaac; do
        printf 'dhcp.lan.%s=' "$key"; uci -q get "dhcp.lan.$key" || true
    done
    for device in "$wan" "$lan"; do
        for key in forwarding proxy_ndp; do
            path="/proc/sys/net/ipv6/conf/$device/$key"
            [ ! -r "$path" ] || { printf '%s=' "$path"; cat "$path"; }
        done
    done
    ubus call service list '{"name":"odhcpd"}'
    ip -6 address; ip -6 route show table all; ip -6 rule; ip -6 neigh show; ip -6 neigh show proxy
} > "$out/state-before.txt" 2>&1
sha256sum /etc/config/dhcp /etc/config/network /etc/config/qmodem /etc/config/firewall > "$out/config-hashes-before.txt"
nft -a list ruleset | head -c 1048576 > "$out/firewall-before.txt"
router_test() {
    source_address="$1" label="$2"
    result=0
    {
        date; echo "label=$label source=$source_address"
        for target in 2408:8888::8 2606:4700:4700::1111; do
            if ping -6 -I "$source_address" -c 2 -W 2 "$target"; then result=$((result+1)); fi
        done
        echo "successful_targets=$result"
    } > "$out/router-$label.txt" 2>&1
    echo "$label: $result / 2 targets replied"
}
router_test "$wan_address" WAN-before
[ "$result" -gt 0 ] || { echo 'WAN IPv6 baseline failed; NAT6 test cancelled.' >&2; exit 1; }
router_test "$lan_address" LAN-before
cat > "$out/trial.nft" <<RULES
table ip6 $table {
    chain postrouting {
        type nat hook postrouting priority 105; policy accept;
        oifname "$wan" ip6 saddr $lan_address ip6 daddr { 2408:8888::8, 2606:4700:4700::1111 } meta l4proto ipv6-icmp counter snat to $wan_address
RULES
if [ -n "$pc" ]; then
    cat >> "$out/trial.nft" <<RULES
        iifname "$lan" oifname "$wan" ip6 saddr $pc ip6 daddr { 2408:8888::8, 2606:4700:4700::1111 } meta l4proto ipv6-icmp counter snat to $wan_address
        iifname "$lan" oifname "$wan" ip6 saddr $pc tcp dport 443 counter snat to $wan_address
RULES
fi
printf '%s\n' '    }' '}' >> "$out/trial.nft"
nft -c -f "$out/trial.nft" > "$out/nft-check.txt" 2>&1 || { cat "$out/nft-check.txt" >&2; exit 1; }
if command -v timeout >/dev/null && command -v tcpdump >/dev/null && tcpdump --version >/dev/null 2>&1; then
    for device in "$lan" "$wan"; do
        filter='icmp6'
        if [ -n "$pc" ]; then
            capture_address="$pc"; [ "$device" != "$wan" ] || capture_address="$wan_address"
            filter="icmp6 or (ip6 and tcp and host $capture_address and port 443)"
        fi
        timeout 75 tcpdump -ni "$device" -tttt -v -s 128 -c 250 "$filter" > "$out/capture-$device.txt" 2>&1 &
        capture_pids="$capture_pids $!"
    done
fi
owned=1
nft -f "$out/trial.nft"
# Independent delayed removal also survives an abrupt loss of the parent shell.
( sleep 90; nft delete table ip6 "$table" ) </dev/null >/dev/null 2>&1 &
echo "Manual removal: nft delete table ip6 $table"
router_test "$lan_address" LAN-SNAT
if [ -n "$pc" ]; then
    echo "NAT6 trial ACTIVE for 60 seconds: use PC source $pc for a fresh ping and HTTPS test now."
    sleep 60
fi
nft -a list table ip6 "$table" > "$out/nat6-counters.txt" 2>&1 || true
ip -6 route show table all > "$out/routes-after.txt" 2>&1
ip -6 neigh show > "$out/neighbours-after.txt" 2>&1
