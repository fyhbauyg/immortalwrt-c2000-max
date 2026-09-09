#!/bin/sh
name="${0##*/}"
printf '%s %s\n' "$name" "$1" >> "$LED_TEST_TMP/services"
case "$name:$1" in
	qmodem:running) [ -f "$LED_TEST_TMP/qmodem-running" ]; exit $? ;;
	qmodem:enabled) [ -f "$LED_TEST_TMP/qmodem-enabled" ]; exit $? ;;
	qmodem:stop) rm -f "$LED_TEST_TMP/qmodem-running" ;;
	qmodem:start) : > "$LED_TEST_TMP/qmodem-running" ;;
	system:reload)
		if [ -f "$LED_TEST_TMP/user-config-off" ]; then
			printf 'none\n' > "$C2000MAX_LED_SYSFS/blue:status/trigger"
			printf '0\n' > "$C2000MAX_LED_SYSFS/blue:status/brightness"
		fi
		;;
esac
exit 0
