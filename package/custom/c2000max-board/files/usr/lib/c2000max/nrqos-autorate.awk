# SPDX-License-Identifier: GPL-2.0-or-later
# Original C2000MAX implementation. The load/latency, min/base/max and
# refractory-period design was informed by cake-autorate v3.2.1 (GPLv2):
# https://github.com/lynxthecat/cake-autorate/tree/v3.2.1
# No upstream source code is embedded here.
#
# Input 1: B host baseline / C good bad / T rollback delay age improved /
#          S frozen recovered idle cooldown. Input 2: unique host RTT-ms.
# Parameters: current, minimum, maximum, target, utilization, state_out;
# optional observed_kbit (actual directional kbit/s), base_rate.
# Output: next-kbit peak-delay-ms healthy-probes decision (four fields).
# Invoke once per sampling interval, with independent state per direction.
#
# RTT cannot identify the congested direction, distinguish radio scheduling
# jitter from queues, or prove an HNAT path. A bounded trial tests whether
# lowering this direction helps; no improvement restores the previous rate.
function numeric(value) { return value ~ /^[0-9]+([.][0-9]+)?$/ }
function clamp(value) {
	if (value < minimum) value = minimum
	if (value > maximum) value = maximum
	return int(value)
}
function reset_trial() {
	rollback_rate = 0; reference_delay = 0; trial_age = 0; improved_run = 0
}
FILENAME == ARGV[1] {
	if ($1 == "B" && numeric($3) && $3 + 0 > 0) baseline[$2] = $3 + 0
	if ($1 == "C") { good_run = $2 + 0; bad_run = $3 + 0 }
	if ($1 == "T") {
		rollback_rate = $2 + 0; reference_delay = $3 + 0
		trial_age = $4 + 0; improved_run = $5 + 0
	}
	if ($1 == "S") {
		frozen = $2 + 0; recovered_run = $3 + 0
		idle_run = $4 + 0; cooldown = $5 + 0
	}
	next
}
{
	total++
	# Duplicate lines are not independent evidence, nor are failed probes.
	if (NF != 2 || seen[$1]++ || !numeric($2) || $2 + 0 <= 0 || $2 + 0 > 5000) next
	rtt = $2 + 0; healthy++
	if (!($1 in baseline)) { baseline[$1] = rtt; warming++ }
	# Never learn a persistent NR capacity collapse into the baseline.
	# Reconnect/service restart explicitly resets baselines for a new path.
	if (rtt < baseline[$1]) baseline[$1] = rtt
	delay = rtt - baseline[$1]
	if (delay < 0) delay = 0
	if (delay > target) high++
	if (delay > peak) peak = delay
	if (healthy == 1 || delay < common_delay) common_delay = delay
}
END {
	current = clamp(current); next_rate = current; decision = "hold"
	have_load = numeric(observed_kbit)
	base = numeric(base_rate) && base_rate + 0 > 0 ? clamp(base_rate) : current
	# A few game/ACK packets must not be mistaken for a saturated NR link.
	# Require absolute activity as well as reflector agreement. The relative
	# utilization gate alone fails when capacity falls from 130 to 20 Mbps.
	active_floor = base * 0.02
	if (active_floor < 1000) active_floor = 1000
	if (active_floor > 5000) active_floor = 5000
	active = have_load ? observed_kbit + 0 >= active_floor : utilization >= 70
	clear = high == 0 && peak < target / 2
	complete = healthy >= 2 && healthy == total && !warming
	if (!complete) {
		good_run = 0; bad_run = 0; recovered_run = 0; idle_run = 0
		decision = warming ? "warming" : "probe-loss"
		# Do not leave an unverified low-rate trial in place if its evidence
		# disappears. Normal probe loss otherwise freezes the current rate.
		if (rollback_rate > 0) {
			next_rate = rollback_rate; reset_trial(); frozen = 1
			decision = "probe-loss-restore"
		}
	} else if (rollback_rate > 0) {
		good_run = 0; bad_run = 0; idle_run = 0; trial_age++
		if (!active) {
			# Traffic ending is not evidence that the trial cured congestion.
			next_rate = rollback_rate; reset_trial(); cooldown = 2
			decision = "trial-idle-restore"
		} else {
			# Every reflector must improve, not just the fastest single host.
			if (clear || peak <= reference_delay * 0.75) improved_run++
			else improved_run = 0
			if (improved_run >= 2) {
				reset_trial(); cooldown = 2; decision = "trial-accepted"
			} else if (trial_age >= 4) {
				next_rate = rollback_rate; reset_trial(); frozen = 1
				recovered_run = 0; decision = "trial-unresponsive-restore"
			} else decision = "trial-observe"
		}
	} else if (frozen) {
		good_run = 0; bad_run = 0; idle_run = 0
		if (clear) recovered_run++; else recovered_run = 0
		if (recovered_run >= 3) {
			frozen = 0; recovered_run = 0; decision = "recovered"
		} else decision = "delay-unresponsive"
	} else if (cooldown > 0) {
		cooldown--; good_run = 0; bad_run = 0; idle_run = 0
		decision = "cooldown"
	} else if (!active) {
		good_run = 0; bad_run = 0; decision = "idle"
		# Return slowly toward the configured base only after clean idle RTT.
		# Missing absolute-load input must never trigger aggressive adaptation.
		if (have_load && clear) idle_run++; else idle_run = 0
		if (idle_run >= 5) {
			step = int(current * 0.01); if (step < 1) step = 1
			if (current < base) { next_rate = current + step; if (next_rate > base) next_rate = base }
			if (current > base) { next_rate = current - step; if (next_rate < base) next_rate = base }
			idle_run = 0; if (next_rate != current) decision = "idle-to-base"
		}
	} else if (high == healthy) {
		good_run = 0; idle_run = 0; bad_run++
		if (bad_run >= 2) {
			candidate = int(current * 0.90)
			# A large capacity collapse needs a test below observed throughput,
			# rather than small cuts that remain above the true bottleneck.
			if (have_load && candidate > observed_kbit * 0.90) candidate = int(observed_kbit * 0.90)
			candidate = clamp(candidate); bad_run = 0
			if (candidate < current) {
				rollback_rate = current; reference_delay = common_delay
				trial_age = 0; improved_run = 0; next_rate = candidate
				decision = "decrease-trial"
			} else decision = "at-minimum"
		}
	} else if (clear && utilization >= 85) {
		bad_run = 0; idle_run = 0; good_run++
		if (good_run >= 3) {
			next_rate = int(current * 1.02)
			if (next_rate <= current) next_rate = current + 1
			good_run = 0; decision = "increase"
		}
	} else { good_run = 0; bad_run = 0; idle_run = 0 }
	next_rate = clamp(next_rate)
	for (host in baseline) printf "B %s %.3f\n", host, baseline[host] > state_out
	printf "C %d %d\n", good_run, bad_run > state_out
	printf "T %d %.3f %d %d\n", rollback_rate, reference_delay, trial_age, improved_run > state_out
	printf "S %d %d %d %d\n", frozen, recovered_run, idle_run, cooldown > state_out
	close(state_out)
	printf "%d %d %d %s\n", next_rate, int(peak + 0.5), healthy, decision
}
