#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT="$ROOT/files/etc/init.d/c2000max-sim"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
events="$work/events"
touch "$events"

# Run the actual init wrapper with only external side effects redirected.
# No GPIO, AT port, system directory or persistent configuration is touched.
source <(sed -e "s#/tmp/c2000max-sim-boot.json#$work/state.json#g" \
  -e "s#/var/run/c2000max-sim-boot.pid#$work/worker.pid#g" \
  -e "s#/var/run/c2000max-sim-boot.status#$work/worker.status#g" \
  -e "s#/tmp/c2000max-sim-boot.timeline#$work/timeline#g" \
  -e 's#/usr/sbin/c2000max-sim#sim_mock#g' "$INIT")
[[ $START == 09 ]] || { echo 'FAIL: modem preparation is not before S10boot'; exit 1; }
mkdir() { printf 'mkdir %s\n' "$*" >> "$events"; }
chmod() { printf 'chmod %s\n' "$*" >> "$events"; }
logger() { :; }
ubus() { printf 'at-daemon\n'; }
sim_mock() {
  printf '%s\n' "$1" >> "$events"
  case "$1" in
    boot-prepare) [[ $(wc -l < "$events") == 4 ]] ;;
    boot-restore) [[ ${C2000MAX_SIM_SKIP_BOOT_PREPARE:-0} == 1 ]] ;;
    *) return 1 ;;
  esac
}
boot
wait
[[ $(cat "$work/worker.status") == ready ]] || { echo 'FAIL: SIM worker did not publish ready'; exit 1; }
[[ ! -e "$work/worker.pid" ]] || { echo 'FAIL: stale worker PID after successful exit'; exit 1; }
expected=$'mkdir -p /var/lock /var/run /tmp/.uci\nchmod 1777 /var/lock\nchmod 0700 /tmp/.uci\nboot-prepare\nboot-restore'
[[ $(cat "$events") == "$expected" ]] || {
  echo 'FAIL: early dependencies/power preparation/AT verification ordering'
  cat "$events"
  exit 1
}
before=$(grep -c '^boot-prepare$' "$events")
boot
wait
[[ $(grep -c '^boot-prepare$' "$events") == "$before" ]] || {
  echo 'FAIL: duplicate old/new service links cause another modem power cycle'
  exit 1
}
echo 'C2000-MAX early SIM boot ordering tests passed'
