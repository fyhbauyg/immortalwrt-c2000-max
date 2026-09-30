#!/bin/sh
. /lib/functions.sh

config_name="qmodem"
config_section=$1
init_type=$2

case $init_type in
    post_init)
        # pre-add at commands
        cfg_prefix="post_init"
        debug_subject="post_init"
        ;;
    pre_dial)
        # pre-dial at commands
        cfg_prefix="pre_dial"
        debug_subject="pre_dial"
        ;;
    *)
        logger -t modem_hook "init_type error: $init_type"
        exit 1
        ;;
esac

_execute_ats(){
    command=$1
    res=$(at $at_port $command | tr -d '\r')
    m_debug "execute_ats $config_section: $command $at_port"
    m_debug "execute_ats_result $config_section: $res"
}

. /usr/share/qmodem/modem_util.sh
config_load ${config_name}

config_get delay "$config_section" "${cfg_prefix}_delay" 0

config_get at_port "$config_section" at_port
config_get override_at_port "$config_section" override_at_port
[ -z "$override_at_port" ] || at_port="$override_at_port"

if [ ! -c "$at_port" ]; then
    m_debug "$config_section: AT port is not a character device"
    m_debug "at_port $config_section: $at_port"
    exit 1
fi

case "$delay" in ''|*[!0-9]*) delay=0 ;; esac
if [ "$delay" -gt 0 ]; then
    sleep "$delay"
fi



config_list_foreach $config_section ${cfg_prefix}_at_cmds   _execute_ats
# USB rediscovery and the SIM worker can finish in either order. Replay the
# saved opt-in lock after pre-dial commands too, once the SIM boot gate and
# modem preparation have completed. Never erase settings on an AT failure.
qmodem_lockcell_boot_hook_replay "$config_section" "$at_port"
