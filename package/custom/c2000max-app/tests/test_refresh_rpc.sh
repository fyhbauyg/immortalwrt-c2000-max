#!/bin/sh
# Only evaluates the argument-normalization helpers, never status/set/restart.
set -eu
root="${1:?package root required}"
rpc="$root/../luci-app-c2000max-app/root/usr/libexec/rpcd/c2000max_app"
eval "$(awk '/^normalize_bool\(\)/ { take=1 } /^status\(\)/ { take=0 } take { print }' "$rpc")"
count=0
for spec in modem_cache_interval:1:60:10 selector_cache_interval:1:60:15 \
 cache_warm_interval:1:60:2 cache_idle_interval:5:300:30 \
 cache_active_window:30:900:180 signal_normal_interval:1:30:3 \
 signal_test_interval:1:10:1 signal_carrier_interval:2:120:10 \
 presence_interval:2:60:2 status_interval:10:300:30 report_interval:60:3600:300; do
 oldifs="$IFS"; IFS=:; set -- $spec; IFS="$oldifs"
 number_limits "$1"
 test "$minimum:$maximum:$fallback" = "$2:$3:$4"
 test "$(normalize_number "$minimum" "$minimum" "$maximum")" = "$minimum"
 test "$(normalize_number "$maximum" "$minimum" "$maximum")" = "$maximum"
 test "$(normalize_number "$fallback" "$minimum" "$maximum")" = "$fallback"
 ! normalize_number "$((minimum - 1))" "$minimum" "$maximum" >/dev/null
 ! normalize_number "$((maximum + 1))" "$minimum" "$maximum" >/dev/null
 for invalid in '' -1 1.5 nope '2;echo invalid'; do
  ! normalize_number "$invalid" "$minimum" "$maximum" >/dev/null
 done
 count=$((count + 1))
done
! number_limits unknown_option
test "$(normalize_bool true)" = 1
test "$(normalize_bool false)" = 0
! normalize_bool 2
printf 'PASS: %s RPC interval defaults/ranges, invalid values, boolean validation\n' "$count"
