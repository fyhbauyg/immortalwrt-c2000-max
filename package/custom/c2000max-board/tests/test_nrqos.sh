#!/bin/sh
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BOARD_ROOT=${1:-$(dirname "$HERE")}
BIN="$BOARD_ROOT/files/usr/sbin/c2000max-nrqos"
ALG="$BOARD_ROOT/files/usr/lib/c2000max/nrqos-autorate.awk"
TMP=$(mktemp -d /tmp/c2000max-nrqos-test.XXXXXX)
cleanup() { case "$TMP" in /tmp/c2000max-nrqos-test.*) rm -rf "$TMP";; esac; }
trap cleanup EXIT INT TERM
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/sys/class/net/eth2/device" "$TMP/sys/drivers/cdc_ncm"
ln -s "$TMP/sys/drivers/cdc_ncm" "$TMP/sys/class/net/eth2/device/driver"
for cmd in tc uci ip logger sleep ping; do ln -s "$HERE/nrqos-mock.sh" "$TMP/bin/$cmd"; done
export PATH="$TMP/bin:$PATH" MOCK="$TMP"
export C2000MAX_NRQOS_STATE="$TMP/state" C2000MAX_NRQOS_SYS="$TMP/sys"
export C2000MAX_NRQOS_BOARD="$TMP/board" C2000MAX_NRQOS_COMPAT="$TMP/compat"
export C2000MAX_NRQOS_AWK="$ALG" C2000MAX_NRQOS_EQOS_STATE="$TMP/eqos-backend"
printf 'nradio,c2000-max\n' > "$TMP/board"
printf 'c2000_sqm_enabled() { [ -f "$MOCK/sqm-on" ]; }\n' > "$TMP/compat"

reset_case() {
	sh "$BIN" stop >/dev/null 2>&1 || :
	printf 'qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 4Mb ecn drop_batch 64\n' > "$TMP/qdisc"
	printf 'eth2\n' > "$TMP/default"
	printf '%s\n' 'enabled=1' 'interface=eth2' 'upload_kbit=130000' 'autorate=0' 'min_upload_kbit=0' 'max_upload_kbit=0' 'interval=2' 'delay_target_ms=15' 'ping_hosts=223.5.5.5 119.29.29.29' > "$TMP/config"
	rm -f "$TMP/tc-fail" "$TMP/tc-fail-change" "$TMP/eqos-on" "$TMP/sqm-on" "$TMP/eqos-backend" "$TMP/state/error"
	: > "$TMP/tc.log"
}
cfg() { printf '%s=%s\n' "$1" "$2" >> "$TMP/config"; }
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
reject() { if sh "$BIN" start >/dev/null 2>&1; then printf 'FAIL: expected rejection\n' >&2; exit 1; fi; }

reset_case
cfg enabled 0
sh "$BIN" start
assert test ! -s "$TMP/tc.log"

reset_case
sh "$BIN" start
assert grep -q 'cake bandwidth 130000kbit besteffort flows nonat no-ack-filter' "$TMP/tc.log"
assert sh -c 'sh "$1" status | jq -e ".active == true and .upload_kbit == 130000 and .dataplane_verified == false" >/dev/null' sh "$BIN"
sh "$BIN" stop
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"
size=$(wc -l < "$TMP/tc.log")
sh "$BIN" stop
assert test "$size" -eq "$(wc -l < "$TMP/tc.log")"
sh "$BIN" start
cfg enabled 0
sh "$BIN" start
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"

reset_case
printf 'qdisc htb 1: root refcnt 2\n' > "$TMP/qdisc"
reject
assert test ! -s "$TMP/tc.log"
assert grep -q 'Foreign/non-default' "$TMP/state/error"

reset_case
printf 'qdisc cake 365: root refcnt 2\n' > "$TMP/qdisc"
reject
assert test ! -s "$TMP/tc.log"

reset_case
sh "$BIN" start
printf 'qdisc htb 1: root refcnt 2\n' > "$TMP/qdisc"
size=$(wc -l < "$TMP/tc.log")
sh "$BIN" stop
assert test "$size" -eq "$(wc -l < "$TMP/tc.log")"
assert grep -q '^qdisc htb 1:' "$TMP/qdisc"

reset_case
printf 'eth1\n' > "$TMP/default"
reject
assert test ! -s "$TMP/tc.log"
assert grep -q 'default route is not eth2' "$TMP/state/error"

for reason in sqm-on eqos-on eqos-backend; do
	reset_case
	printf '1\n' > "$TMP/$reason"
	reject
	assert test ! -s "$TMP/tc.log"
done

for pair in 'upload_kbit=127' 'upload_kbit=1000001' 'upload_kbit=128;touch /tmp/not-allowed' 'interface=eth1'; do
	reset_case
	printf '%s\n' "$pair" >> "$TMP/config"
	reject
	assert test ! -s "$TMP/tc.log"
done

for pair in 'interval=1' 'delay_target_ms=201' 'ping_hosts=223.5.5.5' 'ping_hosts=223.5.5.5 223.5.5.5' 'ping_hosts=127.0.0.1 223.5.5.5'; do
	reset_case
	cfg autorate 1
	cfg min_upload_kbit 50000
	cfg max_upload_kbit 130000
	printf '%s\n' "$pair" >> "$TMP/config"
	reject
	assert test ! -s "$TMP/tc.log"
done

# Malformed hidden autorate options cannot break fixed mode.
reset_case
cfg ping_hosts 'invalid ignored hidden field'
cfg interval 0
cfg delay_target_ms 0
sh "$BIN" start
assert sh -c 'sh "$1" status | jq -e ".active == true and .probes == \"disabled-fixed-rate\"" >/dev/null' sh "$BIN"
sh "$BIN" stop

# A tuned default-looking qdisc must be rejected rather than losing tuning.
reset_case
printf 'qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 10ms interval 100ms memory_limit 4Mb ecn drop_batch 64\n' > "$TMP/qdisc"
reject
assert test ! -s "$TMP/tc.log"

reset_case
cfg autorate 1
reject
assert test ! -s "$TMP/tc.log"
cfg min_upload_kbit 50000
cfg max_upload_kbit 130000
sh "$BIN" start
sh "$BIN" stop

reset_case
touch "$TMP/tc-fail"
reject
assert test ! -f "$TMP/state/owner"
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"

reset_case
sh "$BIN" start
touch "$TMP/tc-fail-change"
cfg upload_kbit 120000
reject
assert test "$(cat "$TMP/state/rate")" = 130000
assert grep -q '^qdisc cake 365:' "$TMP/qdisc"

# Foreground supervision restores only its queue on primary-uplink change.
reset_case
sh "$BIN" run & pid=$!
for n in 1 2 3 4 5 6 7 8 9 10; do [ -f "$TMP/state/owner" ] && break; /bin/sleep 0.05; done
printf 'eth1\n' > "$TMP/default"
if wait "$pid"; then printf 'FAIL: topology change must stop service\n' >&2; exit 1; fi
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"
assert grep -q 'default route is not eth2' "$TMP/state/error"

reset_case
sh "$BIN" run & pid=$!
for n in 1 2 3 4 5 6 7 8 9 10; do [ -f "$TMP/state/owner" ] && break; /bin/sleep 0.05; done
kill -TERM "$pid"
wait "$pid"
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"

# Only one supervised session can own the queue. CLI stop waits for its
# cleanup before returning; immediately starting a new session is safe.
reset_case
sh "$BIN" run & pid=$!
for n in 1 2 3 4 5 6 7 8 9 10; do [ -f "$TMP/state/owner" ] && break; /bin/sleep 0.05; done
first_session=$(cat "$TMP/state/session")
if sh "$BIN" run; then printf 'FAIL: duplicate supervisor accepted\n' >&2; exit 1; fi
assert test "$(cat "$TMP/state/session")" = "$first_session"
sh "$BIN" stop
wait "$pid"
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"
assert test ! -f "$TMP/state/session"
sh "$BIN" run & pid=$!
for n in 1 2 3 4 5 6 7 8 9 10; do [ -f "$TMP/state/owner" ] && break; /bin/sleep 0.05; done
assert test "$(cat "$TMP/state/session")" != "$first_session"
sh "$BIN" stop
wait "$pid"
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"

# Simulate a late old supervisor cleanup after a replacement session was
# installed: the old token must not delete the new owner's qdisc or session.
reset_case
sh "$BIN" run & pid=$!
for n in 1 2 3 4 5 6 7 8 9 10; do [ -f "$TMP/state/owner" ] && break; /bin/sleep 0.05; done
printf 'manual:new-owner\n' > "$TMP/state/queue-session"
printf '999999:1\n' > "$TMP/state/session"
kill -TERM "$pid"
wait "$pid"
assert grep -q '^qdisc cake 365:' "$TMP/qdisc"
assert test "$(cat "$TMP/state/session")" = '999999:1'
sh "$BIN" stop
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"

# A stale PID with a mismatched start time must never be signalled.
reset_case
printf '%s:1\n' "$$" > "$TMP/state/session"
sh "$BIN" stop
assert test ! -f "$TMP/state/session"

# Stateful controller checks: warm-up, all-target agreement, persistence,
# missing reflectors, load gate, upward hysteresis and hard bounds.
: > "$TMP/controller-state"
controller() {
	printf '223.5.5.5 %s\n119.29.29.29 %s\n' "$1" "$2" > "$TMP/controller-samples"
	result=$(awk -v current="$3" -v minimum=50000 -v maximum=130000 -v target=15 -v utilization="$4" -v state_out="$TMP/controller-new" -f "$ALG" "$TMP/controller-state" "$TMP/controller-samples")
	mv "$TMP/controller-new" "$TMP/controller-state"
}
controller 20 30 100000 95
assert test "$result" = '100000 0 2 warming'
controller 60 70 100000 95
assert test "$result" = '100000 40 2 hold'
controller 60 70 100000 95
assert test "$result" = '90000 40 2 decrease'
controller 60 30 90000 95
assert test "$result" = '90000 40 2 hold'
controller 60 0 90000 95
assert test "$result" = '90000 40 1 probe-loss'
controller 60 70 90000 30
assert test "$result" = '90000 40 2 idle'
controller 20 30 90000 95
controller 20 30 90000 95
controller 20 30 90000 95
assert test "$result" = '91800 0 2 increase'
controller 60 70 50000 95
controller 60 70 50000 95
assert test "$result" = '50000 40 2 decrease'
controller 20 30 130000 95
controller 20 30 130000 95
controller 20 30 130000 95
assert test "$result" = '130000 0 2 increase'

# NR capacity can collapse below the configured shaper rate. Low observed
# utilization must not teach persistent congestion into the RTT baseline.
for n in $(seq 1 100); do controller 60 70 130000 15; done
assert test "$result" = '130000 40 2 idle'
assert grep -q '^B 223.5.5.5 20.000$' "$TMP/controller-state"
assert grep -q '^B 119.29.29.29 30.000$' "$TMP/controller-state"
# Genuine lower RTT still improves each reflector's independent baseline.
controller 10 15 130000 15
assert test "$result" = '130000 0 2 idle'
assert grep -q '^B 223.5.5.5 10.000$' "$TMP/controller-state"
assert grep -q '^B 119.29.29.29 15.000$' "$TMP/controller-state"

# This egress-only implementation must never claim to control hardware or
# install packet/connection marks, and must have no flash-writing primitives.
if grep -E '^[[:space:]]*(fw_setenv|mtd|flash_erase|nft|iptables|ip6tables)([[:space:]]|$)|>.*(hook_toggle|qos_toggle)|/dev/mtd' "$BIN"; then exit 1; fi
# BusyBox on this target rejects fractional sleep; model this in the mock
# and prevent a future polling-loop regression from slipping through.
if sleep 0.1 >/dev/null 2>&1; then printf 'FAIL: sleep mock accepted a fraction\n' >&2; exit 1; fi
if grep -E 'sleep[[:space:]]+[0-9]+\.[0-9]+' "$BIN"; then printf 'FAIL: target sleep must use integers\n' >&2; exit 1; fi
printf 'NR QoS lifecycle, ownership, conflicts, bounds and autorate tests passed\n'
