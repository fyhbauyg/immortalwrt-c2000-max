#!/bin/sh
# Add only the missing SRM825L profile, preserving every other model and UCI setting.
set -eu

[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }
[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "nradio,c2000-max" ] || {
    echo "This patch is for NRadio C2000MAX only." >&2; exit 1;
}
table=/usr/share/qmodem/modem_support.json
service=/etc/init.d/qmodem_init
scanner=/usr/bin/modem_scanc
[ -r "$table" ] && [ -x "$service" ] && [ -x "$scanner" ] || {
    echo "QModem support table or scanner service is missing." >&2; exit 1;
}
command -v jq >/dev/null || { echo "jq is missing." >&2; exit 1; }

profile='{"manufacturer_id":"2dee","manufacturer":"meig","platform":"qualcomm","data_interface":"usb","pdp_index":"1","modes":["ecm","rndis","ncm"]}'
if ! jq -e --argjson profile "$profile" '
    (.modem_support.usb | type) == "object" and
    (.modem_support.usb.srm825l == null or .modem_support.usb.srm825l == $profile)
' "$table" >/dev/null; then
    echo "Invalid support table or a different custom SRM825L profile exists; no changes made." >&2
    exit 1
fi

backup="/root/c2000max-srm825l-backup-20261001-$(date +%s)-$$"
mkdir -m 700 "$backup"
cp -p "$table" "$backup/modem_support.json"
tmp="$(mktemp "${table}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
jq --argjson profile "$profile" '.modem_support.usb.srm825l = $profile' "$table" > "$tmp"
jq -e --argjson profile "$profile" '.modem_support.usb.srm825l == $profile' "$tmp" >/dev/null
chmod 644 "$tmp"
mv "$tmp" "$table"

# modem_scand keeps the table in memory; a scan alone cannot reload it.
if ! "$service" restart; then
    cp -p "$backup/modem_support.json" "$table"
    "$service" start || true
    echo "Scanner restart failed; support table restored from $backup." >&2
    exit 1
fi
ready=0
for attempt in 1 2 3 4 5; do
    if "$scanner" status >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
if [ "$ready" != 1 ] || ! "$scanner" scan usb; then
    echo "Profile installed, but scan could not be queued. Backup: $backup" >&2
    echo "Check /etc/init.d/qmodem_init and logread before retrying." >&2
    exit 1
fi
echo "SRM825L profile installed; scanner restarted and USB scan queued."
echo "Backup: $backup/modem_support.json"
echo "Wait about 15 seconds, then run:"
echo "uci -q show qmodem.2_1"
echo "logread | grep -E 'modem_scand|modem_init' | tail -30"
