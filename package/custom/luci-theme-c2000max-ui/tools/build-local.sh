#!/bin/bash
set -euo pipefail
repo="$(cd "${OPENWRT_ROOT:?Set OPENWRT_ROOT to your configured OpenWrt build tree}" && pwd)"
src="$(cd "$(dirname "$0")/.." && pwd)"
dest="$repo/package/custom/luci-theme-c2000max-ui"
mkdir -p "$src/build" "$dest"
[ -f "$repo/feeds/luci/luci.mk" ] || { echo 'Configure the LuCI feed first.' >&2; exit 1; }
if [ "$src" != "$(cd "$dest" && pwd)" ]; then
 cp -a "$src/Makefile" "$src/htdocs" "$src/root" "$src/ucode" "$dest/"
fi
# Windows checkout does not retain executable bits.
find "$dest/htdocs" "$dest/root" "$dest/ucode" -type f -exec chmod 644 {} +
find "$dest/htdocs" "$dest/root" "$dest/ucode" -type d -exec chmod 755 {} +
chmod 755 "$dest/root/etc/init.d/c2000max-wallpaper" "$dest/root/usr/libexec/c2000max-bing" "$dest/root/www/cgi-bin/c2000max-wallpaper" "$dest/root/etc/uci-defaults/95-c2000max-ui"
export PATH="$repo/staging_dir/host/bin:${BUILD_TOOL_PATH:+$BUILD_TOOL_PATH:}$PATH"
cd "$repo"
before="$(sha256sum .config)"
make -j"${JOBS:-2}" V=s CONFIG_PACKAGE_luci-theme-c2000max-ui=m package/custom/luci-theme-c2000max-ui/compile > "$src/build/package-build.log" 2>&1 || { tail -70 "$src/build/package-build.log"; exit 1; }
after="$(sha256sum .config)"
[ "$before" = "$after" ] || { echo '.config changed during make; inspect before proceeding'; exit 1; }
version="$(sed -n 's/^PKG_VERSION:=//p' "$src/Makefile" | tr -d '\r')"
release="$(sed -n 's/^PKG_RELEASE:=//p' "$src/Makefile" | tr -d '\r')"
find "$repo/bin/packages" -name "luci-theme-c2000max-ui-${version}-r${release}.apk" -exec cp {} "$src/build/" \;
[ -f "$src/build/luci-theme-c2000max-ui-${version}-r${release}.apk" ] || { echo 'Expected APK was not produced.' >&2; exit 1; }
echo "Build complete. Original .config preserved."
