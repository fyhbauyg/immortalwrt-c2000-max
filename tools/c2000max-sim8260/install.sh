#!/bin/sh
# Verified C2000MAX QModem r15/r16 patch; run diagnose.sh before installation.
set -eu
bundle=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
section="${1:-2_1}"
case "$section" in ''|*[!A-Za-z0-9_]*) echo 'Invalid QModem section' >&2; exit 1 ;; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root' >&2; exit 1; }
[ "$(cat /tmp/sysinfo/board_name)" = nradio,c2000-max ] || { echo 'Wrong board' >&2; exit 1; }
[ "$(uci -q get "qmodem.$section")" = modem-device ] || { echo 'Modem section missing' >&2; exit 1; }
for file in /etc/init.d/qmodem_init /etc/init.d/qmodem_network /usr/share/qmodem/modem_util.sh /usr/share/qmodem/fm350.sh; do
    [ -r "$file" ] || { echo "Missing $file" >&2; exit 1; }
done
(cd "$bundle" && sha256sum -c payload.sha256) || exit 1
while read -r path original fixed; do
    if [ -f "/$path" ]; then
        actual=$(sha256sum "/$path" | awk '{print $1}')
        [ "$actual" = "$original" ] || [ "$actual" = "$fixed" ] || {
            echo "Different custom/versioned file: /$path. No changes made." >&2; exit 1;
        }
    else
        [ "$original" = absent ] || { echo "Missing /$path" >&2; exit 1; }
    fi
done < "$bundle/allowed-files.txt"
profile=$(cat "$bundle/profile.json")
table=/usr/share/qmodem/modem_support.json
jq -e --argjson profile "$profile" '
    (.modem_support.usb | type) == "object" and
    (.modem_support.usb.simcom_sim8260g_m2 == null) and
    (.modem_support.usb["simcom_sim8260g-m2"] == null or .modem_support.usb["simcom_sim8260g-m2"] == $profile) and
    (.modem_support.usb["sim8260g-m2"] == null or .modem_support.usb["sim8260g-m2"] == $profile)
' "$table" >/dev/null || { echo 'Invalid table or custom SIM8260 profile; no changes made' >&2; exit 1; }
modem_config="$section"
config_section="$section"
at_port=$(uci -q get "qmodem.$section.override_at_port" || true)
[ -n "$at_port" ] || at_port=$(uci -q get "qmodem.$section.at_port")
platform=$(uci -q get "qmodem.$section.platform" || true)
manufacturer=$(uci -q get "qmodem.$section.manufacturer" || true)
. /usr/share/qmodem/modem_util.sh
. /usr/share/qmodem/fm350.sh
. "$bundle/payload/usr/share/qmodem/simcom_network.sh"
QMODEM_AT_LOCK_WAIT=2
export QMODEM_AT_LOCK_WAIT
reply=$(at_timeout "$at_port" 'AT+CGMM' 6 2>&1) || { echo 'CGMM failed; no changes made' >&2; exit 1; }
name=$(printf '%s\n' "$reply" | simcom_identity_value CGMM)
modem_name="$name"
simcom_is_sim8260 || { echo "AT identifies a different modem: $name; no changes made" >&2; exit 1; }
backup="/root/c2000max-sim8260-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 700 "$backup"
printf '%s\n' "$section" > "$backup/section"
cp -p /etc/config/qmodem "$backup/qmodem"
cp -p "$table" "$backup/modem_support.json"
while read -r path original fixed; do
    mkdir -p "$backup/$(dirname "$path")"
    if [ -e "/$path" ]; then cp -p "/$path" "$backup/$path";
    else touch "$backup/$path.absent"; fi
done < "$bundle/allowed-files.txt"
cp "$bundle/allowed-files.txt" "$backup/allowed-files.txt"
cp "$bundle/rollback.sh" "$backup/rollback.sh"
complete=0
trap '[ "$complete" = 1 ] || sh "$backup/rollback.sh" "$backup"; :' EXIT
/etc/init.d/qmodem_init stop
while read -r path original fixed; do
    destination="/$path"
    cp "$bundle/payload/$path" "$destination.sim8260-new"
    case "$path" in */modem_dial.sh) chmod 755 "$destination.sim8260-new" ;; *) chmod 644 "$destination.sim8260-new" ;; esac
    mv "$destination.sim8260-new" "$destination"
done < "$bundle/allowed-files.txt"
jq --argjson profile "$profile" '
    .modem_support.usb["simcom_sim8260g-m2"] = $profile |
    .modem_support.usb["sim8260g-m2"] = $profile
' "$table" > "$table.sim8260-new"
jq -e '.modem_support.usb["simcom_sim8260g-m2"].platform == "qualcomm"' "$table.sim8260-new" >/dev/null
chmod 644 "$table.sim8260-new"
mv "$table.sim8260-new" "$table"
uci set "qmodem.$section.name=simcom_sim8260g-m2"
uci set "qmodem.$section.manufacturer=simcom"
uci set "qmodem.$section.platform=qualcomm"
uci set "qmodem.$section.suggest_pdp_index=6"
uci -q delete "qmodem.$section.modes" || true
uci add_list "qmodem.$section.modes=rndis"
uci add_list "qmodem.$section.modes=qmi"
uci commit qmodem
/etc/init.d/qmodem_init start
complete=1
trap - EXIT
echo "SIM8260 patch installed. Backup: $backup"
echo 'Automatic APN and explicit PDP CID were preserved. Redial may briefly interrupt cellular access.'
/etc/init.d/qmodem_network redial "$section"
echo "After about 20 seconds, run: sh $bundle/diagnose.sh $section"
echo "Rollback: sh $backup/rollback.sh $backup"
