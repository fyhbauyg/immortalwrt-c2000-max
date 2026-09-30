#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export C2000MAX_SIM_LIBRARY_ONLY=1 C2000MAX_SIM_SKIP_REDIAL=1
source "$ROOT/files/usr/sbin/c2000max-sim"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
GPIO_SIM="$tmp/gpio" GPIO_POWER="$tmp/power" SHUTDOWN_MARKER="$tmp/shutdown"
echo 1 > "$GPIO_SIM"; echo 1 > "$GPIO_POWER"
log() { :; }
sleep() {
	printf 'sleep:%s\n' "$1" >> "$tmp/events"
	if [[ "$shutdown_during_sleep" == 1 ]]; then : > "$SHUTDOWN_MARKER"; fi
}
first_qmodem_section() { echo modem; }
resolve_port() { echo /dev/null; }
resolve_model() { echo FM150AE; }
resolve_vendor() { echo fibocom; }
begin_at_transaction() {
	printf 'begin:%s\n' "$1" >> "$tmp/events"
	AT_TRANSACTION_PORT="$1" AT_TRANSACTION_HELD=1
}
end_at_transaction() {
	printf 'end\n' >> "$tmp/events"
	AT_TRANSACTION_PORT= AT_TRANSACTION_HELD=0
}
qmodem_at_daemon_close() { printf 'close:%s\n' "$1" >> "$tmp/events"; }
wait_for_modem_ready() {
	[[ "$AT_TRANSACTION_HELD" == 0 ]] || { echo 'old transaction held during probing' >&2; return 1; }
	echo /dev/ttyUSB2
}
write_modem_power() {
	printf 'power:%s\n' "$1" >> "$tmp/events"
	echo "$1" > "$GPIO_POWER"
}
write_gpio_mux() {
	[[ "$(cat "$GPIO_POWER")" == 0 ]] || { echo 'mux changed while powered' >&2; return 1; }
	printf 'gpio:%s\n' "$1" >> "$tmp/events"
	if [[ "$fail_gpio" == 1 ]]; then return 1; fi
	echo "$1" > "$GPIO_SIM"
}
uci() { printf '%s\n' "$*" >> "$tmp/uci"; }
query_cpin() { echo "$FAKE_CPIN"; }
query_iccid() {
	if [[ "$AT_TRANSACTION_PORT" == /dev/ttyUSB2 ]]; then echo "$FAKE_AFTER"; else echo 8986000000000000001; fi
}
reset_case() {
	: > "$tmp/events"; : > "$tmp/uci"; rm -f "$SHUTDOWN_MARKER"
	echo 1 > "$GPIO_SIM"; echo 1 > "$GPIO_POWER"
	AT_TRANSACTION_PORT= AT_TRANSACTION_HELD=0 SIM_LOCK_HELD=0
	MODEM_POWER_CYCLE_ACTIVE=0 LAST_ERROR= fail_gpio=0 shutdown_during_sleep=0
	FAKE_CPIN=READY FAKE_AFTER=8986010000000000002
}
reset_case
force_gpio_slot external1
[[ "$(cat "$GPIO_SIM")" == 0 && "$(cat "$GPIO_POWER")" == 1 ]]
grep -q 'last_force_verification=changed' "$tmp/uci"
[[ "$SWITCH_MESSAGE" == *'已确认换卡'* ]]
expected=$'begin:/dev/null\nclose:/dev/null\npower:0\nsleep:8\ngpio:0\nsleep:1\npower:1\nend\nbegin:/dev/ttyUSB2'
[[ "$(cat "$tmp/events")" == "$expected" ]]
[[ "$MODEM_RESTARTED_PORT" == /dev/ttyUSB2 ]]

reset_case
FAKE_AFTER=8986000000000000001
force_gpio_slot external1
grep -q 'last_force_verification=unchanged' "$tmp/uci"
[[ "$SWITCH_MESSAGE" == *'未确认换卡'* && "$SWITCH_MESSAGE" != *'已确认换卡'* ]]

reset_case
FAKE_CPIN='SIM PIN'
force_gpio_slot external1
grep -q 'last_force_verification=unavailable' "$tmp/uci"

reset_case
fail_gpio=1
if power_cycle_mux 0; then echo 'FAIL: failed GPIO accepted'; exit 1; fi
[[ "$(cat "$GPIO_POWER")" == 1 ]]

reset_case
shutdown_during_sleep=1
if power_cycle_mux 0; then echo 'FAIL: shutdown ignored'; exit 1; fi
[[ "$(cat "$GPIO_POWER")" == 0 ]]
cleanup_locks
[[ "$(cat "$GPIO_POWER")" == 0 ]]

reset_case
if force_gpio_slot internal; then echo 'FAIL: invalid GPIO selector accepted'; exit 1; fi
[[ ! -s "$tmp/events" ]]
echo 'PASS: GPIO changes only while powered off, fresh AT port, ICCID verification, power recovery and shutdown priority'
