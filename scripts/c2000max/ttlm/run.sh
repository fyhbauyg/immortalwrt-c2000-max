#!/bin/bash
set -euo pipefail
testdir=$(cd -- "$(dirname -- "$0")" && pwd)
# Usage: run.sh [base|work|/absolute/path/to/mt_wifi] [all|nonnull|null|boundary]
#               [/absolute/path/to/Linux/include/linux/ieee80211.h]
# An explicit source directory makes this reusable after patch integration.
tree=${1:-work}
case "$tree" in
    base|work) src="$testdir/../$tree/mt_wifi"; label="$tree" ;;
    *) src=$(cd -- "$tree" && pwd); label=custom ;;
esac
out=${TTLM_TEST_OUT:-"$testdir/generated-$label"}
mkdir -p "$out"
element="$src/common/bss_mngr/bss_mngr_element.c"
awk '/^u8 \*build_tid_to_link_map_ie\(/ { on=1 } on { print } on && /^}/ { exit }' "$element" > "$out/builder.inc"
awk '/^int parse_tid_to_link_map_ie\(/ { on=1 } on { print } on && /^}/ { exit }' "$element" > "$out/parser.inc"
awk '/^struct tid2lnk_ie_info \{/ { on=1 } on { print } on && /^};/ { exit }' "$src/include/bss_mngr.h" > "$out/struct.inc"
awk '/^#define MAX_TID_MAPPING_NUM/ { on=1 } on && /^\/\*/ { exit } on { print }' "$src/include/protocol/dot11be_eht.h" > "$out/macros.inc"
awk '/if \(HAS_EHT_ML_T2LM_EXIST\(ie_list->cmm_ies.ie_exists\)\)/ || /if \(pEid->Len >= 1 && pEid->Octet\[0\] == EID_EXT_EHT_TID2LNK_MAP\)/ { on=1 } on && /\/\*parse reconfiguration/ { exit } on { print }' "$src/common/cmm_sanity.c" > "$out/dispatch.inc"
awk '/get variable fields from payload and advance the pointer/ { found=1; next } found && /while \(/ { on=1 } on { print } on && /\{/ { exit }' "$src/common/cmm_sanity.c" > "$out/loop-guard.inc"
linux=${3:-}
if [ -z "$linux" ]; then
    repo=$(cd -- "$testdir/../../.." && pwd)
    shopt -s nullglob
    linux_headers=("$repo"/build_dir/target-*/linux-*/linux-6.*/include/linux/ieee80211.h)
    shopt -u nullglob
    if [ "${#linux_headers[@]}" -ne 1 ]; then
        printf 'Expected one prepared Linux 6.x header; pass its absolute path as argument 3.\n' >&2
        exit 2
    fi
    linux=${linux_headers[0]}
fi
awk '/^static inline bool ieee80211_tid_to_link_map_size_ok\(/ { on=1 } on { print } on && /^}/ { exit }' "$linux" > "$out/linux-size.inc"
test -s "$out/parser.inc"
test -s "$out/builder.inc"
test -s "$out/struct.inc"
test -s "$out/macros.inc"
test -s "$out/dispatch.inc"
test -s "$out/loop-guard.inc"
test -s "$out/linux-size.inc"
sha256sum "$element" "$src/include/bss_mngr.h" "$src/include/protocol/dot11be_eht.h" "$src/common/cmm_sanity.c" "$linux" "$testdir/ttlm-test.c" "$out"/*.inc > "$out/source-sha256.txt"
gcc -std=gnu11 -g -O1 -Wall -Wextra -Wno-unused-parameter -fno-omit-frame-pointer -fsanitize=address,undefined -I "$out" "$testdir/ttlm-test.c" -o "$out/ttlm-test"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$out/ttlm-test" "${2:-all}"
