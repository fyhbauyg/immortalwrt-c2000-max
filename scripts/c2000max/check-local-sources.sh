#!/bin/sh
# Fail explicitly instead of silently mixing other vendor SDK generations.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$script_dir/../.." && pwd)
missing=0
for archive in c2000max-deco-wifi-765c6bef-source.tar.xz mt_wifi_osal-a53418.tar.xz warp_20250919-9c1cfa.tar.xz; do
 if [ ! -s "$repo/local-sources/$archive" ]; then
  printf 'Missing required vendor source: local-sources/%s\n' "$archive" >&2
  missing=1
 fi
done
if [ "$missing" -ne 0 ]; then
 printf 'Prepare authorized archives as described in local-sources/README.md; no old-driver fallback is allowed.\n' >&2
 exit 1
fi
cd "$repo/local-sources"
sha256sum -c <<'CHECKSUMS'
847e6794beb86713fc9ab08f620e78dca3b537bb1677960937f6ec66a430ccd3  c2000max-deco-wifi-765c6bef-source.tar.xz
dfa4b178f198504a707dec957242f8ede1a732823e940faa6304c723ac3224ad  mt_wifi_osal-a53418.tar.xz
f644bb165b0c1d05167d09dea91a678b7304238dae82dfe541bfd3e2920be28a  warp_20250919-9c1cfa.tar.xz
CHECKSUMS
