#!/bin/sh
# Deterministic replay, no network/device access and no real sleeps.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BOARD_ROOT=${1:-$(dirname "$HERE")}
ALG="$BOARD_ROOT/files/usr/lib/c2000max/nrqos-autorate.awk"
TMP=$(mktemp -d /tmp/c2000max-nrqos-autorate-v2.XXXXXX)
cleanup() { case "$TMP" in /tmp/c2000max-nrqos-autorate-v2.*) rm -rf "$TMP";; esac; }
trap cleanup EXIT INT TERM
assert() { "$@" || { printf 'FAIL: %s; rate=%s decision=%s\n' "$*" "$rate" "$decision" >&2; exit 1; }; }
reset_case() {
	minimum=10000; maximum=150000; base=130000; rate=130000
	state="$TMP/state"; : > "$state"
	decision=unset; count=0; lowest=$rate
}
sample() {
	printf '223.5.5.5 %s\n119.29.29.29 %s\n' "$1" "$2" > "$TMP/probes"
	observed=$3
	util=$(awk -v n="$observed" -v d="$rate" 'BEGIN { printf "%.2f", n*100/d }')
	set -- $(awk -v current="$rate" -v minimum="$minimum" -v maximum="$maximum" \
		-v target=15 -v utilization="$util" -v observed_kbit="$observed" -v base_rate="$base" \
		-v state_out="$TMP/next" -f "$ALG" "$state" "$TMP/probes")
	assert test "$#" -eq 4
	rate=$1; delay=$2; healthy=$3; decision=$4
	assert test "$rate" -ge "$minimum"
	assert test "$rate" -le "$maximum"
	[ "$rate" -ge "$lowest" ] || lowest=$rate
	count=$((count + 1))
	mv "$TMP/next" "$state"
}
warm() { sample 20 30 0; assert test "$decision" = warming; }
repeat() {
	remaining=$1; shift
	while [ "$remaining" -gt 0 ]; do sample "$@"; remaining=$((remaining - 1)); done
}

# 130 -> 20 Mbps NR capacity drop: low relative utilization is still busy.
reset_case; warm
sample 110 120 20000
assert test "$rate" -eq 130000
sample 110 120 20000
assert test "$rate" -eq 18000
assert test "$decision" = decrease-trial
sample 23 33 17000
assert test "$decision" = trial-observe
sample 22 32 17000
assert test "$decision" = trial-accepted
assert test "$rate" -eq 18000
printf 'PASS capacity collapse: 130000 -> 18000 kbit, confirmed by two clean RTT samples\n'

# Capacity restoration: each direction independently recovers slowly on load.
n=0
while [ "$n" -lt 360 ]; do
	load=$((rate * 95 / 100)); sample 22 32 "$load"; n=$((n + 1))
done
assert test "$rate" -eq 150000
printf 'PASS capacity recovery: reaches configured 150000 kbit ceiling without overshoot\n'

# A game alone, single bad reflector, a one-round spike and probe loss do not
# initiate a decrease. Failed/duplicate reflectors are not a quorum.
reset_case; warm
repeat 100 110 120 500
assert test "$rate" -eq 130000
assert test "$decision" = idle
repeat 100 110 32 120000
assert test "$rate" -eq 130000
sample 110 120 120000; sample 22 32 120000
assert test "$rate" -eq 130000
repeat 5 110 0 120000
assert test "$rate" -eq 130000
assert test "$decision" = probe-loss
printf '223.5.5.5 110\n223.5.5.5 110\n' > "$TMP/probes"
result=$(awk -v current=130000 -v minimum=10000 -v maximum=150000 -v target=15 \
	-v utilization=95 -v observed_kbit=120000 -v base_rate=130000 -v state_out="$TMP/next" \
	-f "$ALG" "$state" "$TMP/probes")
assert test "$result" = '130000 90 1 probe-loss'
printf 'PASS idle game, independent probe disagreement/loss/duplicates and isolated spikes\n'

# Shared radio/network jitter unrelated to shaping: bound the diagnostic dip
# to four observation rounds, restore once, and do not stair-step to minimum.
reset_case; warm
repeat 2 110 120 20000
assert test "$rate" -eq 18000
repeat 3 110 120 17000
assert test "$decision" = trial-observe
sample 110 120 17000
assert test "$rate" -eq 130000
assert test "$decision" = trial-unresponsive-restore
repeat 100 110 120 20000
assert test "$rate" -eq 130000
assert test "$decision" = delay-unresponsive
assert test "$lowest" -eq 18000
repeat 3 22 32 20000
assert test "$decision" = recovered
printf 'PASS common-mode jitter: one bounded trial, rollback, freeze and clean-RTT recovery\n'

# Stopping a download or losing a probe during a trial is not positive causal
# evidence. Restore the pre-trial rate instead of accepting a false success.
reset_case; warm
repeat 2 110 120 20000
sample 22 32 0
assert test "$rate" -eq 130000
assert test "$decision" = trial-idle-restore
reset_case; warm
repeat 2 110 120 20000
sample 22 0 17000
assert test "$rate" -eq 130000
assert test "$decision" = probe-loss-restore

# Shared RTT, different loads: a saturated download may adjust down while the
# low-traffic upload/game direction holds. These are two independent states.
reset_case; state="$TMP/up"; : > "$state"; warm
up_rate=$rate
reset_case; state="$TMP/down"; : > "$state"; warm
repeat 2 110 120 20000
assert test "$rate" -eq 18000
state="$TMP/up"; rate=$up_rate
repeat 2 110 120 500
assert test "$rate" -eq 130000
printf 'PASS directional independence: busy download adapts, low-rate game/upload holds\n'

# 100 rounds at sustained high RTT may not inflate either host baseline.
reset_case; warm
repeat 100 60 70 500
assert grep -q '^B 223.5.5.5 20.000$' "$state"
assert grep -q '^B 119.29.29.29 30.000$' "$state"
sample 10 15 500
assert grep -q '^B 223.5.5.5 10.000$' "$state"
assert grep -q '^B 119.29.29.29 15.000$' "$state"
printf 'PASS 100-round baseline non-drift and genuine lower-baseline learning\n'

# Hard floor and bounded idle return. Cold/unknown or delayed idle RTT cannot
# increase the cap; five clean idle samples make only a one-percent move.
reset_case; minimum=25000; warm
repeat 2 110 120 20000
assert test "$rate" -eq 25000
reset_case; warm; rate=100000
repeat 5 22 32 500
assert test "$rate" -eq 101000
assert test "$decision" = idle-to-base
repeat 100 110 120 500
assert test "$rate" -eq 101000

# Legacy callers without absolute observation may not perform the low-util
# cliff trial. This protects callers that have not upgraded their counters.
result=$(awk -v current=130000 -v minimum=10000 -v maximum=150000 -v target=15 \
	-v utilization=15 -v state_out="$TMP/next" -f "$ALG" "$state" "$TMP/probes")
assert test "$result" = '130000 90 2 idle'
printf 'PASS hard bounds, conservative idle return and missing-observation fallback\n'
printf 'NR QoS v2 deterministic autorate replay passed (no networking or wall-clock waits)\n'
