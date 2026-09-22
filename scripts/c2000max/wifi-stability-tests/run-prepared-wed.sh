#!/bin/bash
set -euo pipefail
stage=$(cd "$(dirname "$0")" && pwd)
repo=${1:?Usage: run-prepared-wed.sh /path/to/openwrt}
kernel="$repo/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic"
scratch=$(mktemp -d /tmp/c2000max-wifi-validation.XXXXXX)
printf 'Fault-injection inputs and hashes: %s\n' "$scratch"
for file in warp_main.c warp_rx_bm.c warp_rx_page_bm.c warp_tx_bm_v2.c wed.c; do
    cp "$kernel/warp/$file" "$scratch/$file"
done
cp "$kernel/mt_hwifi/wlan_hwifi/bus/mtk_wed.c" "$scratch/mtk_wed.c"
sha256sum "$scratch"/*.c > "$scratch/source-inputs.sha256"
for test in test-wed-init.py test-bm-faults.py test-hif-faults.py test-warp-ref.py; do
    python3 "$stage/wed/$test" "$scratch"
done
echo 'PASS: actual prepared WED/WARP source fault-path regressions'
