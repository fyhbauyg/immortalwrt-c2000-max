#!/usr/bin/env python3
"""Exercise the cold-boot fallback path and physical LED output with mocks."""
import subprocess, tempfile, shlex
from pathlib import Path
board = Path(__file__).resolve().parents[1]
qmodem = board.parent / 'qmodem/application/qmodem'
def run(code):
    return subprocess.check_output(['bash', '-c', code], text=True, stderr=subprocess.STDOUT, timeout=10)
with tempfile.TemporaryDirectory() as tmp:
    d=Path(tmp)
    util=d/'util'
    util.write_text((qmodem/'files/usr/share/qmodem/modem_util.sh').read_text().replace('. /lib/functions.sh', ':'))
    sim=board/'files/usr/sbin/c2000max-sim'
    code=f"""source {util}
export C2000MAX_SIM_LIBRARY_ONLY=1
source {sim}
uci() {{ echo /dev/ttyUSB1; }}
lock() {{ echo "$*" >> {d}/locks; }}
sleep() {{ :; }}
begin_at_transaction /dev/ttyUSB2
port=$(resolve_port modem)
[ "$port" = /dev/ttyUSB2 ] || exit 1
qmodem_at_run "$port" queued echo VERIFIED
qmodem_at_run /dev/ttyUSB1 queued echo UNEXPECTED
[ $? = 76 ] || exit 2
end_at_transaction
cat {d}/locks
"""
    out=run(code)
    assert 'VERIFIED' in out and 'UNEXPECTED' not in out, out
    assert out.count('-n /var/lock/qmodem-at-daemon.lock')==1, out
    assert '-n /var/lock/qmodem-at-ttyUSB1.lock' not in out, out
    assert '-u /var/lock/qmodem-at-ttyUSB2.lock' in out, out
    # Default lock acquisition is bounded, without a caller opting in.
    out=run(f"""source {util}
sleep() {{ :; }}
lock() {{ return 1; }}
qmodem_at_wait_lock /test/busy
echo rc=$?
""")
    assert 'rc=75' in out,out
    led=d/'led'
    led.write_text((board/'files/usr/sbin/c2000max-leds').read_text().replace('/usr/share/qmodem/modem_ctrl.sh', str(d/'ctrl')))
    ctrl=d/'ctrl'
    ctrl.write_text('#!/bin/sh\n[ "$QMODEM_AT_LOCK_WAIT" = 1 ] || exit 1\ncat "'+str(d/'sample')+'"\n')
    ctrl.chmod(0o755)
    import json
    for samples, want in [([(-77,'NR')],(1,0,0)), ([(-85,'LTE')],(0,1,0)), ([(' −85.4 dBm ','LTE')],(0,1,0)), ([(-96,'NR')],(0,0,1)), ([(-70,'LTE'),(-95,'NR')],(0,0,1)), ([(-32768,'NR')],None)]:
        (d/'sample').write_text(json.dumps({'modem_info':[{'key':'RSRP','value':str(v),'extra_info':tag} for v,tag in samples]}))
        for name in ['blue:sig1','blue:sig2','blue:sig3']:
            folder=d/name;folder.mkdir(exist_ok=True)
            for attr in ['trigger','brightness','delay_on','delay_off']: (folder/attr).write_text('0')
        run(f"""export C2000MAX_LED_SYSFS={d}
export C2000MAX_MODEM_CACHE_DIR={d}
source {led} --library
first_qmodem_section() {{ echo modem; }}
data_online() {{ return 0; }}
led_user_managed() {{ return 1; }}
uci() {{ :; }}
good=-80; weak=-90
update_signal
""")
        if want is None:
            assert (d/'blue:sig2/trigger').read_text().strip()=='timer'
        else:
            for name, value in zip(['blue:sig1','blue:sig2','blue:sig3'],want):
                assert (d/name/'trigger').read_text().strip()=='none'
                assert (d/name/'brightness').read_text().strip()==str(value)
    # A recent cache must avoid the AT command entirely.
    (d/'cache_cell_info_modem').write_text('{"modem_info":[{"key":"RSRP","value":"-79 dBm","extra_info":"NR"}]}')
    ctrl.write_text('#!/bin/sh\nexit 7\n')
    out=run(f'source {led} --library; C2000MAX_MODEM_CACHE_DIR={d}; get_rsrp modem')
    assert out.strip()=='-79',out
print('PASS: fallback transaction port, cross-port rejection, finite queue, LTE/NR LED colors and invalid signal')
