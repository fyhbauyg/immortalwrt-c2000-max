#!/bin/bash
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_tree=${1:?Usage: run-sta-tests.sh /path/to/mt_wifi [output-directory]}
output_dir=${2:-$(mktemp -d -t ttlm-sta-tests.XXXXXXXX)}
test -f "$source_tree/common/mld_link_mgr.c"
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)

# Extract the real function preamble verbatim, ending before any ML parsing or
# peer creation. No copy of the production condition is maintained in the test.
awk '
/^int sta_mld_conn_req\(/ { in_function = 1; next }
in_function && /if \(mld != &mld_device\)/ { in_preamble = 1 }
in_preamble && /if \(mld_conn->ml_ie\) \{/ { finished = 1; exit }
in_preamble {
    print
    line++
    if (/parse_tid_to_link_map_ie/) parse_line = line
    if (/sta_mld_disconn_req/) disconnect_line = line
    if (/os_alloc_mem|peer->valid[[:space:]]*=/) premature_mutation = 1
}
END {
    if (!finished || !parse_line || !disconnect_line ||
        parse_line >= disconnect_line || premature_mutation) exit 1
}
' "$source_tree/common/mld_link_mgr.c" > "$output_dir/sta-preamble.inc"
test -s "$output_dir/sta-preamble.inc"

cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer -g -I"$output_dir" \
    "$test_dir/sta-preamble-test.c" -o "$output_dir/sta-preamble-test"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$output_dir/sta-preamble-test"
