#!/bin/sh

# Sourced by modem_dial.sh. This file performs no work at import time.
# The init worker owns the PID/status files; never delete or signal it here.
qmodem_sim_boot_log() {
	local gate_uptime gate_idle
	read -r gate_uptime gate_idle < /proc/uptime
	logger -t qmodem_network "[uptime=${gate_uptime:-unknown}] $*"
}

qmodem_sim_boot_worker_active() {
	local pidfile="$1" procroot="$2" gate_pid gate_command
	gate_pid="$(cat "$pidfile" 2>/dev/null)"
	case "$gate_pid" in ''|*[!0-9]*) return 1 ;; esac
	[ "$gate_pid" -gt 1 ] 2>/dev/null || return 1
	[ -r "$procroot/$gate_pid/cmdline" ] || return 1
	# A stale/reused PID must not hold unrelated modems off. Check argv tokens
	# for both the exact init script and its boot action, not a substring PID.
	# Empty cmdline also excludes zombies. Reading /proc does not signal it.
	gate_command="$(tr '\000' '\n' < "$procroot/$gate_pid/cmdline" 2>/dev/null)"
	printf '%s\n' "$gate_command" |
		grep -Eq '^/etc/(init\.d/c2000max-sim|rc\.d/S[0-9][0-9]c2000max-sim)$' || return 1
	printf '%s\n' "$gate_command" | grep -qx boot
}

qmodem_sim_boot_shutdown_guard() {
	[ -e "$1" ] || return 0
	qmodem_sim_boot_log "system shutdown in progress; defer dial for procd retry"
	return 75
}

qmodem_sim_boot_wait() {
	local pidfile="$1" statusfile="$2" procroot="$3"
	local limit="${4:-120}" waited=0 boot_status
	local shutdown_marker="${5:-/tmp/c2000max-sim-shutdown}"
	qmodem_sim_boot_shutdown_guard "$shutdown_marker" || return 75
	case "$limit" in ''|*[!0-9]*) limit=120 ;; esac
	[ "$limit" -ge 1 ] 2>/dev/null || limit=1
	[ "$limit" -le 300 ] 2>/dev/null || limit=300
	while qmodem_sim_boot_worker_active "$pidfile" "$procroot"; do
		qmodem_sim_boot_shutdown_guard "$shutdown_marker" || return 75
		if [ "$waited" -ge "$limit" ]; then
			qmodem_sim_boot_log "SIM boot worker still active after ${waited}s; defer dial for procd retry"
			return 75
		fi
		if [ "$waited" = 0 ]; then
			qmodem_sim_boot_log "waiting for SIM boot routing before dial"
		fi
		sleep 1
		waited=$((waited + 1))
	done
	# stop may publish its marker while the worker is exiting. The absence
	# of a worker is not permission to start a fresh dial during shutdown.
	qmodem_sim_boot_shutdown_guard "$shutdown_marker" || return 75
	boot_status="$(cat "$statusfile" 2>/dev/null)"
	case "$boot_status" in
		ready)
			qmodem_sim_boot_log "SIM boot ready; continue dial (waited=${waited}s)" ;;
		failed|pending)
			# A failed/aborted worker cannot switch CFUN any more. Allow normal
			# dialing/recovery instead of waiting forever for a success marker.
			qmodem_sim_boot_log "SIM boot worker ended (state=$boot_status); continue dial (waited=${waited}s)" ;;
		*)
			[ "$waited" = 0 ] ||
				qmodem_sim_boot_log "SIM boot worker ended; continue dial (waited=${waited}s)" ;;
	esac
	return 0
}

qmodem_wait_for_c2000max_sim_boot() {
	local gate_board
	[ -r /tmp/sysinfo/board_name ] || return 0
	read -r gate_board < /tmp/sysinfo/board_name
	[ "$gate_board" = 'nradio,c2000-max' ] || return 0
	qmodem_sim_boot_shutdown_guard /tmp/c2000max-sim-shutdown || return 75
	qmodem_sim_boot_wait /var/run/c2000max-sim-boot.pid \
		/var/run/c2000max-sim-boot.status /proc 120
}
