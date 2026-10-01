#!/usr/bin/env python3
"""Exercise real SIM8260 helpers/call sites with redacted wire fixtures, no modem I/O."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
scripts = root / 'files/usr/share/qmodem'
with tempfile.TemporaryDirectory(prefix='sim8260-test-') as temp:
    temp = Path(temp)
    vendor = temp / 'simcom.sh'
    vendor.write_text('\n'.join(line for line in (scripts/'vendor/simcom.sh').read_text().splitlines() if not line.startswith('source ')))
    dial = temp / 'dial.sh'
    dial.write_text((scripts/'modem_dial.sh').read_text().replace('source /lib/functions.sh', ':')
                    .replace('SCRIPT_DIR="/usr/share/qmodem"', 'SCRIPT_DIR='+shlex.quote(str(scripts)))
                    .replace('source "${SCRIPT_DIR}/generic.sh"', ':')
                    .replace('MODEM_RUNDIR="/var/run/qmodem"', 'MODEM_RUNDIR='+shlex.quote(str(temp))))
    prefix = f'''
set -- fixture unused
source {shlex.quote(str(scripts/'fm350.sh'))}
source {shlex.quote(str(scripts/'pdp_address.sh'))}
source {shlex.quote(str(scripts/'simcom_network.sh'))}
source {shlex.quote(str(dial))}
at_port=/dev/mock
modem_name=simcom_sim8260g-m2
modem_config=2_1
config_section=2_1
manufacturer=simcom
platform=qualcomm
driver=rndis
pdp_index=6
pdp_type=ipv4v6
apn=auto
events={shlex.quote(str(temp/'events'))}
m_debug() {{ :; }}
get_driver() {{ echo rndis; }}
add_plain_info_entry() {{ printf '%s|%s\n' "$1" "$2"; }}
at() {{ at_timeout "$@" 5; }}
at_timeout() {{
  printf '%s\n' "$2" >> "$events"
  case "$2" in
    'AT+CGDCONT?') printf '%s\r\n' "${{CONTEXTS:-+CGDCONT: 6,\"IPV4V6\",\"existing-apn\",\"0.0.0.0\"}}" OK ;;
    'AT+CGCONTRDP=1') printf '%s\r\n' "${{PRIMARY_RUNTIME:-}}" OK; return "${{RUNTIME_RC:-0}}" ;;
    'AT+CGCONTRDP='*) printf '%s\r\n' "${{SELECTED_RUNTIME:-}}" OK; return "${{RUNTIME_RC:-0}}" ;;
    'AT+NETACT?') printf '+NETACT: %s\r\nOK\r\n' "${{NETACT:-1}}" ;;
    'AT+CGPADDR='*) printf '%s\r\n' "${{IP_REPLY:-+CGPADDR: 6,\"192.0.2.10\"}}" OK ;;
    'AT+NETACT=1') printf '%s\r\n' "${{DIAL_REPLY:-OK}}"; return "${{DIAL_RC:-0}}" ;;
    'AT+NETACT=0') echo OK ;;
    'AT+CGDCONT='*) printf '%s\r\n' "${{DEFINE_REPLY:-OK}}" ;;
    'AT+CGMM') printf '%s\r\n' 'AT+CGMM' '+CGMM: SIMCOM_SIM8260G-M2' OK ;;
    'AT+CGMI') printf '%s\r\n' '+CGMI: SIMCOM INCORPORATED' OK ;;
    'AT+CGMR') printf '%s\r\n' "${{CGMR_REPLY:-+CGMR: 22131B06X62M44A-M2}}" OK ;;
    'AT+SIMCOMATI') printf '%s\r\n' 'Revision: 22131B06X62M44A-M2' OK ;;
    *) echo "UNEXPECTED $2" >&2; return 1 ;;
  esac
}}
'''
    def run(body):
        (temp/'events').write_text('')
        result = subprocess.run(['bash','-c',prefix+body], text=True, capture_output=True, timeout=8)
        assert result.returncode == 0, (body, result)
        return result.stdout, (temp/'events').read_text().splitlines()
    for raw, key, want in [
        ('AT+CGMM\r\n\r\nSIMCOM_SIM8260G-M2\r\nOK', 'CGMM', 'SIMCOM_SIM8260G-M2'),
        ('+CGMM: "SIMCOM_SIM8260G-M2"\r\nOK', 'CGMM', 'SIMCOM_SIM8260G-M2'),
        ('\r\n+CGMR: 22131B06X62M44A-M2\r\nOK', 'CGMR', '22131B06X62M44A-M2'),
        ('ATI\r\nManufacturer: SIMCOM INCORPORATED\r\nModel: SIMCOM_SIM8260G-M2\r\nRevision: V1.0.01\r\nOK', 'CGMM', 'SIMCOM_SIM8260G-M2'),
        ('ATI\r\nRevision: V1.0.01\r\nOK', 'CGMR', 'V1.0.01'),
        ('AT+CGMM\r\n+CME ERROR: 100\r\nERROR', 'CGMM', ''),
        ('+CEREG: 1\r\nRDY\r\nSIMCOM_SIM8260G-M2\r\nOK', 'CGMM', 'SIMCOM_SIM8260G-M2')]:
        output, _ = run('printf %s '+shlex.quote(raw)+' | simcom_identity_value '+key)
        assert output.strip() == want, (raw, output)
    for raw, want in [('USBID: 0X1E0E,0X9011','9011'), ('USBID: 1e0e,9011','9011'), ('USBID: 0x1e0e, 0x9001','9001'), ('USBID: 2DEE,4D23',''), ('ERROR','')]:
        output, _ = run('printf %s '+shlex.quote(raw)+' | simcom_usb_product')
        assert output.strip() == want
    output, events = run('at_dial')
    assert events == ['AT+CGDCONT?', 'AT+CGCONTRDP=6', 'AT+CGCONTRDP=1', 'AT+NETACT=1'], events  # No APN/type overwrite or CNMP reset.
    output, events = run("apn=\"\"; at_dial")
    assert events == ['AT+CGDCONT?', 'AT+CGCONTRDP=6', 'AT+CGCONTRDP=1', 'AT+NETACT=1'], events
    output, events = run("CONTEXTS='+CGDCONT: 1,\"IP\",\"operator-default\"'; at_dial")
    assert events == ['AT+CGDCONT?', 'AT+CGCONTRDP=6', 'AT+CGCONTRDP=1', 'AT+CGDCONT=6,"IPV4V6"', 'AT+NETACT=1'], events
    output, events = run('apn=example.apn; at_dial')
    assert events == ['AT+CGDCONT?', 'AT+CGDCONT=6,"IPV4V6","example.apn"', 'AT+NETACT=1'], events
    output, events = run("DEFINE_REPLY='ERROR'; apn=example.apn; at_dial; echo rc=$?")
    assert 'rc=1' in output and 'AT+NETACT=1' not in events, (output, events)
    for body in ["DIAL_REPLY='ERROR'", "DIAL_REPLY='+CME ERROR: 30'", 'DIAL_RC=124']:
        output, _ = run(body+'; at_dial; echo rc=$?')
        assert 'rc=1' in output
    # Use the real diagnostic shape (addresses replaced with documentation ranges).
    primary='+CGCONTRDP: 1,5,"3gnet",192.0.2.10,2001:db8::1,,192.0.2.53,192.0.2.54'
    contexts='+CGDCONT: 1,"IPV4V6","","0.0.0.0"\r\n+CGDCONT: 6,"IPV4V6","","0.0.0.0"'
    output, events=run('CONTEXTS='+shlex.quote(contexts)+'; PRIMARY_RUNTIME='+shlex.quote(primary)+'; at_dial')
    assert events==['AT+CGDCONT?', 'AT+CGCONTRDP=6', 'AT+CGCONTRDP=1', 'AT+CGDCONT=6,"IPV4V6","3gnet"', 'AT+NETACT=1'],events
    for raw,expected in [(primary,'3gnet'),('+CGCONTRDP: 2,5,"ims",192.0.2.10',''),('AT+CGCONTRDP=1\r\nOK',''),('+CGCONTRDP: 1,5,"",192.0.2.10','')]:
        output,_=run('printf %s '+shlex.quote(raw)+' | simcom_pdp_apn CGCONTRDP 1')
        assert output.strip()==expected,(raw,output)
    # An active selected context, explicit APN/CID and already correct APN are preserved.
    output,events=run('SELECTED_RUNTIME=\'+CGCONTRDP: 6,5,"private.apn",192.0.2.20\'; PRIMARY_RUNTIME='+shlex.quote(primary)+'; at_dial')
    assert events==['AT+CGDCONT?','AT+CGCONTRDP=6','AT+NETACT=1'],events
    output,events=run('CONTEXTS=\'+CGDCONT: 6,"IPV4V6","3gnet","0.0.0.0"\'; PRIMARY_RUNTIME='+shlex.quote(primary)+'; at_dial')
    assert not any(c.startswith('AT+CGDCONT=') for c in events),events
    # A new SIM's assigned primary APN refreshes an inactive secondary context.
    output,events=run('CONTEXTS=\'+CGDCONT: 6,"IPV4V6","3gnet","0.0.0.0"\'; PRIMARY_RUNTIME=\'+CGCONTRDP: 1,5,"cmnet",192.0.2.10\'; at_dial')
    assert 'AT+CGDCONT=6,"IPV4V6","cmnet"' in events,events
    for bad in ['ims','ims.operator','sos','emergency','v2x_ip','bad;apn','bad apn']:
        output,events=run('PRIMARY_RUNTIME='+shlex.quote('+CGCONTRDP: 1,5,"'+bad+'",192.0.2.10')+'; at_dial')
        assert not any(c.startswith('AT+CGDCONT=') for c in events),events
    output,events=run('pdp_index=3; CONTEXTS=\'+CGDCONT: 3,"IP","","0.0.0.0"\'; PRIMARY_RUNTIME='+shlex.quote(primary)+'; at_dial')
    assert 'AT+CGCONTRDP=3' in events and 'AT+CGDCONT=3,"IPV4V6","3gnet"' in events,events
    output,events=run('pdp_index=1; CONTEXTS=\'+CGDCONT: 1,"IPV4V6","","0.0.0.0"\'; at_dial')
    assert events==['AT+CGDCONT?','AT+NETACT=1'],events
    output,events=run('PRIMARY_RUNTIME='+shlex.quote(primary)+'; DEFINE_REPLY=ERROR; at_dial; echo rc=$?')
    assert 'rc=1' in output and 'AT+NETACT=1' not in events
    output,events=run('RUNTIME_RC=75; at_dial; echo rc=$?')
    assert 'rc=1' in output and not any(c.startswith('AT+CGDCONT=') for c in events)
    output,_=run('m_debug() { echo "$1"; }; DIAL_REPLY=ERROR; at_dial; echo rc=$?')
    assert 'response=ERROR' in output and 'rc=1' in output,output
    output, events = run('ecm_hang')
    assert events == ['AT+NETACT=0'], events
    for ip, state, v4, v6 in [
        ('+CGPADDR: 6,"192.0.2.10"', 1, '192.0.2.10', ''),
        ('+CGPADDR: 6,"0.0.0.0"', 0, '', ''),
        ('+CGPADDR: 6,"2001:db8::1"', 2, '', '2001:db8::1'),
        ('+CGPADDR: 6,"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0"', 0, '', ''),
        ('+CGPADDR: 2,"192.0.2.20"', -1, '', ''),
        ('+CGPADDR: 6,"256.2.3.4"', -1, '', '')]:
        body='IP_REPLY='+shlex.quote(ip)+'; check_ip; printf "%s|%s|%s\\n" "$connection_status" "$ipv4" "$ipv6"'
        output, events = run(body)
        assert output.strip() == f'{state}|{v4}|{v6}', (ip, output)
        assert events == ['AT+CGPADDR=6']
    output, events = run("pdp_index=3; IP_REPLY='+CGPADDR: 3,\"192.0.2.10\"'; check_ip; echo $connection_status")
    assert output.strip() == '1' and events == ['AT+CGPADDR=3']  # Preserve explicit CID.
    for model, plat, cid, query in [('simcom_sim8200ea-m2','qualcomm',3,6), ('simcom_a8200_serias','asrmicro',3,3)]:
        output, events = run(f'modem_name={model}; platform={plat}; pdp_index={cid}; IP_REPLY=\'+CGPADDR: {query},"192.0.2.10"\'; check_ip; echo $connection_status')
        assert output.strip() == '1' and events == [f'AT+CGPADDR={query}']
    for state, ip, expected in [('0','+CGPADDR: 6,"192.0.2.10"','No'), ('1','+CGPADDR: 6,"0.0.0.0"','No'), ('1','+CGPADDR: 2,"192.0.2.20"','No'), ('1','+CGPADDR: 6,"192.0.2.10"','Yes')]:
        output, _ = run('NETACT='+state+'; IP_REPLY='+shlex.quote(ip)+'; simcom_get_connect_status')
        assert output.strip() == 'connect_status|'+expected
    output, events = run(f'source {shlex.quote(str(vendor))}; get_temperature() {{ :; }}; get_voltage() {{ :; }}; base_info')
    assert 'name|SIMCOM_SIM8260G-M2' in output and 'revision|22131B06X62M44A-M2' in output
    assert 'AT+SIMCOMATI' not in events
    output, events = run(f'source {shlex.quote(str(vendor))}; get_temperature() {{ :; }}; get_voltage() {{ :; }}; CGMR_REPLY=ERROR; base_info')
    assert 'revision|22131B06X62M44A-M2' in output and 'AT+SIMCOMATI' in events
print('PASS: SIMCom identity, USB mode, automatic APN preservation, NETACT dial/hang/failure, CID/address validation, unrelated profiles and UI data status')
