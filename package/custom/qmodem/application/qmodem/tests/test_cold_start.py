#!/usr/bin/env python3
import subprocess,tempfile,shlex
from pathlib import Path
root=Path(__file__).resolve().parents[1]
def shell(code):
    return subprocess.check_output(['bash','-c',code],text=True,stderr=subprocess.STDOUT)
with tempfile.TemporaryDirectory() as d:
    d=Path(d)
    vendor=(root/'files/usr/share/qmodem/vendor/meig.sh').read_text().replace('source /usr/share/qmodem/generic.sh','')
    v=d/'vendor';v.write_text(vendor)
    for raw,key,want in [('AT+CGMM\r\n+CGMM: SRM825\r\nOK','CGMM','SRM825'), ('\r\nSRM825\r\nOK','CGMM','SRM825'), ('+CGMR: "SRM825_6.0.8_EQ101"\r\nOK','CGMR','SRM825_6.0.8_EQ101'), ('AT+CGMM\nERROR','CGMM','')]:
        got=shell(f'source {v}; printf %s {shlex.quote(raw)} | meig_identity_value {key}').strip()
        assert got==want,(raw,got)
    init=(root/'files/etc/init.d/qmodem_init').read_text().replace('. $IPKG_INSTROOT/lib/functions.sh',':').replace('/usr/share/qmodem/modem_scan.sh','mock_scan')
    f=d/'init';f.write_text(init)
    out=shell(f'''source {f}
config_get() {{ case "$1" in path) printf -v "$1" /not-ready/2-1 ;; data_interface|type) printf -v "$1" usb ;; slot) printf -v "$1" 2-1 ;; esac; }}
sleep() {{ :; }}
mock_scan() {{ echo "$*" >> {d}/events; }}
uci() {{ echo 'UNEXPECTED UCI mutation' >> {d}/events; }}
_try_device saved
_try_slot preset
wait
cat {d}/events
''')
    assert out.splitlines()==['add 2-1 usb']*2,out
    util=(root/'files/usr/share/qmodem/modem_util.sh').read_text().replace('. /lib/functions.sh',':')
    f=d/'util';f.write_text(util)
    out=shell(f'''source {f}
QMODEM_AT_LOCK_WAIT=1
sleep() {{ :; }}
qmodem_at_lock_path() {{ echo /test/port; }}
lock() {{
  echo "$*" >> {d}/locks
  case "$*" in '-n /test/port') return 0 ;; '-n /test/daemon') return 1 ;; esac
}}
QMODEM_AT_DAEMON_LOCK=/test/daemon
qmodem_at_run /dev/mock queued echo BAD
rc=$?
echo rc=$rc
cat {d}/locks
''')
    assert 'rc=75' in out and 'BAD' not in out,out
    assert '-u /test/port' in out and '-u /test/daemon' not in out,out
print('PASS: identity variants, late USB re-probe without config deletion, bounded queue preserves other lock owner')
