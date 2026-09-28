#!/bin/sh
# Only for the USB composition documented in the supplied SRM825 diagnostic.
set -eu
[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }
command -v ucode >/dev/null || { echo "ucode is required." >&2; exit 1; }
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
rule=/usr/share/qmodem/modem_port_rule.json
slot=
for device in /sys/bus/usb/devices/*; do
    [ -f "$device/idVendor" ] && [ -f "$device/idProduct" ] || continue
    [ "$(cat "$device/idVendor")" = 2dee ] && [ "$(cat "$device/idProduct")" = 4d23 ] || continue
    slot=${device##*/}
    iface="$device/$slot:1.5"
    [ "$(basename "$(readlink -f "$iface/driver")")" = cdc_ether ] || { slot=; continue; }
    [ -d "$iface/net" ] || { slot=; continue; }
    found=0
    for net in "$iface"/net/*; do [ -e "$net" ] && found=1; done
    [ "$found" = 1 ] || { slot=; continue; }
    break
done
[ -n "$slot" ] || { echo "Expected SRM825 2dee:4d23 ECM interface 1.5 not found; unchanged." >&2; exit 1; }
[ -f "$rule" ] && [ -x /etc/init.d/qmodem_init ] && [ -x /usr/bin/modem_scanc ]
tmp=$(mktemp "$rule.srm825.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
ucode "$script_dir/patch-rule.uc" "$rule" "$tmp"
if cmp -s "$rule" "$tmp"; then
    echo "Rule already patched."
else
    backup="$rule.before-srm825-$(date +%Y%m%d-%H%M%S)-$$"
    cp -p "$rule" "$backup"
    chmod 644 "$tmp"
    mv "$tmp" "$rule"
    echo "Backup: $backup"
fi
# Reload the cached JSON rules, then explicitly rescan this USB slot.
/etc/init.d/qmodem_init restart
sleep 2
/usr/bin/modem_scanc add "$slot" usb 0
echo "Rescan queued. Allow 30-60 seconds for AT probing, then check QModem."
echo "This does not change USB mode, flash firmware or reboot the router."
