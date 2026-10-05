#!/bin/bash
set -euo pipefail
repo="$(cd "${OPENWRT_ROOT:?Set OPENWRT_ROOT to your configured OpenWrt build tree}" && pwd)"
src="$(cd "$(dirname "$0")/.." && pwd)"
build="${UCODE_BUILD_DIR:-$src/build/ucode}"
source="${UCODE_SOURCE:-$(find "$repo/build_dir" -maxdepth 2 -type d -name 'ucode-[0-9]*' | sort | tail -1)}"
[ -f "$source/CMakeLists.txt" ] || { echo 'Build the ucode package first or set UCODE_SOURCE.' >&2; exit 1; }
export PATH="$repo/staging_dir/host/bin:$PATH"
export PKG_CONFIG_PATH="$repo/staging_dir/host/lib/pkgconfig"
export STAGING_DIR_HOST="$repo/staging_dir/host"
export STAGING_DIR_HOSTPKG="$repo/staging_dir/hostpkg"
export STAGING_PREFIX="$repo/staging_dir/host"
mkdir -p "$build"
cmake -S "$source" -B "$build" -UHAVE_PARSE_END -UHAVE_ARRAY_EXT -UHAVE_JSON_UINT64 -DUBUS_SUPPORT=OFF -DUCI_SUPPORT=OFF -DULOOP_SUPPORT=OFF -DFS_SUPPORT=ON -DRTNL_SUPPORT=OFF -DNL80211_SUPPORT=OFF -DDIGEST_SUPPORT=OFF > "$build/config.log" 2>&1
cmake --build "$build" -j"${JOBS:-4}" > "$build/build.log" 2>&1
echo "Validation runtime: $build/ucode"
echo "Module directory: $build"
