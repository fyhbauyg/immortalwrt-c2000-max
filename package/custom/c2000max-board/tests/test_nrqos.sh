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
	rm -f "$TMP/fail-match" "$TMP/ingress" "$TMP/filters" "$TMP/foreign-filters" "$TMP/same-pref-filters" "$TMP/down-qdisc" "$TMP/filter-clock" "$TMP/filter-read-fail" "$TMP/keep-pref"
	if [ -d "$TMP/sys/class/net/ifb-nrqos" ]; then
		rm -f "$TMP/sys/class/net/ifb-nrqos/ifalias" "$TMP/sys/class/net/ifb-nrqos/ifindex"
		rmdir "$TMP/sys/class/net/ifb-nrqos"
	fi
	rm -f "$TMP/state/down-owner" "$TMP/state/down-session" "$TMP/state/down-ifindex" "$TMP/state/down-alias" "$TMP/state/down-ingress"
	: > "$TMP/tc.log"
	: > "$TMP/ip.log"
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

# The controller has independent duplex/absolute-throughput regressions.
sh "$HERE/test_nrqos_autorate_v2.sh" "$BOARD_ROOT"

# Old configuration remains upload-only. Missing new fields are not an
# implicit migration that can change a working device's receive path.
reset_case
sh "$BIN" start
assert sh -c 'sh "$1" status | jq -e ".api_version == 2 and .download_enabled == false and .download_active == false and .direction == \"upload\"" >/dev/null' sh "$BIN"
assert test ! -s "$TMP/ip.log"
sh "$BIN" stop

duplex_config() { cfg download_enabled 1; cfg download_kbit 130000; }
reset_case
duplex_config
sh "$BIN" start
assert grep -q 'dev ifb-nrqos root handle 366: cake bandwidth 130000kbit besteffort flows nonat ingress no-ack-filter no-split-gso' "$TMP/tc.log"
assert grep -q 'chain 0 handle 1 matchall skip_hw action mirred egress redirect dev ifb-nrqos' "$TMP/tc.log"
assert sh -c 'sh "$1" status | jq -e ".active == true and .download_active == true and .download_kbit == 130000 and .direction == \"bidirectional\" and .dataplane_verified == false" >/dev/null' sh "$BIN"
sh "$BIN" stop
assert test ! -e "$TMP/sys/class/net/ifb-nrqos"
assert test ! -e "$TMP/ingress"
assert test ! -e "$TMP/filters"
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"

# A pref-scoped tc query omits pref 365 on the target, but other versions
# retain it. Both formats must work without relaxing unscoped ownership.
reset_case
duplex_config
touch "$TMP/keep-pref"
sh "$BIN" start
assert sh -c 'sh "$1" status | jq -e ".download_active == true" >/dev/null' sh "$BIN"
rm -f "$TMP/keep-pref"
assert sh -c 'sh "$1" status | jq -e ".download_active == true" >/dev/null' sh "$BIN"
sh "$BIN" stop
assert test ! -e "$TMP/sys/class/net/ifb-nrqos"
assert test ! -e "$TMP/ingress"

# Installed/used/firstused ages and packet counters change between tc
# snapshots, including during setup. They must not imply ownership loss.
reset_case
duplex_config
printf '0\n' > "$TMP/filter-clock"
sh "$BIN" start
for n in 1 2 3; do
	assert sh -c 'sh "$1" status | jq -e ".download_active == true" >/dev/null' sh "$BIN"
done
assert test "$(cat "$TMP/filter-clock")" -gt 5
sh "$BIN" stop
assert grep -q 'filter del dev eth2 parent ffff: protocol all pref 365 chain 0 handle 1 matchall' "$TMP/tc.log"
assert test ! -e "$TMP/sys/class/net/ifb-nrqos"

for pair in 'download_enabled=bad' 'download_kbit=0' 'download_kbit=127' 'download_kbit=1000001' 'download_kbit=130000;true'; do
	reset_case
	duplex_config
	printf '%s\n' "$pair" >> "$TMP/config"
	reject
	assert test ! -s "$TMP/tc.log"
	assert test ! -s "$TMP/ip.log"
done

reset_case
duplex_config
cfg autorate 1
cfg min_upload_kbit 10000
cfg max_upload_kbit 150000
reject
cfg min_download_kbit 10000
cfg max_download_kbit 150000
sh "$BIN" start
sh "$BIN" stop

# Foreign ingress, clsact and IFB interfaces must be rejected before even
# changing the existing upload shaper.
for foreign in ingress clsact ifb; do
	reset_case
	sh "$BIN" start
	size=$(wc -l < "$TMP/tc.log")
	duplex_config
	case "$foreign" in
		ingress) printf 'qdisc ingress ffff: parent ffff:fff1 ----------------\n' > "$TMP/ingress";;
		clsact) printf 'qdisc clsact ffff: parent ffff:fff1 ----------------\n' > "$TMP/ingress";;
		ifb) mkdir "$TMP/sys/class/net/ifb-nrqos"; printf '100\n' > "$TMP/sys/class/net/ifb-nrqos/ifindex";;
	esac
	reject
	assert test "$size" -eq "$(wc -l < "$TMP/tc.log")"
	assert test ! -s "$TMP/ip.log"
	assert grep -q '^qdisc cake 365:' "$TMP/qdisc"
	sh "$BIN" stop
done

# Each partial setup failure rolls back only newly acquired resources and
# leaves the pre-existing upload queue/rate intact.
for failure in 'link add name' 'link set dev ifb-nrqos alias' 'link set dev ifb-nrqos up' 'qdisc replace dev ifb-nrqos' 'qdisc add dev eth2' 'filter add dev eth2'; do
	reset_case
	sh "$BIN" start
	duplex_config
	printf '%s\n' "$failure" > "$TMP/fail-match"
	reject
	assert grep -q '^qdisc cake 365:' "$TMP/qdisc"
	assert test "$(cat "$TMP/state/rate")" = 130000
	assert test ! -e "$TMP/sys/class/net/ifb-nrqos"
	assert test ! -e "$TMP/ingress"
	assert test ! -e "$TMP/filters"
	rm -f "$TMP/fail-match"
	sh "$BIN" stop
done

# If upload creation fails after download succeeded, remove the whole new
# download path instead of leaving a half-enabled service.
reset_case
duplex_config
printf 'qdisc replace dev eth2\n' > "$TMP/fail-match"
reject
assert test ! -e "$TMP/sys/class/net/ifb-nrqos"
assert test ! -e "$TMP/ingress"
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"

# A foreign filter added later survives stop. It keeps the shared ingress
# qdisc, while our redirect and unused IFB are removed.
reset_case
duplex_config
sh "$BIN" start
printf 'filter protocol ip pref 42 flower chain 0\n' > "$TMP/foreign-filters"
assert sh -c 'sh "$1" status | jq -e ".download_active == false" >/dev/null' sh "$BIN"
sh "$BIN" stop
assert test -s "$TMP/foreign-filters"
assert test -s "$TMP/ingress"
assert test ! -e "$TMP/filters"
assert test ! -e "$TMP/sys/class/net/ifb-nrqos"

# Updating an already running pair is transactional: a failed upload update
# restores the previous download bandwidth and IFB session identity.
reset_case
duplex_config
sh "$BIN" start
saved_down_token=$(cat "$TMP/state/down-session")
cfg upload_kbit 120000
cfg download_kbit 110000
printf 'qdisc change dev eth2\n' > "$TMP/fail-match"
reject
assert test "$(cat "$TMP/state/rate")" = 130000
assert test "$(cat "$TMP/state/download-rate")" = 130000
assert test "$(cat "$TMP/state/down-session")" = "$saved_down_token"
assert test "$(cat "$TMP/sys/class/net/ifb-nrqos/ifalias")" = "c2000max-nrqos:$saved_down_token"
assert grep -q 'qdisc change dev ifb-nrqos root handle 366: cake bandwidth 130000kbit' "$TMP/tc.log"
rm -f "$TMP/fail-match"
sh "$BIN" stop

# Same name alone does not establish IFB ownership: a replaced interface or
# foreign qdisc must be kept, not deleted during our stop.
reset_case
duplex_config
sh "$BIN" start
printf 'qdisc htb 8: root refcnt 2\n' > "$TMP/down-qdisc"
if sh "$BIN" stop; then printf 'FAIL: foreign IFB qdisc must block deletion\n' >&2; exit 1; fi
assert test -d "$TMP/sys/class/net/ifb-nrqos"
assert grep -q '^qdisc htb 8:' "$TMP/down-qdisc"
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"
assert test ! -e "$TMP/state/owner"
assert test -e "$TMP/state/down-owner"

# A pref bucket is not necessarily a single rule. A foreign protocol,
# handle, chain or second action makes deletion unsafe. Keep that bucket
# and its IFB intact, but always release our own upload queue on stop.
for foreign in protocol handle chain action target; do
	reset_case
	duplex_config
	sh "$BIN" start
	case "$foreign" in
		protocol) printf 'filter parent ffff: protocol ip pref 365 flower chain 0 handle 0x1\n' > "$TMP/same-pref-filters";;
		handle) printf 'filter parent ffff: protocol all pref 365 matchall chain 0 handle 0x2\n' > "$TMP/same-pref-filters";;
		chain) printf 'filter parent ffff: protocol all pref 365 matchall chain 1 handle 0x1\n' > "$TMP/same-pref-filters";;
		action) printf '\taction order 2: gact action drop\n' > "$TMP/same-pref-filters";;
		target) printf '\taction order 1: mirred (Egress Redirect to device ifb-other) stolen\n' > "$TMP/same-pref-filters";;
	esac
	assert sh -c 'sh "$1" status | jq -e ".download_active == false" >/dev/null' sh "$BIN"
	if sh "$BIN" stop; then printf 'FAIL: ambiguous pref bucket must prevent download cleanup\n' >&2; exit 1; fi
	assert test -s "$TMP/filters"
	assert test -s "$TMP/same-pref-filters"
	assert test -e "$TMP/sys/class/net/ifb-nrqos"
	assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"
	assert test ! -e "$TMP/state/owner"
	if grep -q '^filter del ' "$TMP/tc.log"; then printf 'FAIL: foreign pref bucket was deleted\n' >&2; exit 1; fi
	# Once the foreign conflict is removed, retained recovery state permits
	# an explicit retry to finish cleaning the download resources.
	rm -f "$TMP/same-pref-filters"
	sh "$BIN" stop
	assert test ! -e "$TMP/sys/class/net/ifb-nrqos"
done

# Disabling only the download option restores ordinary ingress and keeps
# the upload CAKE enabled, without changing HNAT or any packet mark.
reset_case
duplex_config
sh "$BIN" start
cfg download_enabled 0
sh "$BIN" start
assert grep -q '^qdisc cake 365:' "$TMP/qdisc"
assert test ! -e "$TMP/sys/class/net/ifb-nrqos"
assert test ! -e "$TMP/ingress"
sh "$BIN" stop

# A failed netlink inspection is not proof that ingress has no filters.
# Retain uncertain download resources, but release our identified upload.
reset_case
duplex_config
sh "$BIN" start
touch "$TMP/filter-read-fail"
if sh "$BIN" stop; then printf 'FAIL: failed filter inspection must retain download resources\n' >&2; exit 1; fi
assert test -s "$TMP/filters"
assert test -s "$TMP/ingress"
assert test -e "$TMP/sys/class/net/ifb-nrqos"
assert grep -q '^qdisc fq_codel 0:' "$TMP/qdisc"
rm -f "$TMP/filter-read-fail"
sh "$BIN" stop
assert test ! -e "$TMP/sys/class/net/ifb-nrqos"

# Old supervisor tokens cannot tear down the queues of a newer owner.
reset_case
duplex_config
sh "$BIN" run & pid=$!
for n in 1 2 3 4 5 6 7 8 9 10; do [ -f "$TMP/state/rate" ] && [ -f "$TMP/state/download-rate" ] && break; /bin/sleep 0.05; done
printf 'manual:new-owner\n' > "$TMP/state/queue-session"
printf 'manual:new-owner\n' > "$TMP/state/down-session"
printf 'c2000max-nrqos:manual:new-owner\n' > "$TMP/sys/class/net/ifb-nrqos/ifalias"
printf '999999:1\n' > "$TMP/state/session"
kill -TERM "$pid"
wait "$pid"
assert grep -q '^qdisc cake 365:' "$TMP/qdisc"
assert grep -q '^qdisc cake 366:' "$TMP/down-qdisc"
assert test -s "$TMP/filters"
sh "$BIN" stop
assert test ! -e "$TMP/sys/class/net/ifb-nrqos"

# This implementation must never claim to control hardware or
# install packet/connection marks, and must have no flash-writing primitives.
if grep -E '^[[:space:]]*(fw_setenv|mtd|flash_erase|nft|iptables|ip6tables)([[:space:]]|$)|>.*(hook_toggle|qos_toggle)|/dev/mtd' "$BIN"; then exit 1; fi
# BusyBox on this target rejects fractional sleep; model this in the mock
# and prevent a future polling-loop regression from slipping through.
if sleep 0.1 >/dev/null 2>&1; then printf 'FAIL: sleep mock accepted a fraction\n' >&2; exit 1; fi
if grep -E 'sleep[[:space:]]+[0-9]+\.[0-9]+' "$BIN"; then printf 'FAIL: target sleep must use integers\n' >&2; exit 1; fi
printf 'NR QoS lifecycle, ownership, conflicts, bounds and autorate tests passed\n'
