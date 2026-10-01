import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import time

parser = argparse.ArgumentParser(description='Exercise scoped NAT6 probe guards, comparisons and cleanup.')
parser.add_argument('--jq', required=True, type=Path)
parser.add_argument('--shell', default='dash')
args = parser.parse_args()
source = (Path(__file__).resolve().parent / 'probe_ipv6_snat.sh').read_text()
scenarios = ['normal', 'router-only', 'wrong-model', 'wrong-board', 'bad-source',
             'wan-down', 'no-lan', 'wan-failed', 'syntax-failed', 'apply-failed',
             'apply-partial', 'interrupted', 'device-mismatch', 'existing-probe',
             'snat-failed', 'kill-parent']
with tempfile.TemporaryDirectory(prefix='sim8260-snat-test-') as temporary:
    base = Path(temporary)
    for scenario in scenarios:
        root = base / scenario
        for folder in ['bin', 'tmp/sysinfo', 'etc/config', 'sys/class/net/usb0',
                       'proc/sys/net/ipv6/conf/usb0', 'proc/sys/net/ipv6/conf/br-lan']:
            (root / folder).mkdir(parents=True, exist_ok=True)
        def executable(path, text):
            path.write_text(text); path.chmod(0o755)
        for name in ['dhcp', 'network', 'qmodem', 'firewall']:
            (root / 'etc/config' / name).write_text('original ' + name + '\n')
        initial = {p.name: p.read_bytes() for p in (root / 'etc/config').iterdir()}
        (root / 'tmp/sysinfo/board_name').write_text('different,board\n' if scenario == 'wrong-board' else 'nradio,c2000-max\n')
        for device in ['usb0', 'br-lan']:
            for key in ['forwarding', 'proxy_ndp']:
                (root / 'proc/sys/net/ipv6/conf' / device / key).write_text('1\n')
        executable(root / 'bin/id', '#!/bin/sh\necho 0\n')
        (root / 'bin/jq').symlink_to(args.jq.resolve())
        executable(root / 'bin/uci', '''#!/bin/sh
[ "$1" = -q ] && shift
case "$1" in get|show) ;; *) echo 'unexpected UCI mutation' >&2; exit 9 ;; esac
case "$1 $2" in
'get qmodem.2_1') echo modem-device ;;
'get qmodem.2_1.name') if [ "$MOCK_SCENARIO" = wrong-model ]; then echo fm150; else echo simcom_sim8260g-m2; fi ;;
'get qmodem.2_1.alias') echo eth2 ;;
'get qmodem.2_1.network') if [ "$MOCK_SCENARIO" = device-mismatch ]; then echo eth2; else echo usb0; fi ;;
'get network.lan.device') echo br-lan ;;
'show dhcp.eth2v6') echo 'dhcp.eth2v6.ndp=relay' ;;
'get dhcp.lan.ndp') echo relay ;;
'get dhcp.lan.ra') echo server ;;
'get dhcp.lan.dhcpv6') echo disabled ;;
'get dhcp.lan.ra_slaac') echo 1 ;;
*) exit 1 ;;
esac
''')
        executable(root / 'bin/ubus', '''#!/bin/sh
case "$*" in
'call network.interface.eth2v6 status')
    if [ "$MOCK_SCENARIO" = wan-down ]; then up=false; else up=true; fi
    printf '{"up":%s,"l3_device":"usb0","ipv6-address":[{"address":"2001:db8:1::2","preferred":600}]}\n' "$up" ;;
'call service list '* ) echo '{"odhcpd":{"instances":{"running":true}}}' ;;
*) exit 9 ;;
esac
''')
        executable(root / 'bin/ip', '''#!/bin/sh
case "$*" in
'-6 -o address show dev br-lan scope global')
    [ "$MOCK_SCENARIO" != no-lan ] || exit 0
    echo '3: br-lan inet6 2001:db8:9::1/64 scope global deprecated preferred_lft 0sec'
    echo '3: br-lan inet6 2001:db8:1::1/64 scope global preferred_lft 600sec' ;;
*) echo "ip $*" ;;
esac
''')
        executable(root / 'bin/nft', r'''#!/usr/bin/env python3
import ipaddress, json, os, re, sys
from pathlib import Path
root=Path(os.environ['MOCK_ROOT']); scenario=os.environ['MOCK_SCENARIO']; args=sys.argv[1:]
active=root/'active-table'
with (root/'nft-events').open('a') as f: f.write(json.dumps(args)+'\n')
if args==['list','tables']:
    print('table inet fw4')
    if active.exists(): print('table ip6 '+active.read_text())
    if scenario=='existing-probe': print('table ip6 c2000max_s8260_probe_other')
elif args[:2]==['-c','-f'] or args[:1]==['-f']:
    rule=Path(args[-1]).read_text()
    name=re.search(r'table ip6 ([a-z0-9_]+)',rule)[1]
    assert name.startswith('c2000max_s8260_probe_')
    assert 'priority 105;' in rule and 'flush' not in rule
    assert 'oifname "usb0"' in rule
    for address in re.findall(r'(?:saddr|snat to) ([0-9a-f:]+)',rule): ipaddress.IPv6Address(address)
    assert 'ip6 saddr 2001:db8:1::1' in rule
    if scenario!='router-only':
        assert 'iifname "br-lan"' in rule and 'ip6 saddr 2001:db8:1::100 tcp dport 443' in rule
    if args[0]=='-c':
        if scenario=='syntax-failed': sys.exit(6)
    else:
        if scenario=='apply-failed': sys.exit(7)
        active.write_text(name)
        if scenario=='apply-partial': sys.exit(7)
elif args[-2:]==['list','ruleset']:
    print('table inet fw4 { /* existing firewall unchanged */ }')
elif args[:2]==['delete','table']:
    assert args[2]=='ip6' and args[3].startswith('c2000max_s8260_probe_')
    if not active.exists(): sys.exit(1)
    assert active.read_text()==args[3]
    active.unlink()
elif 'list' in args and 'table' in args:
    assert args[-2]=='ip6' and args[-1].startswith('c2000max_s8260_probe_')
    if not active.exists(): sys.exit(1)
    print('counter packets 2 bytes 160 snat to 2001:db8:1::2')
else: raise AssertionError(args)
''')
        executable(root / 'bin/ping', '''#!/bin/sh
echo "ping $*"
[ "$MOCK_SCENARIO" != wan-failed ] || exit 1
case "$*" in
*'-I 2001:db8:1::2'*) exit 0 ;;
*'-I 2001:db8:1::1'*) [ -f "$MOCK_ROOT/active-table" ] && [ "$MOCK_SCENARIO" != snat-failed ] ;;
*) exit 9 ;;
esac
''')
        executable(root / 'bin/sleep', '''#!/bin/sh
if [ "$1" = 90 ]; then exec /bin/sleep 1; fi
if [ "$MOCK_SCENARIO" = interrupted ]; then kill -TERM "$PPID"; exit 0; fi
if [ "$MOCK_SCENARIO" = kill-parent ]; then exec /bin/sleep 4; fi
exec /bin/sleep 0.02
''')
        executable(root / 'bin/tcpdump', '#!/bin/sh\necho "tcpdump $*"\n')
        script = root / 'probe.sh'
        transformed = re.sub(r'/(tmp|etc|sys|proc)/', lambda m: str(root) + m[0], source)
        script.write_text(transformed.replace('-C /tmp ', '-C ' + str(root / 'tmp') + ' '))
        env = dict(os.environ, MOCK_ROOT=str(root), MOCK_SCENARIO=scenario,
                   PATH=str(root / 'bin') + ':' + os.environ['PATH'])
        command = [args.shell, str(script), '2_1']
        if scenario != 'router-only': command.append('bad-value' if scenario == 'bad-source' else '2001:db8:1::100')
        if scenario == 'kill-parent':
            with (root / 'output.txt').open('w') as output:
                process = subprocess.Popen(command, env=env, stdout=output, stderr=output)
                deadline = time.monotonic()+5
                while time.monotonic()<deadline:
                    if 'NAT6 trial ACTIVE' in (root/'output.txt').read_text(): break
                    assert process.poll() is None
                    time.sleep(0.02)
                else: raise AssertionError('probe did not become active')
                process.kill(); process.wait(timeout=2)
            assert (root / 'active-table').exists()
            deadline = time.monotonic()+3
            while (root/'active-table').exists() and time.monotonic()<deadline: time.sleep(0.02)
            assert not (root / 'active-table').exists(), 'independent watchdog failed'
        else:
            result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
            success = scenario in ['normal', 'router-only', 'snat-failed']
            assert (result.returncode==0)==success, (scenario, result)
            assert not (root / 'active-table').exists(), scenario
            if success:
                assert 'WAN-before: 2 / 2 targets replied' in result.stdout
                assert 'LAN-before: 0 / 2 targets replied' in result.stdout
                assert ('LAN-SNAT: 0' if scenario=='snat-failed' else 'LAN-SNAT: 2') in result.stdout
                assert 'Temporary NAT6 rules removed.' in result.stdout
                archive = next((root/'tmp').glob('sim8260-nat6-*.tar.gz'))
                with tarfile.open(archive) as data:
                    names = [m.name.split('/')[-1] for m in data.getmembers()]
                    assert 'nat6-counters.txt' in names and 'state-before.txt' in names
                    before=data.extractfile(next(m for m in data.getmembers() if m.name.endswith('config-hashes-before.txt'))).read()
                    after=data.extractfile(next(m for m in data.getmembers() if m.name.endswith('config-hashes-after.txt'))).read()
                    assert before==after
        assert {p.name:p.read_bytes() for p in (root/'etc/config').iterdir()} == initial
        events=[json.loads(line) for line in (root/'nft-events').read_text().splitlines()] if (root/'nft-events').exists() else []
        if scenario in ['wrong-model','wrong-board','bad-source','existing-probe','wan-down','no-lan','device-mismatch','wan-failed','syntax-failed']:
            assert not any(e[0]=='-f' for e in events), scenario
print(f'PASS: {len(scenarios)} scenarios ({args.shell}); source comparison, exact PC scope, unchanged configs, failures/signals cleanup, independent watchdog')
