#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export C2000MAX_SIM_LIBRARY_ONLY=1
source "$ROOT/files/usr/sbin/c2000max-sim"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sleep() { :; }
write_gpio_mux() { echo "$1" > "$tmp/gpio"; }
read_gpio_mux() { cat "$tmp/gpio"; }
send_at() {
    echo "$2" >> "$tmp/calls"
    case "$2" in
        'AT^SIMSLOT=?') [ "$support" = 1 ] && echo '^SIMSLOT: (1-2)' || echo ERROR ;;
        'AT^SIMSLOT?')
            [ "$(cat "$tmp/slot")" = 1 ] && echo '^SIMSLOT: 1,1,1,0' || echo '^SIMSLOT: 1,0,1,1' ;;
        AT^SIMSLOT=*)
            [ "$accept" = 0 ] || echo "${2#*=}" > "$tmp/slot"
            echo OK ;;
        AT+CFUN=*) echo OK ;;
        *) echo ERROR ;;
    esac
}
support=1 accept=1
echo 1 > "$tmp/slot"; echo 1 > "$tmp/gpio"
switch_meig /dev/mock 2 0
[ "$(cat "$tmp/slot")" = 2 ] && [ "$(cat "$tmp/gpio")" = 0 ]
# A modem can acknowledge a disabled custom feature without changing slots.
accept=0
if switch_meig /dev/mock 1 1; then echo 'FAIL: accepted unchanged slot'; exit 1; fi
[ "$(cat "$tmp/slot")" = 2 ] && [ "$(cat "$tmp/gpio")" = 0 ]
[ "$(tail -n 1 "$tmp/calls")" = AT+CFUN=1 ]
support=0
: > "$tmp/calls"
if switch_meig /dev/mock 1 1; then exit 1; fi
! grep -q 'AT+CFUN=' "$tmp/calls"
[ "$(cat "$tmp/gpio")" = 0 ]
echo 'PASS: MeiG route switch, no-op acknowledgement rollback, unsupported firmware has no writes'
