#!/bin/sh
# Whole-field PDP address validation; requires fm350.sh.
qmodem_parse_cgpaddr()
{
    local response="$1" wanted="$2" records line field converted malformed=0

    ipv4=""
    ipv6=""
    connection_status=-1
    fm350_is_uint "$wanted" || return 1
    # Select whole CGPADDR records for the requested CID. Never search the
    # flattened response for IP substrings: MT5700's 16 decimal IPv6 bytes
    # otherwise look like four unrelated IPv4 addresses.
    records=$(printf '%s\n' "$response" | awk -v wanted="$wanted" '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        /^[[:space:]]*\+CGPADDR:/ {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[[:space:]]*\+CGPADDR:[[:space:]]*/, "", line)
            n = split(line, part, ",")
            cid = trim(part[1])
            if (cid !~ /^[0-9]+$/ || cid + 0 != wanted + 0)
                next
            print "R"
            for (i = 2; i <= n; i++) {
                field = trim(part[i])
                if (field ~ /^"[^"]*"$/) {
                    sub(/^"/, "", field)
                    sub(/"$/, "", field)
                }
                print "F" field
            }
        }')
    [ -n "$records" ] || return 1

    while IFS= read -r line; do
        [ "$line" != R ] || continue
        field="${line#F}"
        [ -n "$field" ] || continue
        case "$field" in
            *:*)
                converted="$(fm350_colon_ipv6 "$field" 1 2>/dev/null)" || {
                    malformed=1
                    continue
                }
                case "$converted" in *[!0:]*) [ -n "$ipv6" ] || ipv6="$converted" ;; esac
                ;;
            *.*)
                case "$field" in
                    *[!0-9.]*|.*|*.|*..*) malformed=1; continue ;;
                esac
                [ "$field" != 0.0.0.0 ] || continue
                if fm350_is_valid_ipv4 "$field"; then
                    case "$field" in *[!0.]*) [ -n "$ipv4" ] || ipv4="$field" ;; esac
                else
                    converted="$(fm350_dotted_ipv6 "$field" 1 2>/dev/null)" || {
                        malformed=1
                        continue
                    }
                    case "$converted" in *[!0:]*) [ -n "$ipv6" ] || ipv6="$converted" ;; esac
                fi
                ;;
            *) malformed=1 ;;
        esac
    done <<EOF
$records
EOF

    if [ "$malformed" != 0 ]; then
        ipv4=""
        ipv6=""
        return 1
    fi
    connection_status=0
    [ -n "$ipv4" ] && connection_status=1
    [ -n "$ipv6" ] && connection_status=2
    [ -n "$ipv4" ] && [ -n "$ipv6" ] && connection_status=3
    return 0
}
