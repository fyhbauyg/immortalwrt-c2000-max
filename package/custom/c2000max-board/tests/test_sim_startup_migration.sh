#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/files/etc/uci-defaults/99-c2000max-sim-early-boot"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/etc/rc.d"
board_name() { printf '%s\n' "$TEST_BOARD"; }
sim_enable() { printf 'enable\n' >> "$work/enabled"; }
run_migration() {
  (source <(sed -e '\#^\. /lib/functions.sh$#d' \
    -e "s#/etc/rc.d/#$work/etc/rc.d/#g" \
    -e 's#/etc/init.d/c2000max-sim enable#sim_enable#g' "$SCRIPT"))
}
old="$work/etc/rc.d/S12c2000max-sim"
TEST_BOARD=nradio,c2000-max
ln -s ../init.d/c2000max-sim "$old"
run_migration
[[ ! -L "$old" ]] && [[ $(cat "$work/enabled") == enable ]]
run_migration
[[ ! -L "$old" ]] # Idempotent after migration.
ln -s ../init.d/unrelated "$old"
run_migration
[[ $(readlink "$old") == ../init.d/unrelated ]]
rm "$old"
ln -s ../init.d/c2000max-sim "$old"
TEST_BOARD=other,device
before=$(wc -l < "$work/enabled")
run_migration
[[ -L "$old" ]] && [[ $(wc -l < "$work/enabled") == "$before" ]]
echo 'C2000-MAX exact legacy SIM service link migration tests passed'
