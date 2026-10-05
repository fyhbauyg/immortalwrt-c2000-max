#!/bin/bash
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"
ucode=("${UCODE_BIN:-ucode}")
if [ -n "${UCODE_LIB_DIR:-}" ]; then ucode+=(-L "$(cd "$UCODE_LIB_DIR" && pwd)"); fi
ucode+=(-L "$src/tests/stubs")
mkdir -p "$src/build/preview"
for file in "$src"/ucode/template/themes/c2000max-ui/*.ut; do
 "${ucode[@]}" -T -c -o "$src/build/template.uc" "$file"
done
"${ucode[@]}" -c -o "$src/build/rpc.uc" "$src/root/usr/share/rpcd/ucode/c2000max-ui"
"${ucode[@]}" "$src/tests/render.uc" "$src" "$src/build/preview"
for file in "$src/root/etc/init.d/c2000max-wallpaper" "$src/root/usr/libexec/c2000max-bing" "$src/root/www/cgi-bin/c2000max-wallpaper" "$src/root/etc/uci-defaults/95-c2000max-ui"; do
 /bin/sh -n "$file"
done
bootstrap="${BOOTSTRAP_CSS:-${OPENWRT_ROOT:+$OPENWRT_ROOT/feeds/luci/themes/luci-theme-bootstrap/htdocs/luci-static/bootstrap/cascade.css}}"
if [ -n "$bootstrap" ] && [ -f "$bootstrap" ]; then
 mkdir -p "$src/build/preview/bootstrap"
 cp "$bootstrap" "$src/build/preview/bootstrap/"
else
 echo 'Set BOOTSTRAP_CSS or OPENWRT_ROOT before browser preview/tests.' >&2
 exit 1
fi
