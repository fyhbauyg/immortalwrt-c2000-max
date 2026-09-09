#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QMODEM="$ROOT/../qmodem/application/qmodem/files/usr/share/qmodem"
DIAL="${C2000MAX_CGPADDR_DIAL_SCRIPT:-$QMODEM/modem_dial.sh}"
. "$QMODEM/fm350.sh"
# Load only the actual pure parser/check_ip functions; never source the
# dialer's main entrypoint, OpenWrt libraries, or any AT/network code.
eval "$(sed -n '/^qmodem_parse_cgpaddr()/,/^check_ip()/p' "$DIAL" | sed '$d')"
eval "$(sed -n '/^check_ip()/,/^find_wan_fw_zone()/p' "$DIAL" | sed '$d')"

manufacturer=huawei
platform=hisilicon
driver=ncm
pdp_index=1
at_port=/dev/mock
test_count=0
at() {
    [ "$1" = /dev/mock ] && [ "$2" = "AT+CGPADDR=$pdp_index" ] || {
        printf 'Unexpected AT query\n' >&2
        return 1
    }
    printf '%s\n' "$RESPONSE"
}
m_debug() { :; }
check() {
    RESPONSE="$1"
    expected_status="$2"
    expected4="$3"
    expected6="$4"
    label="$5"
    ipv4=stale-ipv4
    ipv6=stale-ipv6
    connection_status=stale
    check_ip || :
    if [ "$connection_status" != "$expected_status" ] ||
       [ "$ipv4" != "$expected4" ] || [ "$ipv6" != "$expected6" ]; then
        printf 'FAIL %s: status=%s v4=<%s> v6=<%s>\n' \
            "$label" "$connection_status" "$ipv4" "$ipv6" >&2
        exit 1
    fi
    test_count=$((test_count + 1))
}

# Synthetic documentation addresses preserve the original wire shape.
dotted='32.1.13.184.2.112.173.239.24.211.90.236.50.61.27.64'
colon='2001:0db8:0270:adef:18d3:5aec:323d:1b40'
check "+CGPADDR: 1,\"$dotted\"" 2 '' "$colon" 'reported 16-byte IPv6 must not become four IPv4s'
check '+CGPADDR: 1,"192.0.2.10"' 1 192.0.2.10 '' 'IPv4 only'
check '+CGPADDR: 1,"2001:DB8::1"' 2 '' 2001:db8::1 'colon IPv6 only'
check "+CGPADDR: 1,\"192.0.2.10\",\"$dotted\"" 3 192.0.2.10 "$colon" 'dual stack IPv4 first'
check '+CGPADDR: 1,"2001:db8::1","192.0.2.10"' 3 192.0.2.10 2001:db8::1 'dual stack IPv6 first'
check '  +CGPADDR: 1 , 192.0.2.10 , 2001:db8::1' 3 192.0.2.10 2001:db8::1 'whole unquoted fields'
check '+CGPADDR: 2,"192.0.2.2"
+CGPADDR: 1,"192.0.2.10"' 1 192.0.2.10 '' 'unrelated CID ignored'
check '+CGPADDR: 1,"192.0.2.10"
+CGPADDR: 1,"2001:db8::1"' 3 192.0.2.10 2001:db8::1 'two matching CID records'
check '+CGPADDR: 2,"192.0.2.2"' -1 '' '' 'only another CID is not our connection'
check '+CGPADDR: 1,"0.0.0.0"' 0 '' '' 'zero IPv4 disconnected'
check '+CGPADDR: 1,"::"' 0 '' '' 'compressed zero IPv6 disconnected'
check '+CGPADDR: 1,"0:0:0:0:0:0:0:0"' 0 '' '' 'full zero IPv6 disconnected'
check '+CGPADDR: 1,"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0"' 0 '' '' '16-byte zero IPv6 disconnected'
check '+CGPADDR: 1,"",""' 0 '' '' 'empty address fields disconnected'
check '+CGPADDR: 1' 0 '' '' 'CID-only record disconnected'
check '+CGPADDR: 1,"0.0.0.0","2001:db8::1"' 2 '' 2001:db8::1 'IPv6-only dual-stack response'

for bad in '256.1.2.3' '10.1.2.3.' '.10.1.2.3' '10..1.2.3' \
    'prefix10.1.2.3suffix' '10.1.2.3/24' '1.2.3.4.5.6.7.8' \
    '1.2.3.4.5.6.7.8.9.10.11.12.13.14.15' \
    '256.2.3.4.5.6.7.8.9.10.11.12.13.14.15.16' \
    '2001:::1' '2001::1::2' '2001:db8:1' '10000::1' \
    '1:2:3:4:5:6:7:8:9' '::ffff:192.0.2.1' 'garbage'; do
    check "+CGPADDR: 1,\"$bad\"" -1 '' '' "reject whole malformed field $bad"
done
check '+CGPADDR: 1,"10.1.2.3","2001:::1"' -1 '' '' 'malformed second field does not report partial connection'
check '+CGPADDR: 1,"10.1.2.3' -1 '' '' 'unmatched quote rejected'
check 'garbage +CGPADDR: 1,"10.1.2.3"' -1 '' '' 'unanchored response prefix rejected'
check 'ERROR' -1 '' '' 'missing response clears stale addresses'
pdp_index=7
check '+CGPADDR: 1,"192.0.2.1"
+CGPADDR: 7,"192.0.2.10"' 1 192.0.2.10 '' 'actual requested CID 7'

# Existing FM350 callers retain the original nonzero-only default.
if fm350_colon_ipv6 :: >/dev/null; then exit 1; fi
if fm350_dotted_ipv6 0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0 >/dev/null; then exit 1; fi
[ "$(fm350_colon_ipv6 :: 1)" = :: ]
printf 'PASS: %s actual check_ip CGPADDR cases; default FM350 zero rejection unchanged\n' "$test_count"
