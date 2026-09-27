#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
helper="$ROOT/files/usr/sbin/c2000max-boot-official-once"
sh -n "$helper"
if grep -q fw_setenv "$helper"; then echo 'Legacy one-shot writer still present'; exit 1; fi
if sh "$helper" arm; then echo 'Retired one-shot command accepted'; exit 1; fi
echo 'PASS: retired one-shot entry cannot write or reboot'
