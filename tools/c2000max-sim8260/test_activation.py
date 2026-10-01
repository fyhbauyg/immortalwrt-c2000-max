import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

parser=argparse.ArgumentParser()
parser.add_argument('--jq',required=True)
parser.add_argument('--shell',default='bash')
args=parser.parse_args()
repo=Path(__file__).resolve().parents[2]
source=(repo/'tools/c2000max-sim8260/probe_activation.sh').read_text()
with tempfile.TemporaryDirectory(prefix='sim8260-activation-test-') as temp:
    temp=Path(temp)
    for scenario in ['success','rejected','timeout','hang-failed','interrupted','disabled','ubus-failed','restore-failed']:
        root=temp/scenario
        for d in ['bin','tmp','etc/init.d','dev','usr/share/qmodem','var/run/qmodem/2_1_dir','sys/class/net/usb0']:
            (root/d).mkdir(parents=True,exist_ok=True)
        (root/'dev/ttyUSB2').touch()
        (root/'var/run/qmodem/2_1_dir/dial_log').write_text('old dial trace\npassword=SECRET\nIMEI: 123456789012345\n')
        if scenario!='disabled': (root/'running').touch()
        def executable(path,text):
            path.write_text(text);path.chmod(0o755)
        executable(root/'bin/id','#!/bin/sh\necho 0\n')
        executable(root/'bin/sleep', '#!/bin/sh\n[ "$MOCK_SCENARIO" != interrupted ] || kill -TERM "$PPID"\n')
        (root/'bin/jq').symlink_to(Path(args.jq).resolve())
        executable(root/'bin/uci', '#!/bin/sh\ncase "$*" in\n*"qmodem.2_1.name") echo simcom_sim8260g-m2 ;;\n*"qmodem.2_1.at_port") echo '+shlex.quote(str(root/'dev/ttyUSB2'))+' ;;\n*"qmodem.2_1.override_at_port") exit 1 ;;\n*"qmodem.2_1.network") echo usb0 ;;\n*"qmodem.2_1") echo modem-device ;;\n*) exit 1 ;;\nesac\n')
        executable(root/'bin/ubus', '''#!/bin/sh
[ "$MOCK_SCENARIO" != ubus-failed ] || [ -f "$MOCK_ROOT/running" ] || exit 1
if [ -f "$MOCK_ROOT/running" ]; then state=true; else state=false; fi
printf '{"qmodem_network":{"instances":{"modem_2_1":{"running":%s}}}}\n' "$state"
''')
        for name in ['ip','ping','nslookup']:
            executable(root/'bin'/name, '#!/bin/sh\n[ -f "$MOCK_ROOT/running" ] || exit 7\necho "'+name+' $*" >> "$MOCK_ROOT/host-events"\necho "'+name+' $*"\n')
        executable(root/'etc/init.d/qmodem_network', '''#!/bin/sh
echo "$*" >> "$MOCK_ROOT/events"
case "$1" in
hang) [ "$MOCK_SCENARIO" != hang-failed ] || exit 1; rm -f "$MOCK_ROOT/running" ;;
dial) [ "$MOCK_SCENARIO" != restore-failed ] || exit 1; touch "$MOCK_ROOT/running" ;;
*) exit 1 ;;
esac
''')
        (root/'usr/share/qmodem/modem_util.sh').write_text('''at_timeout() {
    printf '%s|%s\\n' "$2" "$3" >> "$MOCK_ROOT/at-events"
    case "$2" in
    'AT+NETACT=1')
        [ "$3" = 30 ] || return 2
        case "$MOCK_SCENARIO" in
        rejected) printf '%s\\r\\n' '+CME ERROR: 30'; return 0 ;;
        timeout) echo 'response timeout'; return 1 ;;
        esac
        ;;
    esac
    printf '%s\\r\\n' "$2" OK
}
''')
        script=re.sub(r'/(root|tmp|etc|usr|sys|dev|lib|var)/',lambda m: str(root)+m[0],source)
        script=script.replace('[ -c "$at_port" ]','[ -e "$at_port" ]')
        path=root/'probe.sh';path.write_text(script)
        env=dict(os.environ,MOCK_ROOT=str(root),MOCK_SCENARIO=scenario,PATH=str(root/'bin')+':'+os.environ['PATH'])
        result=subprocess.run([args.shell,str(path),'2_1'],env=env,text=True,capture_output=True,timeout=10)
        if scenario=='disabled':
            assert result.returncode!=0 and not (root/'events').exists(),result
            continue
        assert (root/'running').exists() == (scenario!='restore-failed'),result
        assert (root/'events').read_text().splitlines()==['hang 2_1','dial 2_1'],result
        report=next((root/'tmp').glob('sim8260-activation-*.txt')).read_text()
        assert 'SECRET' not in report and '123456789012345' not in report
        assert 'restore_exit='+('1' if scenario=='restore-failed' else '0') in report
        commands=(root/'at-events').read_text().splitlines() if (root/'at-events').exists() else []
        if scenario in ['hang-failed','ubus-failed']:
            assert result.returncode!=0 and not any(c.startswith('AT+NETACT=1|') for c in commands)
        elif scenario in ['interrupted','restore-failed']:
            assert result.returncode!=0 and commands.count('AT+NETACT=1|30')==1
            if scenario=='restore-failed': assert 'Failed to restore dialer' in result.stderr
            assert not (root/'host-events').exists()
        else:
            assert result.returncode==0,result
            assert commands.count('AT+NETACT=1|30')==1
            assert len(commands)==12,commands
            assert (root/'host-events').exists()
            assert 'ping -I usb0' in (root/'host-events').read_text()
            assert report.index('restore_exit=0') < report.index('--- Host connectivity after restoring target dialer')
            assert not any('CGDCONT=' in c or 'CFUN=' in c or 'CUSBCFG=' in c for c in commands)
            if scenario=='rejected': assert '+CME ERROR: 30' in report
            if scenario=='timeout': assert 'response timeout' in report and 'exit=1' in report
print('PASS: one activation, raw error/timeout capture, restore target after failures and signals, disabled guard, no configuration writes, ID redaction ('+args.shell+')')
