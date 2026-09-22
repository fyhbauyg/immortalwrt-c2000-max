#!/usr/bin/env bash
set -euo pipefail
stage=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=${1:-/home/wkz/c2000max-v36.01-build}
patch_file=${2:-$repo/package/mtk/drivers/mt_wifi7/patches/023-fix-ba-recipient-rcu-balance.patch}
kernel="$repo/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic"
test_root=$(mktemp -d /tmp/c2000max-ba-rcu.XXXXXX)
printf 'Generated test artifacts: %s\n' "$test_root"
sha256sum "$kernel/mt_wifi7/mt_wifi/common/ba_action.c" "$kernel/mt_hwifi/mt_wifi/common/ba_action.c"
cmp "$kernel/mt_wifi7/mt_wifi/common/ba_action.c" "$kernel/mt_hwifi/mt_wifi/common/ba_action.c"
for tree in mt_wifi7 mt_hwifi; do
  for version in original fixed; do
    variant="$test_root/$tree/$version"
    mkdir -p "$variant/mt_wifi/common"
    cp "$kernel/$tree/mt_wifi/common/ba_action.c" "$variant/mt_wifi/common/ba_action.c"
    if grep -Fq 'A concurrent teardown may already have released this BA entry.' "$variant/mt_wifi/common/ba_action.c"; then
      if [ "$version" = original ]; then
        patch --batch --fuzz=0 -R -d "$variant" -p1 < "$patch_file"
      fi
    elif [ "$version" = fixed ]; then
      patch --batch --fuzz=0 -d "$variant" -p1 < "$patch_file"
    fi
    # Extract the actual current function rather than testing a hand-copied body.
    awk '/^VOID ba_free_rec_entry\(/ { copying=1 } copying { print } copying && /^}/ { exit }' \
      "$variant/mt_wifi/common/ba_action.c" > "$variant/ba_free_rec_entry.inc"
    test "$(grep -c '^VOID ba_free_rec_entry(' "$variant/ba_free_rec_entry.inc")" -eq 1
    for eht in enabled disabled; do
      flags=()
      [ "$eht" != enabled ] || flags=(-DDOT11_EHT_BE=1)
      gcc -std=c99 -Wall -Wextra -Werror -Wno-unused-label -fsanitize=undefined \
        "${flags[@]}" -I "$variant" "$stage/ba_rcu_regression.c" -o "$variant/harness-$eht"
      set +e
      "$variant/harness-$eht" > "$variant/result-$eht.txt" 2>&1
      result=$?
      set -e
      printf '%s/%s/EHT-%s exit=%s\n' "$tree" "$version" "$eht" "$result"
      cat "$variant/result-$eht.txt"
      if [ "$version" = original ] && [ "$eht" = enabled ]; then
        test "$result" -eq 1
        grep -q '^none: FAIL;' "$variant/result-$eht.txt"
        grep -q '^repeated: FAIL;' "$variant/result-$eht.txt"
        grep -q '^mlo-repeated: FAIL;' "$variant/result-$eht.txt"
      else
        test "$result" -eq 0
      fi
    done
  done
done
printf 'PASS: original EHT underflow reproduced; fixed branches and non-EHT unchanged.\n'
