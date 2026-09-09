#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${C2000MAX_SIM_TEST_SCRIPT:-$ROOT/files/usr/sbin/c2000max-sim}"
GATE="$ROOT/../qmodem/application/qmodem/files/usr/share/qmodem/c2000max_sim_gate.sh"
STATE_DIR="$(mktemp -d)"
trap 'rm -rf -- "$STATE_DIR"' EXIT

fail_test() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
	[[ "$1" == "$2" ]] || fail_test "$3: expected '$1', got '$2'"
}

export C2000MAX_SIM_LIBRARY_ONLY=1
# Library mode does not source OpenWrt libraries or run any main command.
source "$SCRIPT"
source "$GATE"

# Reproduce the installed BusyBox build's missing TR_CLASSES case folding.
# Keep the ordinary ASCII-range and CR/NUL handling on the real host tr.
tr() {
	if [[ "$*" == '[:upper:] [:lower:]' || "$*" == '[:lower:] [:upper:]' ]]; then
		cat
	else
		command tr "$@"
	fi
}
FAKE_VENDOR=auto
FAKE_MODEL=''
FAKE_MANUFACTURER=''
FAKE_AT_MODEL=MT5700M-CN
FAKE_AT_MANUFACTURER=TDTECH
FAKE_FIBOCOM='+GTDUALSIM: main'
uci() {
	[[ "$*" == '-q get c2000max.sim.vendor' ]] && printf '%s\n' "$FAKE_VENDOR"
	return 0
}
qmodem_get() {
	case "$2" in
		name) printf '%s\n' "$FAKE_MODEL" ;;
		manufacturer) printf '%s\n' "$FAKE_MANUFACTURER" ;;
	esac
	return 0
}
send_at() {
	printf '%s\n' "$2" >> "$STATE_DIR/at_commands"
	case "$2" in
		AT+CGMM) printf '%s\r\nOK\r\n' "$FAKE_AT_MODEL" ;;
		AT+CGMI) printf '%s\r\nOK\r\n' "$FAKE_AT_MANUFACTURER" ;;
		'AT+GTDUALSIM?') printf '%s\r\nOK\r\n' "$FAKE_FIBOCOM" ;;
		*) fail_test "unexpected mocked AT command: $2" ;;
	esac
}

assert_eq MT5700M-CN "$(printf MT5700M-CN | tr '[:upper:]' '[:lower:]')" 'trimmed BusyBox reproducer'
assert_eq mt5700m-cn "$(printf MT5700M-CN | tr A-Z a-z)" 'portable ASCII conversion'
model="$(resolve_model '' /dev/mock)"
assert_eq MT5700M-CN "$model" 'uncached AT identity'
assert_eq huawei "$(resolve_vendor '' /dev/mock "$model")" 'uncached uppercase MT5700 auto detection'
assert_eq huawei "$(resolve_vendor 2_1 /dev/mock mt5700m-cn)" 'cached lowercase identity'
assert_eq fibocom "$(resolve_vendor '' /dev/mock FM350-GL)" 'uppercase Fibocom model'
assert_eq quectel "$(resolve_vendor '' /dev/mock RM520N-GL)" 'uppercase Quectel model'
FAKE_AT_MANUFACTURER=HUAWEI
assert_eq huawei "$(resolve_vendor '' /dev/mock unknown-model)" 'CGMI uppercase manufacturer fallback'
FAKE_AT_MANUFACTURER=unknown
assert_eq unknown "$(resolve_vendor '' /dev/mock unknown-model)" 'unrecognized modem stays unsupported'
for FAKE_VENDOR in huawei fibocom quectel; do
	assert_eq "$FAKE_VENDOR" "$(resolve_vendor '' /dev/mock unknown-model)" 'explicit vendor override'
done
FAKE_VENDOR=auto
assert_eq 1 "$(query_fibocom_channel /dev/mock)" 'Fibocom lowercase MAIN fallback'
FAKE_FIBOCOM='+GTDUALSIM: sub'
assert_eq 2 "$(query_fibocom_channel /dev/mock)" 'Fibocom lowercase SUB fallback'

# A failed GPIO write may race shutdown. Recovery may restore power only if
# shutdown has not started; every GPIO/power operation below is a mock.
SHUTDOWN_MARKER="$STATE_DIR/shutdown"
C2000MAX_MODEM_POWER_OFF_SECONDS=2
FAIL_WITH_SHUTDOWN=0
log() { printf '%s\n' "$*" >> "$STATE_DIR/sim.log"; }
sleep() { :; }
write_modem_power() { printf '%s\n' "$1" >> "$STATE_DIR/power.log"; }
write_gpio_mux() {
	[[ "$FAIL_WITH_SHUTDOWN" != 1 ]] || : > "$SHUTDOWN_MARKER"
	return 1
}
if prepare_modem_boot external1; then
	fail_test 'GPIO failure was incorrectly accepted'
fi
assert_eq $'0\n1' "$(cat "$STATE_DIR/power.log")" 'non-shutdown GPIO failure restores modem power'
: > "$STATE_DIR/power.log"
FAIL_WITH_SHUTDOWN=1
if prepare_modem_boot external1; then
	fail_test 'shutdown-racing GPIO failure was incorrectly accepted'
fi
assert_eq 0 "$(cat "$STATE_DIR/power.log")" 'shutdown marker forbids recovery power-on'

PIDFILE="$STATE_DIR/boot.pid"
STATUSFILE="$STATE_DIR/boot.status"
PROCROOT="$STATE_DIR/proc"
mkdir -p "$PROCROOT/1234"
qmodem_sim_boot_log() { printf '%s\n' "$*" >> "$STATE_DIR/gate.log"; }
sleep() {
	[[ "$1" == 1 ]] || fail_test "unexpected gate sleep: $1"
	sleeps=$((sleeps + 1))
	if [[ "$release_after" -gt 0 && "$sleeps" -ge "$release_after" ]]; then
		printf 'ready\n' > "$STATUSFILE"
		rm -f -- "$PIDFILE"
	fi
}
reset_gate() {
	sleeps=0
	release_after=0
	printf '1234\n' > "$PIDFILE"
	printf 'pending\n' > "$STATUSFILE"
	printf '/bin/sh\0/etc/rc.common\0/etc/rc.d/S09c2000max-sim\0boot\0' > "$PROCROOT/1234/cmdline"
}
expect_gate_rc() {
	local expected="$1" label="$2" result=0
	qmodem_sim_boot_wait "$PIDFILE" "$STATUSFILE" "$PROCROOT" 3 || result=$?
	assert_eq "$expected" "$result" "$label"
}

reset_gate
rm -f -- "$PIDFILE" "$STATUSFILE"
expect_gate_rc 0 'no boot worker must not delay dial'
assert_eq 0 "$sleeps" 'no worker sleep count'

reset_gate
release_after=2
expect_gate_rc 0 'active worker completion releases dial'
assert_eq 2 "$sleeps" 'wait only until worker ends'

for terminal_state in pending ready failed; do
	reset_gate
	printf '%s\n' "$terminal_state" > "$STATUSFILE"
	expect_gate_rc 75 "live worker wins over $terminal_state marker"
	assert_eq 3 "$sleeps" 'live worker timeout is bounded'
done

reset_gate
printf 'failed\n' > "$STATUSFILE"
rm -f -- "$PIDFILE"
expect_gate_rc 0 'finished failure permits normal recovery'
assert_eq 0 "$sleeps" 'finished failure never waits'

reset_gate
printf '/usr/sbin/unrelated\0boot\0' > "$PROCROOT/1234/cmdline"
expect_gate_rc 0 'reused PID for unrelated process'
assert_eq 0 "$sleeps" 'reused PID does not block'

reset_gate
printf '/bin/sh\0/etc/init.d/c2000max-sim\0start\0' > "$PROCROOT/1234/cmdline"
expect_gate_rc 0 'manual start is not a boot worker'

reset_gate
printf '/bin/sh\0/etc/init.d/c2000max-sim\0boot\0' > "$PROCROOT/1234/cmdline"
expect_gate_rc 75 'direct init boot spelling remains recognized'

reset_gate
: > "$PROCROOT/1234/cmdline"
expect_gate_rc 0 'exited/zombie empty cmdline cannot hold gate'

reset_gate
printf 'not-a-pid\n' > "$PIDFILE"
expect_gate_rc 0 'malformed PID is harmless'

# The entrypoint must return the retry status before update_config, set_if,
# or any AT call. Check the actual candidate dial() prologue, not a duplicate.
DIAL="$ROOT/../qmodem/application/qmodem/files/usr/share/qmodem/modem_dial.sh"
prologue="$(sed -n '/^dial(){/,/^    update_config/p' "$DIAL")"
[[ "$prologue" == *'qmodem_wait_for_c2000max_sim_boot || return $?'* ]] ||
	fail_test 'dial entrypoint does not propagate the gate retry status'

# Run the real dial() body with only the gate replaced. No real modem code
# is sourced or invoked; touching update_config would make this test fail.
eval "$(sed -n '/^dial(){/,/^}/p' "$DIAL")"
SCRIPT_DIR="$STATE_DIR/dial-lib"
mkdir -p "$SCRIPT_DIR"
printf 'qmodem_wait_for_c2000max_sim_boot() { return 75; }\n' > "$SCRIPT_DIR/c2000max_sim_gate.sh"
update_config() { fail_test 'dial touched configuration before SIM gate released'; }
dial_rc=0
dial || dial_rc=$?
assert_eq 75 "$dial_rc" 'real dial entrypoint preserves retry status without side effects'

echo 'PASS: uppercase identity regression, vendor overrides, Fibocom fallback, bounded SIM boot gate'
