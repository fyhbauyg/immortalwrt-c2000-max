#!/bin/sh
# Isolated stop-contract tests: no real signals, GPIO, ubus, or modem access.
set -eu

board_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
init_script="${1:-$board_dir/files/etc/init.d/c2000max-sim}"
fixture="$(mktemp -d /tmp/c2000max-sim-stop.XXXXXX)"
cleanup() {
	case "$fixture" in
		/tmp/c2000max-sim-stop.*) rm -rf -- "$fixture" ;;
	esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$fixture/proc/1234" "$fixture/proc/0" "$fixture/proc/1"
for reserved_pid in 0 1; do
	printf '%s\000' /bin/sh /etc/rc.common /etc/init.d/c2000max-sim boot > "$fixture/proc/$reserved_pid/cmdline"
done
STOP_TEST_PROC="$fixture/proc"
events="$fixture/events"
marker="$fixture/shutdown"
test_pidfile="$fixture/worker.pid"
kill_rc=0
power_rc=0
checks=0

# Redirect only the fixture's init-script dependencies; boot/start/reload are
# never called. /proc is fake, kill is a recording function, and power-off is
# a marker-writing stub, so even PID 0/1/unrelated-PID cases cannot signal.
sed \
	-e "s|/var/run/c2000max-sim-boot.pid|$test_pidfile|g" \
	-e "s|/tmp/c2000max-sim-boot.timeline|$fixture/timeline|g" \
	-e 's|/usr/sbin/c2000max-sim|sim_cli_mock|g' \
	-e 's|if sim_boot_worker_active "$pid"; then|if sim_boot_worker_active "$pid" "$STOP_TEST_PROC"; then|' \
	"$init_script" > "$fixture/init"
. "$fixture/init"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
check() { checks=$((checks + 1)); "$@" || fail "check $checks: $*"; }
sim_cli_mock() {
	[ "$*" = power-off ] || fail "unexpected CLI action: $*"
	: > "$marker"
	printf 'power-off\n' >> "$events"
	return "$power_rc"
}
kill() {
	[ -e "$marker" ] || fail 'signal before shutdown guard'
	[ -f "$test_pidfile" ] || fail 'pidfile removed before signal'
	printf 'kill %s\n' "$*" >> "$events"
	return "$kill_rc"
}
new_case() {
	: > "$events"
	rm -f "$marker" "$test_pidfile" "$fixture/proc/1234/cmdline"
	kill_rc=0
	power_rc=0
}
set_worker() {
	printf '1234\n' > "$test_pidfile"
	printf '%s\000' /bin/sh /etc/rc.common "$1" "${2:-boot}" > "$fixture/proc/1234/cmdline"
}
assert_active_stop() {
	stop || fail 'stop returned failure'
	check test -e "$marker"
	check test -f "$test_pidfile"
	check test "$(cat "$test_pidfile")" = 1234
	check test "$(cat "$events")" = "$(printf 'power-off\nkill -TERM 1234')"
}
assert_stale_stop() {
	stop || fail 'stop returned failure'
	check test -e "$marker"
	check test ! -e "$test_pidfile"
	check test "$(cat "$events")" = power-off
}

# Both rc.common invocation forms, including the queued old S12 link, match.
for init_arg in /etc/init.d/c2000max-sim /etc/rc.d/S09c2000max-sim /etc/rc.d/S12c2000max-sim; do
	new_case
	set_worker "$init_arg"
	assert_active_stop
done

# A foreground CLI may defer the wrapper's TERM trap. Repeated stop and even
# signal failure must keep ownership until that wrapper really exits.
new_case
set_worker /etc/rc.d/S09c2000max-sim
assert_active_stop
: > "$events"
kill_rc=1
assert_active_stop
sim_boot_finish 143 "$fixture/status" "$test_pidfile"
check test ! -e "$test_pidfile"
check test "$(cat "$fixture/status")" = failed
: > "$events"
assert_stale_stop

# A failed physical power write still precedes signalling; production CLI
# publishes the guard first, and stop intentionally tolerates its error.
new_case
set_worker /etc/init.d/c2000max-sim
power_rc=1
assert_active_stop

# Empty, malformed, process-group, PID 1, and overflow inputs must never kill.
for bad_pid in '' 0 1 -1 abc '1234 5678' 999999999999999999999999999999; do
	new_case
	printf '%s\n' "$bad_pid" > "$test_pidfile"
	assert_stale_stop
done
new_case
assert_stale_stop
new_case
printf '1234\n' > "$test_pidfile"
assert_stale_stop
new_case
printf '1234\n' > "$test_pidfile"
: > "$fixture/proc/1234/cmdline"
assert_stale_stop

# Reused PIDs, manual apply/start, and substring/lookalike service arguments
# are not the background boot worker, even if one argument happens to be boot.
for init_arg in /usr/bin/unrelated /etc/rc.d/S9c2000max-sim /etc/rc.d/S09c2000max-sim-extra /tmp/etc/init.d/c2000max-sim; do
	new_case
	set_worker "$init_arg"
	assert_stale_stop
done
for action in start apply reboot boot-extra; do
	new_case
	set_worker /etc/init.d/c2000max-sim "$action"
	assert_stale_stop
done
new_case
printf '1234\n' > "$test_pidfile"
printf '%s\000' /bin/sh '-c /etc/init.d/c2000max-sim boot' > "$fixture/proc/1234/cmdline"
assert_stale_stop

printf 'SIM stop lifecycle: %s isolated checks passed\n' "$checks"
