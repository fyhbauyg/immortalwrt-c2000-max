#!/bin/sh
# C2000MAX / OpenWrt QModem SRM825N diagnostic collector
# Read-only by design: does not restart QModem, rebind USB drivers, or send AT commands.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL

TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
OUTDIR="/tmp/c2000max-srm825n-diag-$TS"
LOG="$OUTDIR/report.txt"
mkdir -p "$OUTDIR" || exit 1

section() {
    printf '\n\n========== %s ==========\n' "$1" >>"$LOG"
}

run() {
    printf '\n$ %s\n' "$*" >>"$LOG"
    "$@" >>"$LOG" 2>&1
}

run_sh() {
    printf '\n$ %s\n' "$1" >>"$LOG"
    sh -c "$1" >>"$LOG" 2>&1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

copy_if_exists() {
    src="$1"
    dst="$2"
    [ -e "$src" ] && cp -a "$src" "$OUTDIR/$dst" 2>/dev/null
}

{
    echo "C2000MAX SRM825N / QModem diagnostic report"
    echo "Generated: $(date 2>/dev/null)"
    echo "Collector: v1"
    echo
    echo "Purpose: lsusb can see the modem, but QModem does not recognize it."
    echo "This script is intended to preserve the failure state and collect evidence."
} >"$LOG"

section "System"
run uname -a
[ -f /etc/openwrt_release ] && run cat /etc/openwrt_release
[ -f /etc/os-release ] && run cat /etc/os-release
run uptime
run df -h
run free

section "Installed QModem / modem packages"
if have apk; then
    run_sh "apk list --installed 2>/dev/null | grep -Ei 'qmodem|modem|usb|qmi|mbim|mhi|wwan|serial|uqmi|umbim|sms|atinout' || true"
elif have opkg; then
    run_sh "opkg list-installed 2>/dev/null | grep -Ei 'qmodem|modem|usb|qmi|mbim|mhi|wwan|serial|uqmi|umbim|sms|atinout' || true"
fi

section "USB enumeration"
if have lsusb; then
    run lsusb
    run_sh "lsusb -t 2>/dev/null || true"
    run_sh "lsusb -v 2>/dev/null | grep -E '(^Bus|idVendor|idProduct|iManufacturer|iProduct|iSerial|bInterfaceNumber|bInterfaceClass|bInterfaceSubClass|bInterfaceProtocol|bNumInterfaces)' || true"
else
    echo "lsusb not installed" >>"$LOG"
fi

section "USB sysfs details"
for d in /sys/bus/usb/devices/*; do
    [ -d "$d" ] || continue
    [ -f "$d/idVendor" ] || continue
    {
        echo
        echo "--- $d ---"
        for f in idVendor idProduct bcdDevice manufacturer product serial busnum devnum speed version bDeviceClass bDeviceSubClass bDeviceProtocol bNumConfigurations bNumInterfaces; do
            [ -f "$d/$f" ] && printf '%s=' "$f" && cat "$d/$f"
        done
        [ -L "$d/driver" ] && echo "driver=$(readlink -f "$d/driver")"
    } >>"$LOG" 2>&1

    for i in "$d":*; do
        [ -d "$i" ] || continue
        {
            echo "  interface: $i"
            for f in bInterfaceNumber bInterfaceClass bInterfaceSubClass bInterfaceProtocol interface; do
                [ -f "$i/$f" ] && printf '    %s=' "$f" && cat "$i/$f"
            done
            if [ -L "$i/driver" ]; then
                echo "    driver=$(readlink -f "$i/driver")"
            else
                echo "    driver=<none>"
            fi
        } >>"$LOG" 2>&1
    done
done

section "TTY / WWAN / network device nodes"
run_sh "ls -l /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/wwan* /dev/mhi* 2>/dev/null || true"
run_sh "ls -l /sys/class/tty/ttyUSB* /sys/class/tty/ttyACM* 2>/dev/null || true"
for t in /sys/class/tty/ttyUSB* /sys/class/tty/ttyACM*; do
    [ -e "$t" ] || continue
    {
        echo "--- $t ---"
        readlink -f "$t/device"
        [ -L "$t/device/driver" ] && readlink -f "$t/device/driver"
    } >>"$LOG" 2>&1
done
run ip link show
run_sh "for n in /sys/class/net/*; do [ -e \"\$n/device\" ] || continue; echo --- \$n ---; readlink -f \"\$n/device\"; [ -L \"\$n/device/driver\" ] && readlink -f \"\$n/device/driver\"; done"

section "Kernel modules"
run lsmod
run_sh "lsmod | grep -Ei 'usbserial|option|qcserial|qmi|mbim|ncm|rndis|cdc|wwan|mhi|rmnet|qrtr|ipa|gobinet' || true"

section "Kernel log - modem related"
if have dmesg; then
    run_sh "dmesg | grep -Ei 'usb|ttyUSB|ttyACM|cdc-wdm|qmi|mbim|ncm|wwan|mhi|modem|option|usbserial|SRM|825|Quectel|Fibocom|SIMCOM' | tail -n 1200"
    run_sh "dmesg | tail -n 1500"
fi

section "procd / logread - QModem and USB"
if have logread; then
    run_sh "logread | grep -Ei 'qmodem|modem|usb|ttyUSB|ttyACM|cdc-wdm|qmi|mbim|mhi|wwan|SRM|825' | tail -n 1500"
    run_sh "logread | tail -n 1800"
fi

section "Processes and services"
run_sh "ps w | grep -Ei '[q]modem|modem|uqmi|umbim|atinout|mhi|wwan' || true"
run_sh "ls -l /etc/init.d/*qmodem* /etc/init.d/*modem* 2>/dev/null || true"
for s in /etc/init.d/*qmodem* /etc/init.d/*modem*; do
    [ -x "$s" ] || continue
    echo "--- service: $s ---" >>"$LOG"
    "$s" status >>"$LOG" 2>&1 || true
done

section "ubus objects"
if have ubus; then
    run_sh "ubus list | grep -Ei 'qmodem|modem|network.interface|network.device' || true"
    run_sh "ubus call system board 2>/dev/null || true"
    run_sh "ubus call network.interface dump 2>/dev/null || true"
fi

section "QModem configuration"
if [ -f /etc/config/qmodem ]; then
    sed -E \
        -e "s/(password|passwd|username|user|pin|puk)[[:space:]]+'?[^' ]+'?/\1 '<redacted>'/Ig" \
        -e "s/([0-9]{14,16})/<redacted-number>/g" \
        /etc/config/qmodem >>"$LOG" 2>&1
else
    echo "/etc/config/qmodem not found" >>"$LOG"
fi
run_sh "uci -q show qmodem 2>/dev/null | sed -E \"s/(password|passwd|username|user|pin|puk)=.*/\\1='<redacted>'/Ig; s/[0-9]{14,16}/<redacted-number>/g\" || true"

section "QModem files / modem profiles"
run_sh "find /usr /lib /etc -maxdepth 5 -type f \( -iname '*qmodem*' -o -iname '*modem*' -o -iname '*srm*' \) 2>/dev/null | sort | head -n 1000"
run_sh "grep -RniE 'SRM825|SRM825N|825N' /etc /usr/share /usr/lib /lib 2>/dev/null | head -n 500 || true"

section "Hotplug USB rules"
run_sh "find /etc/hotplug.d /usr/share/hotplug.d /lib -maxdepth 5 -type f 2>/dev/null | grep -Ei 'usb|modem|qmodem' | head -n 500 || true"
run_sh "grep -RniE 'idVendor|idProduct|ttyUSB|cdc-wdm|qmi_wwan|cdc_mbim|option|usbserial|qmodem' /etc/hotplug.d /usr/share/hotplug.d 2>/dev/null | head -n 1000 || true"

section "USB driver ID tables / dynamic IDs"
for p in /sys/bus/usb-serial/drivers/* /sys/bus/usb/drivers/*; do
    [ -d "$p" ] || continue
    case "$(basename "$p")" in
        option|qcserial|qmi_wwan|cdc_mbim|cdc_ncm|cdc_ether|rndis_host|usbserial_generic)
            echo "--- $p ---" >>"$LOG"
            [ -f "$p/new_id" ] && ls -l "$p/new_id" >>"$LOG" 2>&1
            [ -f "$p/remove_id" ] && ls -l "$p/remove_id" >>"$LOG" 2>&1
            ls -l "$p" >>"$LOG" 2>&1
            ;;
    esac
done

section "Device-tree / platform clues"
run_sh "find /proc/device-tree -maxdepth 4 -type f 2>/dev/null | grep -Ei 'usb|pcie|mhi|modem' | head -n 500 || true"

section "Network config"
run_sh "uci -q show network 2>/dev/null | sed -E 's/(password|passwd|username|user)=.*/\1=<redacted>/Ig' || true"
run_sh "uci -q show firewall 2>/dev/null | head -n 1000 || true"

section "Quick diagnosis hints"
{
    echo "1) lsusb present but no ttyUSB/cdc-wdm/wwan: likely kernel driver/interface binding issue."
    echo "2) ttyUSB/cdc-wdm present but QModem absent: likely QModem profile/device-match/hotplug detection issue."
    echo "3) USB interface driver=<none>: compare interface class/subclass/protocol with option/qmi_wwan/cdc_mbim support."
    echo "4) option binds AT ports but no cdc-wdm/netdev: check qmi_wwan/cdc_mbim and USB composition."
    echo "5) QModem logs mentioning unsupported/unknown modem strongly suggest missing SRM825N adapter/profile."
} >>"$LOG"

# Make a lightly sanitized copy for sharing. Raw report remains local for advanced debugging.
SAN="$OUTDIR/report-share.txt"
sed -E \
    -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/<redacted-mac>/g' \
    -e 's/([0-9]{14,16})/<redacted-number>/g' \
    -e 's/(serial=).*/\1<redacted>/Ig' \
    "$LOG" >"$SAN" 2>/dev/null || cp "$LOG" "$SAN"

ARCHIVE="/tmp/c2000max-srm825n-diag-$TS.tar.gz"
if have tar; then
    tar -czf "$ARCHIVE" -C /tmp "$(basename "$OUTDIR")" 2>/dev/null || ARCHIVE=""
fi

echo
echo "Done."
echo "Report: $LOG"
echo "Share-safe report: $SAN"
[ -n "$ARCHIVE" ] && echo "Archive: $ARCHIVE"
echo
echo "Please send report-share.txt first. If more detail is needed, keep report.txt private until reviewed."
