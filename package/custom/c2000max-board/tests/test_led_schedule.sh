#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/files/usr/sbin/c2000max-leds"
LED_TEST_TMP="$(mktemp -d -t c2000max-led-test.XXXXXXXX)"
export LED_TEST_TMP
cleanup_test() {
	case "$LED_TEST_TMP" in /tmp/c2000max-led-test.*) rm -rf -- "$LED_TEST_TMP" ;; esac
}
trap cleanup_test EXIT
mkdir -p "$LED_TEST_TMP/sysfs" "$LED_TEST_TMP/bin"
export C2000MAX_LED_SYSFS="$LED_TEST_TMP/sysfs"
export C2000MAX_LED_STATE_DIR="$LED_TEST_TMP/state"
export C2000MAX_LED_INIT="$LED_TEST_TMP/system"
export C2000MAX_QMODEM_LED_INIT="$LED_TEST_TMP/qmodem"
cp "$ROOT/tests/led-init-mock.sh" "$C2000MAX_LED_INIT"
cp "$ROOT/tests/led-init-mock.sh" "$C2000MAX_QMODEM_LED_INIT"
chmod +x "$C2000MAX_LED_INIT" "$C2000MAX_QMODEM_LED_INIT"
manual=1
user_managed=0
user_status_managed=0
fake_stamp=1788950000
fake_hour=23
fake_minute=00
real_timezone=0
uci() {
	[ "${1:-}" != -q ] || shift
	case "$1:$2" in
		get:c2000max.led.enabled) echo "$manual" ;;
		show:system)
			[ "$user_managed" != 1 ] || printf "system.myled=led\nsystem.myled.sysfs='blue:sig1'\n"
			[ "$user_status_managed" != 1 ] || printf "system.statusled=led\nsystem.statusled.sysfs='blue:status'\n" ;;
		get:system.myled.sysfs) echo 'blue:sig1' ;;
		get:system.myled.trigger) echo 'heartbeat' ;;
		get:system.statusled.sysfs) echo 'blue:status' ;;
	esac
	return 0
}
date() {
	if [ "$real_timezone" = 1 ]; then command date -d "@$fake_stamp" "$@"
	else printf '%s %s %s\n' "$fake_stamp" "$fake_hour" "$fake_minute"; fi
}
set -- --library
. "$BIN"
assert_eq() { [ "$1" = "$2" ] || { echo "FAIL: $3: wanted '$2', got '$1'" >&2; exit 1; }; }
pass=0
assert_on() { if scheduled_off; then echo "FAIL: expected scheduled on: $*" >&2; exit 1; fi; pass=$((pass + 1)); }
assert_off() { scheduled_off || { echo "FAIL: expected scheduled off: $*" >&2; exit 1; }; pass=$((pass + 1)); }
schedule_enabled=1; schedule_start='22:0'; schedule_end='7:0'
fake_hour=21; fake_minute=59; assert_on before-start
fake_hour=22; fake_minute=00; assert_off exact-start
fake_hour=23; fake_minute=59; assert_off before-midnight
fake_hour=00; fake_minute=00; assert_off midnight
fake_hour=06; fake_minute=59; assert_off before-end
fake_hour=07; fake_minute=00; assert_on exact-end
schedule_start=08:00; schedule_end=18:00
fake_hour=08; assert_off daytime-start
fake_hour=17; fake_minute=59; assert_off daytime-before-end
fake_hour=18; fake_minute=00; assert_on daytime-end
schedule_start=22:00; schedule_end=07:00; fake_hour=23
fake_stamp=0; assert_on invalid-boot-clock
fake_stamp=1788950000; assert_off synchronized-clock
schedule_enabled=0; assert_on disabled-schedule
manual=0; effective_off || { echo 'FAIL: manual off ignored with schedule disabled' >&2; exit 1; }
manual=1; schedule_enabled=1
for invalid in 24:00 23:60 -1:00 00:000 000:00 '3:4:5' '2:4;reboot' ' 2:4' ''; do
	if time_minutes "$invalid" >/dev/null; then echo "FAIL: accepted time '$invalid'" >&2; exit 1; fi
done
assert_eq "$(time_minutes 08:09)" 489 leading-zeros
schedule_start=07:00; schedule_end=07:00; assert_on equal-boundaries
schedule_start=22:00; schedule_end=07:00
fake_stamp="$(command date -u -d '2026-09-09 00:30:00' +%s)"; real_timezone=1
export TZ=UTC0; assert_off UTC-timezone
export TZ=CST-8; assert_on China-timezone
real_timezone=0; fake_hour=23; fake_minute=00

make_led() {
	local name="$1" trigger="$2" value="$3"
	mkdir -p "$LED_ROOT/$name"
	printf 'none timer netdev [%s]\n' "$trigger" > "$LED_ROOT/$name/trigger"
	printf '%s\n' "$value" > "$LED_ROOT/$name/brightness"
}
make_led blue:sig1 timer 1
make_led blue:sig2 none 0
make_led blue:sig3 none 1
make_led blue:status heartbeat 1
make_led red:error none 0
printf '123\n' > "$LED_ROOT/blue:sig1/delay_on"
printf '456\n' > "$LED_ROOT/blue:sig1/delay_off"
: > "$LED_TEST_TMP/qmodem-running"; : > "$LED_TEST_TMP/qmodem-enabled"
enter_off
for dir in "$LED_ROOT"/*; do
	assert_eq "$(cat "$dir/brightness")" 0 all-five-dark
	assert_eq "$(cat "$dir/trigger")" none triggers-disabled
done
assert_eq "$(cat "$STATE_DIR/saved/blue:sig1/trigger")" timer saved-timer
assert_eq "$(cat "$STATE_DIR/saved/blue:sig1/delay_on")" 123 saved-delay
assert_eq "$(grep -c '^qmodem stop$' "$LED_TEST_TMP/services")" 1 suspend-once
# Simulate another LED writer waking an indicator and a service reload while
# suppression remains active. Neither may replace the original snapshots.
printf '1\n' > "$LED_ROOT/blue:sig2/brightness"
enter_off
cleanup
assert_eq "$(cat "$STATE_DIR/saved/blue:sig1/brightness")" 1 reload-keeps-snapshot
assert_eq "$(cat "$STATE_DIR/saved/blue:sig2/brightness")" 0 originally-off-stays-off
assert_eq "$(grep -c '^qmodem stop$' "$LED_TEST_TMP/services")" 1 no-per-tick-restart
# A future PHY LED, if safely registered by the kernel, participates without
# board-specific PHY register writes or any networking restart.
make_led phy0:green:lan netdev 1
printf 'eth1\n' > "$LED_ROOT/phy0:green:lan/device_name"
printf '1\n' > "$LED_ROOT/phy0:green:lan/link_2500"
enter_off
assert_eq "$(cat "$LED_ROOT/phy0:green:lan/brightness")" 0 late-LED-dark
leave_off
assert_eq "$(cat "$LED_ROOT/blue:sig1/trigger")" timer restore-timer
assert_eq "$(cat "$LED_ROOT/blue:sig1/brightness")" 1 restore-signal
assert_eq "$(cat "$LED_ROOT/blue:sig1/delay_on")" 123 restore-delay-on
assert_eq "$(cat "$LED_ROOT/blue:sig1/delay_off")" 456 restore-delay-off
assert_eq "$(cat "$LED_ROOT/blue:sig2/brightness")" 0 preserve-original-off
assert_eq "$(cat "$LED_ROOT/blue:status/trigger")" heartbeat restore-heartbeat
assert_eq "$(cat "$LED_ROOT/phy0:green:lan/trigger")" netdev restore-PHY-trigger
assert_eq "$(cat "$LED_ROOT/phy0:green:lan/device_name")" eth1 restore-netdev
assert_eq "$(cat "$LED_ROOT/phy0:green:lan/link_2500")" 1 restore-link-rule
assert_eq "$(grep -c '^qmodem start$' "$LED_TEST_TMP/services")" 1 resume-previously-running
assert_eq "$(grep -c '^system reload$' "$LED_TEST_TMP/services" || true)" 0 no-reload-without-system-LED-rules
leave_off
assert_eq "$(grep -c '^system reload$' "$LED_TEST_TMP/services" || true)" 0 no-steady-state-reload
# Explicit user LED configuration takes priority over signal colour updates.
user_managed=1
printf 'heartbeat\n' > "$LED_ROOT/blue:sig1/trigger"
set_led blue:sig1 0; blink_led blue:sig1 700
assert_eq "$(cat "$LED_ROOT/blue:sig1/trigger")" heartbeat preserve-user-trigger
user_managed=0
# User edits while suppressed win over the pre-suppression snapshot.
printf 'none [heartbeat]\n' > "$LED_ROOT/blue:status/trigger"
printf '1\n' > "$LED_ROOT/blue:status/brightness"
enter_off
: > "$LED_TEST_TMP/user-config-off"
user_status_managed=1
rm -f "$LED_TEST_TMP/qmodem-enabled"
leave_off
assert_eq "$(cat "$LED_ROOT/blue:status/brightness")" 0 honor-updated-user-config
assert_eq "$(grep -c '^system reload$' "$LED_TEST_TMP/services")" 1 reload-current-system-LED-rule
assert_eq "$(grep -c '^qmodem start$' "$LED_TEST_TMP/services")" 1 no-enable-disabled-service

# Exercise the production tick scheduler, using a counter instead of its AT
# consumer. No disabled or overnight tick can call the modem status path.
signal_queries=0
update_signal() { signal_queries=$((signal_queries + 1)); }
remaining=0; interval=15; schedule_enabled=0; manual=0
led_tick; led_tick; led_tick
assert_eq "$signal_queries" 0 zero-AT-while-manually-off
manual=1; schedule_enabled=1; fake_hour=23
led_tick; led_tick
assert_eq "$signal_queries" 0 zero-AT-during-night
fake_hour=12
led_tick; led_tick; led_tick
assert_eq "$signal_queries" 1 signal-query-resumes-once
led_tick; led_tick; led_tick; led_tick; led_tick
assert_eq "$signal_queries" 1 no-per-tick-AT-query
led_tick
assert_eq "$signal_queries" 2 preserve-low-frequency-signal-update

# Failure injection: a non-directory state path cannot capture any baseline.
# No indicator may be suppressed without a restorable snapshot.
STATE_DIR="$LED_TEST_TMP/blocked-state"
printf 'not-a-directory\n' > "$STATE_DIR"
printf '1\n' > "$LED_ROOT/red:error/brightness"
printf 'none\n' > "$LED_ROOT/red:error/trigger"
if enter_off 2>/dev/null; then echo 'FAIL: snapshot directory failure accepted' >&2; exit 1; fi
assert_eq "$(cat "$LED_ROOT/red:error/brightness")" 1 no-off-without-snapshot-directory
rm -f "$STATE_DIR"

# A partial write failure must not leave completed stale snapshots from the
# aborted off attempt. Unrecognized contents are not recursively removed.
STATE_DIR="$LED_TEST_TMP/partial-state"
mkdir -p "$STATE_DIR/saved/red:error/brightness"
if enter_off 2>/dev/null; then echo 'FAIL: partial snapshot write failure accepted' >&2; exit 1; fi
assert_eq "$(cat "$LED_ROOT/red:error/brightness")" 1 no-off-after-partial-snapshot
[ ! -f "$STATE_DIR/forced_off" ] || { echo 'FAIL: failed snapshot armed suppression' >&2; exit 1; }
[ ! -f "$STATE_DIR/saved/blue:sig1/complete" ] || { echo 'FAIL: aborted snapshot remained valid' >&2; exit 1; }
[ -f "$STATE_DIR/error" ] || { echo 'FAIL: missing snapshot failure diagnostic' >&2; exit 1; }
rmdir "$STATE_DIR/saved/red:error/brightness"

# Snapshot succeeds on retry. A failed restoration keeps only the affected
# snapshot and retries later; restored siblings are not overwritten again.
printf '1\n' > "$LED_ROOT/blue:sig1/brightness"
enter_off
assert_eq "$(cat "$LED_ROOT/red:error/brightness")" 0 off-after-successful-retry
rm -f "$LED_ROOT/red:error/brightness"
mkdir "$LED_ROOT/red:error/brightness"
if leave_off 2>/dev/null; then echo 'FAIL: restoration write failure accepted' >&2; exit 1; fi
[ -f "$STATE_DIR/saved/red:error/complete" ] || { echo 'FAIL: failed restore snapshot deleted' >&2; exit 1; }
[ -f "$STATE_DIR/forced_off" ] && [ -f "$STATE_DIR/error" ] || { echo 'FAIL: failed restore lost retry state' >&2; exit 1; }
grep -q 'red:error:brightness' "$STATE_DIR/error" || { echo 'FAIL: missing failed LED attribute' >&2; exit 1; }
[ ! -f "$STATE_DIR/saved/blue:sig1/complete" ] || { echo 'FAIL: restored sibling snapshot retained' >&2; exit 1; }
printf '0\n' > "$LED_ROOT/blue:sig1/brightness"
rmdir "$LED_ROOT/red:error/brightness"
printf '0\n' > "$LED_ROOT/red:error/brightness"
leave_off
assert_eq "$(cat "$LED_ROOT/red:error/brightness")" 1 failed-restore-retries-original-value
assert_eq "$(cat "$LED_ROOT/blue:sig1/brightness")" 0 successful-sibling-not-overwritten-on-retry
[ ! -f "$STATE_DIR/forced_off" ] && [ ! -f "$STATE_DIR/error" ] || { echo 'FAIL: successful retry kept failure state' >&2; exit 1; }

# The live device already matched its saved none/brightness states, but the
# old restore kept attempting writes. Matched read-only attributes succeed
# without any write; a mismatched read-only value still fails closed.
chmod 444 "$LED_ROOT/red:error/brightness"
restore_led_attribute "$LED_ROOT/red:error" brightness 1 || { echo 'FAIL: matching read-only attribute required a write' >&2; exit 1; }
if restore_led_attribute "$LED_ROOT/red:error" brightness 0; then echo 'FAIL: mismatched read-only attribute accepted' >&2; exit 1; fi
chmod 644 "$LED_ROOT/red:error/brightness"

# A successful write return is not evidence that sysfs applied the value.
# Simulate a driver retaining 0 after a requested 1 and verify both readback
# rejection and retention of the exact snapshot until a genuine retry.
enter_off
discard_one=1
printf() {
	if [ "$discard_one" = 1 ] && [ "${1:-}" = '%s\n' ] && [ "${2:-}" = 1 ]; then
		builtin printf '0\n'
	else builtin printf "$@"; fi
}
if leave_off 2>/dev/null; then echo 'FAIL: unapplied sysfs write accepted' >&2; exit 1; fi
[ -f "$STATE_DIR/saved/red:error/complete" ] && [ -f "$STATE_DIR/forced_off" ] || { echo 'FAIL: readback mismatch discarded retry state' >&2; exit 1; }
grep -q 'red:error:brightness' "$STATE_DIR/error" || { echo 'FAIL: readback mismatch missing attribute diagnostic' >&2; exit 1; }
assert_eq "$(cat "$LED_ROOT/red:error/brightness")" 0 fault-actually-retained-different-value
discard_one=0
leave_off
unset -f printf
assert_eq "$(cat "$LED_ROOT/red:error/brightness")" 1 readback-retry-restores-original
[ ! -f "$STATE_DIR/forced_off" ] && [ ! -f "$STATE_DIR/error" ] || { echo 'FAIL: verified readback retry retained error' >&2; exit 1; }

echo "LED schedule/sysfs fixture passed ($pass schedule checks plus snapshot/service assertions)"
