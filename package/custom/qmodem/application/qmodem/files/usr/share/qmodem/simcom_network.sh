#!/bin/sh
# SIM82XX_SIM83XX AT manual V1.03: sections 2.2.28/29, 12.2.9, 18.2.1.

simcom_is_sim8260()
{
    local model="${modem_name:-${name:-}}"
    if [ -z "$model" ]; then
        model=$(uci -q get "qmodem.${modem_config:-$config_section}.name")
    fi
    case "$(printf '%s' "$model" | tr 'A-Z' 'a-z')" in
        simcom_sim8260g-m2|sim8260g-m2) return 0 ;;
    esac
    return 1
}

simcom_identity_value()
{
    awk -v key="$1" '
        BEGIN {
            label=key
            if (key == "CGMM") label="Model"
            if (key == "CGMI") label="Manufacturer"
            if (key == "CGMR") label="Revision"
        }
        { gsub(/\r/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
        $0 == "" || toupper($0) == "OK" || toupper($0) == "ERROR" ||
        toupper($0) ~ /^AT/ || /^[+^]/ && index($0, "+" key ":") != 1 { next }
        index($0, "+" key ":") == 1 || index($0, label ":") == 1 {
            sub("^\\+?" key ":[ \t]*", "")
            sub("^" label ":[ \t]*", "")
            gsub(/^"|"$/, ""); print; found=1; exit
        }
        key != "Revision" && !fallback && $0 !~ /^(RDY|PB DONE|SMS DONE|Call Ready|SMS Ready|NO CARRIER)$/ { fallback=$0 }
        END { if (!found && fallback != "") { gsub(/^"|"$/, "", fallback); print fallback } }
    '
}

simcom_usb_product()
{
    awk '
        { line=toupper($0); gsub(/[ \t\r]/, "", line) }
        line ~ /^USBID:/ {
            sub(/^USBID:/, "", line); n=split(line, ids, ",")
            sub(/^0X/, "", ids[1]); sub(/^0X/, "", ids[2])
            if (n == 2 && ids[1] == "1E0E" && ids[2] ~ /^[0-9A-F][0-9A-F][0-9A-F][0-9A-F]$/) print ids[2]
            exit
        }
    '
}

simcom_netact_state()
{
    awk '/^[ \t]*\+NETACT:/ {
        sub(/^[ \t]*\+NETACT:[ \t]*/, ""); gsub(/[ \t\r]/, "")
        if ($0 == "0" || $0 == "1") print; exit
    }'
}

simcom_at_succeeded()
{
    printf '%s\n' "$1" | tr -d '\r' | grep -qE '^[[:space:]]*OK[[:space:]]*$' || return 1
    ! fm350_response_has_error "$1"
}

simcom_netact_set()
{
    local state="$1" response rc
    case "$state" in 0|1) ;; *) return 1 ;; esac
    response=$(at_timeout "$at_port" "AT+NETACT=$state" 8 2>&1)
    rc=$?
    if [ "$rc" != 0 ] || ! simcom_at_succeeded "$response"; then
        m_debug "SIM8260 NETACT=$state rejected or timed out (rc=$rc)"
        return 1
    fi
}

simcom_rndis_dial()
{
    local cid="${pdp_index:-6}" type apn_value response context_exists=0 command
    fm350_is_uint "$cid" && [ "$cid" -ge 1 ] && [ "$cid" -le 16 ] || return 1
    type=$(printf '%s' "${pdp_type:-ipv4v6}" | tr 'a-z' 'A-Z')
    case "$type" in IPV4) type=IP ;; IP|IPV6|IPV4V6) ;; *) return 1 ;; esac
    apn_value="$apn"
    [ "$(printf '%s' "$apn_value" | tr 'A-Z' 'a-z')" != auto ] || apn_value=""
    case "$apn_value" in *[!A-Za-z0-9._-]*)
        m_debug "SIM8260 APN contains invalid characters"; return 1 ;;
    esac

    # With automatic APN, keep an existing context exactly as the modem reports it.
    # The manual NETACT example uses CID 6; this is the new profile suggestion.
    # An explicit user CID is retained and must match the modem data-call setup.
    response=$(at_timeout "$at_port" 'AT+CGDCONT?' 8 2>&1) || return 1
    simcom_at_succeeded "$response" || return 1
    if printf '%s\n' "$response" | awk -F '[,:]' -v cid="$cid" '
        /^[ \t]*\+CGDCONT:/ && $2 + 0 == cid + 0 { found=1 }
        END { exit !found }'; then
        context_exists=1
    fi
    if [ -n "$apn_value" ] || [ "$context_exists" = 0 ]; then
        command="AT+CGDCONT=$cid,\"$type\""
        [ -z "$apn_value" ] || command="$command,\"$apn_value\""
        response=$(at_timeout "$at_port" "$command" 8 2>&1) || return 1
        simcom_at_succeeded "$response" || {
            m_debug "SIM8260 CGDCONT rejected for CID $cid"; return 1;
        }
    fi
    m_debug "SIM8260 RNDIS enable data call; configured CID=$cid"
    simcom_netact_set 1
}

simcom_get_connect_status()
{
    local response cid="${pdp_index:-}" section="${modem_config:-$config_section}"
    # The vendor info worker may not have resolved the profile suggestion yet.
    [ -n "$cid" ] || cid=$(uci -q get "qmodem.$section.suggest_pdp_index")
    [ -n "$cid" ] || cid=6
    connect_status="No"
    response=$(at_timeout "$at_port" 'AT+NETACT?' 5 2>&1)
    if [ "$(printf '%s\n' "$response" | simcom_netact_state)" = 1 ]; then
        response=$(at_timeout "$at_port" "AT+CGPADDR=$cid" 5 2>&1)
        if qmodem_parse_cgpaddr "$response" "$cid" && [ "$connection_status" -gt 0 ]; then
            connect_status="Yes"
        fi
    fi
    # This describes the modem data context. Host DHCP/routing is diagnosed separately.
    add_plain_info_entry "connect_status" "$connect_status" "Connect Status"
}
