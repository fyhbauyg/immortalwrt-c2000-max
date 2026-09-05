# Input 1: B host baseline / C good-count bad-count; input 2: host RTT-ms.
# All calculations are monotonic-rate bounded. No network or persistent I/O.
FILENAME == ARGV[1] {
	if ($1 == "B" && $3 + 0 > 0) baseline[$2] = $3 + 0
	if ($1 == "C") { good_run = $2 + 0; bad_run = $3 + 0 }
	next
}
{
	total++
	if (NF != 2 || $2 !~ /^[0-9]+([.][0-9]+)?$/ || $2 + 0 <= 0 || $2 + 0 > 5000) next
	rtt = $2 + 0
	healthy++
	if (!($1 in baseline)) { baseline[$1] = rtt; warming++ }
	# Only learn downward within one service session. A low ratio to the
	# configured shaper rate is not proof of idle: NR capacity may have fallen
	# far below that rate. Learning upward here would hide real congestion.
	# A route/link reconnect or service restart explicitly starts a new baseline.
	if (rtt < baseline[$1]) baseline[$1] = rtt
	delay = rtt - baseline[$1]
	if (delay < 0) delay = 0
	if (delay > target) high++
	if (delay > peak) peak = delay
}
END {
	next_rate = current; decision = "hold"
	# A missing/failed reflector freezes the rate. Require all configured
	# independent targets to be healthy and congested before backing off.
	if (healthy < 2 || healthy != total || warming) {
		good_run=0; bad_run=0; decision=(warming ? "warming" : "probe-loss")
	} else if (utilization < 70) {
		good_run=0; bad_run=0; decision="idle"
	} else if (high == healthy) {
		good_run=0; bad_run++
		if (bad_run >= 2) { next_rate=int(current*0.90); bad_run=0; decision="decrease" }
	} else if (high == 0 && peak < target/2 && utilization >= 85) {
		bad_run=0; good_run++
		if (good_run >= 3) { next_rate=int(current*1.02); if (next_rate <= current) next_rate=current+1; good_run=0; decision="increase" }
	} else { good_run=0; bad_run=0 }
	if (next_rate < minimum) next_rate=minimum
	if (next_rate > maximum) next_rate=maximum
	for (host in baseline) printf "B %s %.3f\n", host, baseline[host] > state_out
	printf "C %d %d\n", good_run, bad_run > state_out
	close(state_out)
	printf "%d %d %d %s\n", next_rate, int(peak+0.5), healthy, decision
}
