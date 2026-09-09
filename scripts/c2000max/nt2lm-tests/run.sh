#!/bin/bash
set -euo pipefail
testdir=$(cd -- "$(dirname -- "$0")" && pwd)
src=${1:?Usage: run.sh /path/to/mt_wifi [output-dir]}
out=${2:-$(mktemp -d -t nt2lm-tests.XXXXXXXX)}
mkdir -p "$out"
out=$(cd -- "$out" && pwd)
element="$src/common/bss_mngr/bss_mngr_element.c"
nt="$src/feature/t2lm/t2lm.c"
awk '/^int parse_tid_to_link_map_ie\(/ { on=1 } on { print } on && /^}/ { exit }' "$element" > "$out/parser.inc"
awk '/^int nt2lm_t2lm_ie_link_map_to_tid_map\(/ { on=1 } on { print } on && /^}/ { exit }' "$nt" > "$out/nt-parser.inc"
awk '/^int nt2lm_peer_mld_tid_sanity_check\(/ { on=1 } on { print } on && /^}/ { exit }' "$nt" > "$out/request-sanity.inc"
awk '/^int nt2lm_peer_t2lm_rsp_sanity_check\(/ { on=1 } on { print } on && /^}/ { exit }' "$nt" > "$out/response-sanity.inc"
awk '/^void nt2lm_peer_t2lm_req_action\(/ { on=1 } on { print } on && /^}/ { exit }' "$nt" > "$out/action-dispatch.inc"
awk '/^int nt2lm_t2lm_request\(/ { found=1 } found && /t2lm_ctrl.link_map_ind =/ { on=1 } on { print } on && /END_OF_ARGS\);/ { exit }' "$nt" > "$out/tx-frame.inc"
awk '/^struct t2lm_ctrl_t \{/ { on=1 } on { print } on && /^};/ { exit }' "$src/include/feature/t2lm/t2lm.h" > "$out/control.inc"
awk '/^struct nt2lm_contract_t \{/ { on=1 } on { print } on && /^};/ { exit }' "$src/include/bss_mngr.h" > "$out/contract.inc"
awk '/^struct tid2lnk_ie_info \{/ { on=1 } on { print } on && /^};/ { exit }' "$src/include/bss_mngr.h" > "$out/struct.inc"
awk '/^#define MAX_TID_MAPPING_NUM/ { on=1 } on && /^\/\*/ { exit } on { print }' "$src/include/protocol/dot11be_eht.h" > "$out/macros.inc"
for name in parser nt-parser struct macros request-sanity response-sanity contract action-dispatch tx-frame control; do test -s "$out/$name.inc"; done
sha256sum "$element" "$nt" "$testdir/nt2lm-test.c" "$out"/*.inc > "$out/sources.sha256"
gcc -std=gnu11 -g -O1 -Wall -Wextra -Wno-unused-parameter \
    -fno-omit-frame-pointer -fsanitize=address,undefined \
    -I "$out" "$testdir/nt2lm-test.c" -o "$out/nt2lm-test"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$out/nt2lm-test"
