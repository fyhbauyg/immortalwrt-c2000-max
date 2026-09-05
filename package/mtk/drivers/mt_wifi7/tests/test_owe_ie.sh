#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
SOURCE=${1:?Usage: test_owe_ie.sh /path/to/prepared/mt_wifi/common/fsm/ap_mgmt_assoc.c}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed -n '/case EID_EXT_ECDH:/,/^#endif.*CONFIG_OWE_SUPPORT/p' "$SOURCE" > "$tmp/owe-copy-fragment.inc"
test -s "$tmp/owe-copy-fragment.inc"
gcc -Wall -Wextra -Werror -O2 -D_FORTIFY_SOURCE=3 -fsanitize=address,undefined \
 -I "$tmp" "$ROOT/test_owe_ie.c" -o "$tmp/test-owe-ie"
"$tmp/test-owe-ie"
