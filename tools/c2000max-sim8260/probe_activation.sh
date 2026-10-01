#!/bin/sh
# Capture one SIM8260 data-link activation while its own retry loop is paused.
# Uses the existing AT queue; preserves APN, PDP, USB and modem settings.
section="${1:-2_1}"
case "$section" in ''|*[!A-Za-z0-9_]*) echo 'Invalid section' >&2; exit 1 ;; esac
[ "$(id -u)" = 0 ] || exit 1
[ "$(uci -q get "qmodem.$section")" = modem-device ] || exit 1
model=$(uci -q get "qmodem.$section.name")
case "$model" in simcom_sim8260g-m2|sim8260g-m2) ;; *) echo 'Install the SIM8260 patch first' >&2; exit 1 ;; esac
modem_config="$section"
config_section="$section"
at_port=$(uci -q get "qmodem.$section.override_at_port")
[ -n "$at_port" ] || at_port=$(uci -q get "qmodem.$section.at_port")
case "$at_port" in /dev/ttyUSB[0-9]*) ;; *) exit 1 ;; esac
[ -c "$at_port" ] || exit 1
. /usr/share/qmodem/modem_util.sh
QMODEM_AT_LOCK_WAIT=10
export QMODEM_AT_LOCK_WAIT
out="/tmp/sim8260-activation-$(date +%Y%m%d-%H%M%S)-$$.txt"
umask 077
redact() {
    sed -E '/[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|ppp_auth|CGAUTH=|MGAUTH=/d; s/[0-9]{15,22}/[redacted-id]/g'
}
service_state() {
    snapshot=$(ubus call service list '{"name":"qmodem_network"}' 2>/dev/null) || return 2
    printf '%s\n' "$snapshot" | jq -e 'type == "object"' >/dev/null 2>&1 || return 2
    printf '%s\n' "$snapshot" |
        jq -er --arg instance "modem_$section" '.qmodem_network.instances[$instance].running == true'
}
service_state >/dev/null 2>&1 || { echo 'Target dialer is not running; no changes made'; exit 1; }
{
    date; uptime; echo "section=$section port=$at_port"
    echo '--- Dial log before test'
    tail -100 "/var/run/qmodem/${section}_dir/dial_log" 2>/dev/null
} | redact > "$out"
restore=1
restore_failed=0
cleanup() {
    [ "$restore" = 1 ] || return
    restore=0
    echo '--- Restore target dialer' >> "$out"
    /etc/init.d/qmodem_network dial "$section" >> "$out" 2>&1
    rc=$?
    echo "restore_exit=$rc" >> "$out"
    if [ "$rc" != 0 ]; then
        restore_failed=1
        echo "Failed to restore dialer: /etc/init.d/qmodem_network dial $section" >&2
    fi
}
trap cleanup 0
trap 'exit 128' 1 2 15
{
    echo '--- Pause only the target dialer'
    timeout 25 /etc/init.d/qmodem_network hang "$section"
    echo "hang_exit=$?"
} >> "$out" 2>&1
service_state >/dev/null 2>&1
state_rc=$?
if [ "$state_rc" != 1 ]; then
    echo "Cannot confirm target dialer stopped (status=$state_rc); activation test skipped" >> "$out"
    cleanup
    echo "Diagnostic file: $out"
    exit 1
fi
query() {
    cmd="$1" seconds="${2:-6}"
    started=$(date +%s)
    response=$(at_timeout "$at_port" "$cmd" "$seconds" 2>&1)
    rc=$?
    elapsed=$(( $(date +%s) - started ))
    {
        echo "--- command=$cmd timeout=$seconds"
        printf '%s\n' "$response"
        echo "exit=$rc elapsed=$elapsed"
    } | redact >> "$out"
}
query 'AT+NETACT?'
query 'AT+CGCONTRDP=1'
query 'AT+CGCONTRDP=6'
query 'AT+CEER'
query 'AT+NETACT=1' 30
query 'AT+NETACT?'
query 'AT+CEER'
echo '--- Waiting 20 seconds for data-link state' >> "$out"
sleep 20
for cmd in 'AT+NETACT?' 'AT+CAPNET?' 'AT+CGPADDR=6' 'AT+CQCMAP="WWAN"' 'AT+CEER'; do
    query "$cmd"
done
cleanup
if [ "$restore_failed" != 0 ]; then
    echo '--- Host test skipped because restoring the target dialer failed' >> "$out"
    echo "Diagnostic file: $out"
    exit 1
fi
echo '--- Waiting 20 seconds after restoring the target dialer' >> "$out"
sleep 20
service_state >/dev/null 2>&1
state_rc=$?
if [ "$state_rc" != 0 ]; then
    echo "--- Host test skipped: target dialer is not confirmed running (status=$state_rc)" >> "$out"
    echo "Diagnostic file: $out"
    exit 1
fi
{
    echo '--- Host connectivity after restoring target dialer'
    devices=$(uci -q get "qmodem.$section.network")
    for dev in $devices; do
        [ -d "/sys/class/net/$dev" ] || continue
        ip address show dev "$dev"
        ping -I "$dev" -c 2 -W 2 1.1.1.1
    done
    ip route
    timeout 8 nslookup example.com
} | redact >> "$out" 2>&1
trap - 0 1 2 15
echo "Diagnostic file: $out"
[ "$restore_failed" = 0 ]
