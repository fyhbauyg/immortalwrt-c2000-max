#!/bin/sh
set -eu
calls=''
config_load() { :; }
config_get_bool() { enabled=0; }
stop_service() { calls="${calls}cleanup "; }
stop() { calls="${calls}stop "; }
start() { calls="${calls}start "; }
start_service() {
	local enabled mode
	config_load accelerator
	config_get_bool enabled base enabled 0
	[ "$enabled" -eq 1 ] || { stop_service; return 0; }
	[ -x "$BIN" ] || {
		logger -t leigod "missing accelerator binary: $BIN"
		return 1
	}

	mode="$(sed -n 's/^mode=//p' /etc/config/acc_firewall.ini | head -1)"
	case "$mode" in tun|tproxy) ;; *) logger -t leigod "invalid acceleration mode"; return 1 ;; esac
	# Suspend fast paths while the accelerator must inspect forwarded traffic.
	touch /var/run/c2000max-leigod-active
	[ ! -x /etc/init.d/c2000max-hnat ] || /etc/init.d/c2000max-hnat reload
	procd_open_instance
	procd_set_param command "$BIN" -r daemon -m "$mode" -p 5588
	[ "$mode" != tproxy ] || procd_append_param command -l 0.0.0.0
	procd_set_param file /etc/config/accelerator.ini /etc/config/acc_firewall.ini
	procd_set_param env ACC_FIREWALL_INI=/etc/config/acc_firewall.ini
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param limits nofile="65535 65535"
	procd_close_instance
}

reload_service() {
 stop
 start
}

start_service
[ "$calls" = 'cleanup ' ]
calls=''
reload_service
[ "$calls" = 'stop start ' ]
echo 'PASS: disabled start cleans state; LuCI reload executes full stop/start'
