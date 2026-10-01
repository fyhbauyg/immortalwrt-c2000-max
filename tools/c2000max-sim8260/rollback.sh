#!/bin/sh
set -eu
backup="${1:-}"
case "$backup" in /root/c2000max-sim8260-backup-*) ;; *) echo 'Invalid backup path' >&2; exit 1 ;; esac
[ -r "$backup/allowed-files.txt" ] && [ -r "$backup/qmodem" ] && [ -r "$backup/modem_support.json" ] || exit 1
/etc/init.d/qmodem_init stop || true
while read -r path original fixed; do
    if [ -f "$backup/$path.absent" ]; then
        rm -f "/$path"
    else
        cp -p "$backup/$path" "/$path"
    fi
done < "$backup/allowed-files.txt"
cp -p "$backup/modem_support.json" /usr/share/qmodem/modem_support.json
cp -p "$backup/qmodem" /etc/config/qmodem
/etc/init.d/qmodem_init start
section=$(cat "$backup/section")
/etc/init.d/qmodem_network redial "$section"
echo "Restored scripts and QModem configuration from $backup"
