#!/bin/sh
# Read-only IPv6 forwarding diagnosis; no AT commands or service/config changes.
section="${1:-2_1}"
pc_address="${2:-}"
case "$section" in ''|*[!A-Za-z0-9_]*) echo 'Invalid section' >&2; exit 1 ;; esac
case "$pc_address" in *[!0-9A-Fa-f:]*) echo 'Invalid PC IPv6 address' >&2; exit 1 ;; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root' >&2; exit 1; }
[ "$(uci -q get "qmodem.$section")" = modem-device ] || exit 1
alias=$(uci -q get "qmodem.$section.alias")
interface="${alias:-$section}"
case "$interface" in ''|*[!A-Za-z0-9_.-]*) echo 'Invalid interface alias' >&2; exit 1 ;; esac
wan6="${interface}v6"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
out="/tmp/sim8260-ipv6-$stamp"
umask 077
mkdir "$out" || exit 1
ubus call "network.interface.$wan6" status > "$out/wan6-status.txt" 2>&1
wan=$(jq -r '.l3_device // .device // empty' "$out/wan6-status.txt" 2>/dev/null)
case "$wan" in ''|*[!A-Za-z0-9_.:-]*) wan='' ;; esac
if [ -z "$wan" ]; then
    for device in $(uci -q get "qmodem.$section.network"); do
        case "$device" in *[!A-Za-z0-9_.:-]*) continue ;; esac
        [ -d "/sys/class/net/$device" ] && { wan="$device"; break; }
    done
fi
lan=$(uci -q get network.lan.device)
[ -n "$lan" ] || lan=br-lan
case "$lan" in *[!A-Za-z0-9_.:-]*) echo 'Invalid LAN device' >&2; exit 1 ;; esac
redact() {
    sed -E '/[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|ppp_auth|CGAUTH=|MGAUTH=/d; s/[0-9]{15,22}/[redacted-id]/g'
}
options() {
    package="$1" name="$2"; shift 2
    for key in "$@"; do
        value=$(uci -q get "$package.$name.$key") || value='<unset>'
        printf '%s.%s.%s=%s\n' "$package" "$name" "$key" "$value"
    done
}
{
    date; uptime; uname -a
    echo "section=$section wan6=$wan6 wan=$wan lan=$lan pc=$pc_address"
    options qmodem "$section" name alias network pdp_type ra_master extend_prefix
    for name in $(uci -q show network | sed -n 's/^network\.\([^=]*\)=interface$/\1/p'); do
        options network "$name" proto device ifname ip6addr ip6gw ip6assign ip6hint ip6class ip6ifaceid delegate extendprefix reqaddress reqprefix defaultroute sourcefilter metric mtu
    done
    for name in $(uci -q show dhcp | sed -n 's/^dhcp\.\([^=]*\)=dhcp$/\1/p'); do
        options dhcp "$name" interface master ra dhcpv6 ndp ignore ndproxy_routing ndproxy_slave ra_default ra_flags ra_slaac ra_offlink ra_lifetime ra_mtu ra_useleasetime max_preferred_lifetime max_valid_lifetime prefix_filter
    done
    options dhcp odhcpd loglevel piodir leasefile
    for name in $(uci -q show firewall | sed -n 's/^firewall\.\([^=]*\)=\(zone\|forwarding\)$/\1/p'); do
        options firewall "$name" name network src dest input output forward family masq masq6 mtu_fix
    done
} | redact > "$out/config.txt"
snapshot() {
    label="$1"
    {
        date
        ip -6 address
        ip -6 route show table all
        ip -6 rule
        ip -6 neigh show
        ip -6 neigh show proxy
        if [ -n "$pc_address" ]; then
            ip -6 route get 2408:8888::8 from "$pc_address" iif "$lan"
        fi
        for device in all default "$lan" "$wan"; do
            [ -n "$device" ] || continue
            for key in forwarding proxy_ndp accept_ra; do
                path="/proc/sys/net/ipv6/conf/$device/$key"
                [ -r "$path" ] && { printf '%s=' "$path"; cat "$path"; }
            done
        done
        ubus call network.interface dump
        ubus call dhcp ipv6leases
        ubus call dhcp ipv6ra
        ubus call service list '{"name":"odhcpd"}'
    } > "$out/state-$label.txt" 2>&1
    nft -a list ruleset 2>&1 | head -c 1048576 > "$out/firewall-$label.txt"
}
snapshot before
capture_pids=''
if command -v tcpdump >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    tcpdump --version > "$out/tcpdump-version.txt" 2>&1
    if [ "$?" = 0 ]; then
        for device in "$lan" "$wan"; do
            [ -n "$device" ] && [ -d "/sys/class/net/$device" ] || continue
            # Headers only: ICMPv6 includes NDP/RA, echo and PMTU messages.
            timeout 40 tcpdump -ni "$device" -tttt -v -s 128 -c 250 \
                'icmp6 or (ip6 and udp and (port 546 or port 547))' \
                > "$out/capture-$device.txt" 2>&1 &
            capture_pids="$capture_pids $!"
        done
    fi
fi
if [ -n "$capture_pids" ]; then
    echo 'Capturing LAN and modem IPv6 headers for up to 40 seconds.'
    echo 'Run the Windows IPv6 ping/source-address tests now.'
else
    echo 'Packet capture unavailable; collecting configuration and router tests.'
fi
{
    date
    if [ -n "$wan" ]; then
        ping -6 -I "$wan" -c 2 -W 2 2408:8888::8
        ping -6 -I "$wan" -c 2 -W 2 2606:4700:4700::1111
    fi
    lan_address=$(ip -6 -o address show dev "$lan" scope global | awk '$4 ~ /^[23]/ {split($4,a,"/"); print a[1]; exit}')
    if [ -n "$lan_address" ]; then
        echo "Test using router LAN source address: $lan_address"
        ping -6 -I "$lan_address" -c 2 -W 2 2408:8888::8
    fi
} > "$out/router-tests.txt" 2>&1
for pid in $capture_pids; do wait "$pid"; done
snapshot after
logread | tail -250 | redact > "$out/logread.txt"
archive="$out.tar.gz"
tar -czf "$archive" -C /tmp "${out##*/}" || exit 1
chmod 600 "$archive"
echo "Diagnostic archive: $archive"
