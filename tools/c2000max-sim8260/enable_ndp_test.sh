#!/bin/sh
# Scoped NDP configuration trial for an already working SIM8260 extended /64.
# Restart only odhcpd; preserve RA/SLAAC, DHCPv6 and modem dial configuration.
set -e
section="${1:-2_1}"
case "$section" in ''|*[!A-Za-z0-9_]*) echo 'Invalid modem section' >&2; exit 1 ;; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root' >&2; exit 1; }
[ "$(cat /tmp/sysinfo/board_name)" = nradio,c2000-max ] || { echo 'Wrong board' >&2; exit 1; }
[ "$(uci -q get "qmodem.$section")" = modem-device ] || exit 1
model=$(uci -q get "qmodem.$section.name")
case "$model" in simcom_sim8260g-m2|sim8260g-m2) ;; *) echo 'Wrong modem model' >&2; exit 1 ;; esac
[ "$(uci -q get "qmodem.$section.extend_prefix")" = 1 ] || { echo 'Extended-prefix mode is not enabled' >&2; exit 1; }
alias=$(uci -q get "qmodem.$section.alias" || true)
interface="${alias:-$section}v6"
case "$interface" in *[!A-Za-z0-9_.-]*) echo 'Invalid WAN6 alias' >&2; exit 1 ;; esac
[ "$(uci -q get "network.$interface.extendprefix")" = 1 ] || exit 1
[ "$(uci -q get dhcp.lan)" = dhcp ] || exit 1
[ -z "$(uci -q changes dhcp)" ] || { echo 'DHCP has pending user changes; no changes made' >&2; exit 1; }
[ -x /etc/init.d/odhcpd ] || exit 1
ubus call "network.interface.$interface" status | jq -e '.up == true' >/dev/null || { echo 'WAN6 is not up' >&2; exit 1; }
for name in $(uci -q show dhcp | sed -n 's/^dhcp\.\([^=]*\)=dhcp$/\1/p'); do
    [ "$name" = "$interface" ] && continue
    if [ "$(uci -q get "dhcp.$name.master" || true)" = 1 ]; then
        echo "Another relay master exists: dhcp.$name; no changes made" >&2
        exit 1
    fi
done
existing=$(uci -q get "dhcp.$interface" || true)
if [ -n "$existing" ]; then
    [ "$existing" = dhcp ] &&
    [ "$(uci -q get "dhcp.$interface.interface" || true)" = "$interface" ] &&
    [ "$(uci -q get "dhcp.$interface.master" || true)" = 1 ] &&
    [ "$(uci -q get "dhcp.$interface.ndp" || true)" = relay ] &&
    [ "$(uci -q get dhcp.lan.ndp || true)" = relay ] || {
        echo "Custom dhcp.$interface configuration exists; no changes made" >&2; exit 1;
    }
    echo 'NDP relay is already configured; no changes made.'
    exit 0
fi
umask 077
backup="/root/c2000max-sim8260-ndp-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir "$backup"
cp -p /etc/config/dhcp "$backup/dhcp"
printf '%s\n' "$section" "$interface" > "$backup/target"
cat > "$backup/rollback.sh" <<'ROLLBACK'
#!/bin/sh
set -e
backup=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$(id -u)" = 0 ] || exit 1
[ -f "$backup/dhcp" ] || exit 1
[ -z "$(uci -q changes dhcp)" ] || { echo 'DHCP has pending changes; rollback stopped' >&2; exit 1; }
if [ -f "$backup/applied.sha256" ]; then
    expected=$(cat "$backup/applied.sha256")
    current=$(sha256sum /etc/config/dhcp | cut -d ' ' -f 1)
    original=$(sha256sum "$backup/dhcp" | cut -d ' ' -f 1)
    [ "$current" = "$expected" ] || [ "$current" = "$original" ] || {
        echo 'DHCP was changed after this trial; rollback stopped to preserve those changes.' >&2
        echo "Original configuration: $backup/dhcp" >&2
        exit 1
    }
fi
cp -p "$backup/dhcp" /etc/config/dhcp
/etc/init.d/odhcpd restart
echo 'DHCP configuration restored; odhcpd restarted.'
ROLLBACK
chmod 700 "$backup/rollback.sh"
complete=0
recover() {
    rc=$?
    if [ "$complete" != 1 ]; then
        uci -q revert dhcp || true
        sh "$backup/rollback.sh" || echo "Recovery failed; backup: $backup" >&2
    fi
    return "$rc"
}
trap recover 0
trap 'exit 128' 1 2 15
uci set "dhcp.$interface=dhcp"
uci set "dhcp.$interface.interface=$interface"
uci set "dhcp.$interface.master=1"
uci set "dhcp.$interface.ndp=relay"
uci set "dhcp.$interface.ra=disabled"
uci set "dhcp.$interface.dhcpv6=disabled"
uci set "dhcp.$interface.ignore=1"
uci set dhcp.lan.ndp=relay
uci commit dhcp
sha256sum /etc/config/dhcp | cut -d ' ' -f 1 > "$backup/applied.sha256"
/etc/init.d/odhcpd restart
complete=1
trap - 0 1 2 15
echo "NDP relay trial applied for $interface and LAN."
echo "Backup: $backup"
echo "Rollback: sh $backup/rollback.sh"
echo 'Wait 10 seconds, then repeat the Windows source-address ping and IPv6 HTTPS test.'
echo 'QModem currently deletes this trial WAN6 DHCP section when redialing extended-prefix mode.'
echo 'Keep the dialer unchanged during this trial; permanent integration follows hardware verification.'
