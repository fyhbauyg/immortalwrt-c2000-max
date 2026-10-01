#!/bin/sh
# Collect SIM8260 RNDIS state without changing USB mode, SIM, APN or restarting services.
set -u
section="${1:-2_1}"
case "$section" in ''|*[!A-Za-z0-9_]*) echo 'Invalid QModem section' >&2; exit 1 ;; esac
[ "$(uci -q get "qmodem.$section")" = modem-device ] || {
    echo "Missing qmodem.$section modem-device" >&2; exit 1;
}
port=$(uci -q get "qmodem.$section.override_at_port")
[ -n "$port" ] || port=$(uci -q get "qmodem.$section.at_port")
case "$port" in /dev/ttyUSB[0-9]*) ;; *) echo "Unexpected AT port: $port" >&2; exit 1 ;; esac
[ -c "$port" ] || { echo "AT port missing: $port" >&2; exit 1; }
stamp=$(date +%Y%m%d-%H%M%S)-$$
out="/tmp/sim8260-diag-$stamp"
mkdir -m 700 "$out" || exit 1
redact() {
    sed -E '/[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|ppp_auth|CGAUTH=|MGAUTH=/d; s/[0-9]{15,22}/[redacted-id]/g'
}
{
    date; uptime; uname -a
    cat /etc/c2000max-release /etc/openwrt_release 2>/dev/null
    echo "section=$section port=$port"
    for key in name manufacturer platform data_interface at_port override_at_port network modes state enable_dial suggest_pdp_index pdp_index pdp_type apn apn2 use_ubus at_backend; do
        printf '%s=' "$key"; uci -q get "qmodem.$section.$key" || true
    done
    printf 'global_enable_dial='; uci -q get qmodem.main.enable_dial || true
} | redact > "$out/system-config.txt"
lsusb > "$out/lsusb.txt" 2>&1
lsusb -t > "$out/usb-tree.txt" 2>&1
{
    for dev in /sys/bus/usb/devices/*; do
        [ "$(cat "$dev/idVendor" 2>/dev/null)" = 1e0e ] || continue
        echo "USB: $dev"
        for field in idVendor idProduct product manufacturer speed authorized; do
            printf '%s=' "$field"; cat "$dev/$field" 2>/dev/null || true
        done
        find "$dev/" -maxdepth 6 -name net -o -name 'ttyUSB*' -o -name driver 2>/dev/null
    done
    for dev in /sys/class/tty/ttyUSB*; do
        echo "$dev -> $(readlink -f "$dev/device")"
    done
} > "$out/sysfs.txt" 2>&1
{
    ip -details link; ip address; ip route show table all; ip -6 route show table all
    ubus call network.interface dump
    for service in qmodem_init qmodem_network ubus-at-daemon; do
        ubus call service list "{\"name\":\"$service\"}"
    done
    ps w
} | redact > "$out/network-services.txt" 2>&1
# Dialer diagnostics are stored here rather than in logread.
tail -150 "/var/run/qmodem/${section}_dir/dial_log" 2>/dev/null | redact > "$out/dial-log.txt"
sha256sum /usr/share/qmodem/modem_dial.sh /usr/share/qmodem/simcom_network.sh \
    /usr/share/qmodem/vendor/simcom.sh 2>/dev/null > "$out/installed-files.txt"
logread | tail -450 | redact > "$out/logread.txt"
dmesg | tail -250 | redact > "$out/dmesg.txt"
cat > "$out/query.sh" <<'QUERY'
#!/bin/sh
modem_config="$1"
config_section="$1"
at_port="$2"
use_ubus=$(uci -q get "qmodem.$modem_config.use_ubus")
manufacturer=$(uci -q get "qmodem.$modem_config.manufacturer")
platform=$(uci -q get "qmodem.$modem_config.platform")
. /usr/share/qmodem/modem_util.sh
QMODEM_AT_LOCK_WAIT=2
export QMODEM_AT_LOCK_WAIT
at_timeout "$at_port" "$3" 6
QUERY
index=0
for cmd in 'ATI' 'AT+CGMM' 'AT+CGMI' 'AT+CGMR' 'AT+SIMCOMATI' \
    'AT+CUSBCFG?' 'AT+CPIN?' 'AT+CFUN?' 'AT+CEREG?' 'AT+C5GREG?' \
    'AT+CGATT?' 'AT+CGDCONT?' 'AT+CGACT?' 'AT+CGPADDR' \
    'AT+NETACT?' 'AT+CAPNET?' 'AT+CQCMAP="WWAN"' \
    'AT+CQCMAP="MPDN_rule"' 'AT+CQCMAP="auto_connect"' 'AT+CPSI?'; do
    index=$((index+1))
    file=$(printf '%s/at-%02d.txt' "$out" "$index")
    echo "[$index/20] $cmd"
    printf 'command=%s\n' "$cmd" > "$file"
    timeout 15 sh "$out/query.sh" "$section" "$port" "$cmd" > "$out/raw.tmp" 2>&1
    rc=$?
    redact < "$out/raw.tmp" >> "$file"
    echo "exit=$rc" >> "$file"
done
rm -f "$out/raw.tmp" "$out/query.sh"
{
    devices=$(uci -q get "qmodem.$section.network")
    for dev in $devices; do
        [ -d "/sys/class/net/$dev" ] || continue
        echo "RNDIS device: $dev"
        ip address show dev "$dev"
        ping -I "$dev" -c 2 -W 2 1.1.1.1
    done
    timeout 8 nslookup example.com
} > "$out/connectivity.txt" 2>&1
archive="$out.tar.gz"
tar -czf "$archive" -C /tmp "${out##*/}" || exit 1
chmod 600 "$archive"
echo "Diagnostic archive: $archive"
