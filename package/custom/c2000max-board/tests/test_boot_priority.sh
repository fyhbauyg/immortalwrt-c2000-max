#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
helper="$ROOT/files/usr/sbin/c2000max-boot-priority"
sh -n "$helper"
testdir=$(mktemp -d)
trap 'rm -rf "$testdir"' EXIT
# Load function definitions only. Mock storage boundaries; no device is written.
source <(sed '/^case "${1:-status}" in/,$d' "$helper")
trap 'rm -rf "$testdir"' EXIT
result() { printf '%s:%s:%s:%s\n' "$1" "$2" "$CURRENT" "$MIGRATE"; }
prepare() {
 WORK="$testdir/work"; mkdir -p "$WORK"
 WRITABLE=$RW
 [[ "$CRC_OK" == 1 ]] || return 1
 cp "$testdir/env" "$WORK/before"
 CURRENT=$(env_get boot_from_sd) || return 1
 [[ "$CURRENT" == 0 || "$CURRENT" == 1 ]]
}
fw_printenv() {
 [[ "$CRC_OK" == 1 ]] || return 1
 if [[ "$#" == 2 ]]; then cat "$testdir/env"; return; fi
 local line
 line=$(grep -m1 "^$4=" "$testdir/env") || return 1
 printf '%s\n' "${line#*=}"
}
fw_setenv() {
 echo write >> "$testdir/writes"
 [[ "$WRITE_OK" == 1 ]] || return 1
 [[ "$READBACK_OK" == 1 ]] || return 0
 local key value
 while read -r key value; do
  grep -v "^$key=" "$testdir/env" > "$testdir/next" || true
  [[ -z "$value" ]] || printf '%s=%s\n' "$key" "$value" >> "$testdir/next"
  mv "$testdir/next" "$testdir/env"
 done < "$4"
 if [[ "$CORRUPT_OTHER" == 1 ]]; then echo 'other=changed' >> "$testdir/env"; fi
}
reset_env() {
 printf 'boot_from_sd=1\nboot_system=0\nserial=keep-me\n' > "$testdir/env"
 : > "$testdir/writes"
 CRC_OK=1 WRITE_OK=1 READBACK_OK=1 CORRUPT_OTHER=0 RW=1024
 CURRENT= MIGRATE=0 WORK=
 BACKUP="$testdir/backup/env.bin"
 rm -f "$BACKUP"
 ENV_MTD="$testdir/raw.bin"
 dd if=/dev/zero of="$ENV_MTD" bs=65536 count=1 status=none
}
refuse_without_write() {
 if set_priority flash > "$testdir/result"; then echo 'unsafe change accepted'; exit 1; fi
 grep -q '^0:0:' "$testdir/result"
 [[ ! -s "$testdir/writes" ]]
}
reset_env
[[ "$(status)" == 1:0:1:0 ]]
[[ ! -e "$BACKUP" && ! -s "$testdir/writes" ]]
[[ "$(set_priority sd)" == 1:1:1:0 ]]
[[ ! -e "$BACKUP" && ! -s "$testdir/writes" ]]
[[ "$(set_priority flash)" == 1:1:0:0 ]]
[[ $(wc -c < "$BACKUP") == 65536 && $(stat -c %a "$BACKUP") == 600 ]]
before=$(sha256sum "$BACKUP")
[[ "$(set_priority sd)" == 1:1:1:0 ]]
[[ "$before" == "$(sha256sum "$BACKUP")" ]]
grep -qx 'serial=keep-me' "$testdir/env"
for var in bootcmd bootmenu_default bootmenu_delay preboot bootmenu_0; do
 reset_env; echo "$var=custom" >> "$testdir/env"; refuse_without_write
done
reset_env; CRC_OK=0; refuse_without_write
reset_env; RW=0; refuse_without_write
reset_env; sed -i 's/boot_from_sd=1/boot_from_sd=invalid/' "$testdir/env"; refuse_without_write
reset_env
if set_priority ';reboot' > "$testdir/result"; then exit 1; fi
[[ ! -s "$testdir/writes" ]]
reset_env; WRITE_OK=0
if set_priority flash > "$testdir/result"; then exit 1; fi
grep -q '^0:0:' "$testdir/result"
reset_env; READBACK_OK=0
if set_priority flash > "$testdir/result"; then exit 1; fi
grep -q '^0:0:' "$testdir/result"
reset_env; CORRUPT_OTHER=1
if set_priority flash > "$testdir/result"; then exit 1; fi
grep -q '^0:0:' "$testdir/result"
reset_env; printf x > "$BACKUP"; refuse_without_write
reset_env; BACKUP="$testdir/another/env.bin"; ENV_MTD="$testdir/missing"; refuse_without_write
reset_env
printf 'bootcmd=%s\nbootmenu_default=8\nbootmenu_delay=0\npreboot=%s\nbootmenu_0=%s\n' "$LEGACY_BOOTCMD" "$LEGACY_PREBOOT" "$LEGACY_MENU" >> "$testdir/env"
[[ "$(status)" == 1:0:1:1 ]]
[[ "$(set_priority sd)" == 1:1:1:0 ]]
! grep -Eq '^(bootcmd|bootmenu_default|bootmenu_delay|preboot|bootmenu_0)=' "$testdir/env"
[[ $(wc -l < "$testdir/writes") == 1 ]]
echo 'PASS: persistent SD/Flash selection, idempotence, backup, custom-command refusal, CRC/readback/write failures, legacy cleanup, other-variable preservation'
