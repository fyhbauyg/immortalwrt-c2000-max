import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description='Verify the NDP trial installer and rollback against simulated router state.')
parser.add_argument('--jq', required=True, type=Path)
parser.add_argument('--shell', default='dash')
args = parser.parse_args()
source = (Path(__file__).resolve().parent / 'enable_ndp_test.sh').read_text()
scenarios = ['normal', 'wrong-model', 'wrong-board', 'pending', 'wan-down',
             'no-extension', 'other-master', 'anonymous-master', 'custom-target',
             'commit-failed', 'restart-failed', 'later-edit', 'later-pending']
with tempfile.TemporaryDirectory(prefix='sim8260-ndp-trial-') as temporary:
    base = Path(temporary)
    for scenario in scenarios:
        root = base / scenario
        for folder in ['bin', 'tmp/sysinfo', 'root', 'etc/config', 'etc/init.d']:
            (root / folder).mkdir(parents=True, exist_ok=True)
        def executable(path, text):
            path.write_text(text)
            path.chmod(0o755)
        executable(root / 'bin/id', '#!/bin/sh\necho 0\n')
        (root / 'bin/jq').symlink_to(args.jq.resolve())
        (root / 'tmp/sysinfo/board_name').write_text('different,board\n' if scenario == 'wrong-board' else 'nradio,c2000-max\n')
        original = {
            'dhcp.lan': 'dhcp', 'dhcp.lan.interface': 'lan', 'dhcp.lan.ra': 'server',
            'dhcp.lan.dhcpv6': 'disabled', 'dhcp.lan.ra_slaac': '1',
            'dhcp.lan.max_preferred_lifetime': '2700', 'dhcp.lan.max_valid_lifetime': '5400',
            'dhcp.lan.start': '100', 'dhcp.lan.limit': '150', 'dhcp.lan.leasetime': '12h',
            'dhcp.wan': 'dhcp', 'dhcp.wan.interface': 'wan', 'dhcp.wan.ignore': '1',
            'dhcp.pc': 'host', 'dhcp.pc.name': 'desktop', 'dhcp.pc.ip': '192.168.66.159',
        }
        if scenario in ['other-master', 'anonymous-master']:
            section = 'other' if scenario == 'other-master' else '@dhcp[0]'
            original['dhcp.' + section] = 'dhcp'
            original['dhcp.' + section + '.master'] = '1'
        if scenario == 'custom-target':
            original.update({'dhcp.eth2v6': 'dhcp', 'dhcp.eth2v6.dhcpv6': 'relay'})
        config = root / 'etc/config/dhcp'
        config.write_text(json.dumps(original, indent=2) + '\n')
        original_bytes = config.read_bytes()
        metadata = {'qmodem.2_1': 'modem-device', 'qmodem.2_1.name': 'simcom_sim8260g-m2',
                    'qmodem.2_1.alias': 'eth2', 'qmodem.2_1.extend_prefix': '1',
                    'network.eth2v6.extendprefix': '1'}
        if scenario == 'wrong-model': metadata['qmodem.2_1.name'] = 'fm150_ae'
        if scenario == 'no-extension': metadata['network.eth2v6.extendprefix'] = '0'
        (root / 'metadata.json').write_text(json.dumps(metadata))
        (root / 'pending.json').write_text(json.dumps({'dhcp.lan.ndp': 'disabled'} if scenario == 'pending' else {}))
        executable(root / 'bin/uci', r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root=Path(os.environ['MOCK_ROOT'])
config=root/'etc/config/dhcp'
pending_path=root/'pending.json'
committed=json.loads(config.read_text())
pending=json.loads(pending_path.read_text())
state={**json.loads((root/'metadata.json').read_text()), **committed, **pending}
args=[a for a in sys.argv[1:] if a!='-q']
action,key=args[:2]
if action=='get':
    if key not in state: sys.exit(1)
    print(state[key])
elif action=='show':
    for k,v in state.items():
        if k.startswith(key+'.'):
            print(k+'='+v if k.count('.')==1 else k+'='+repr(v))
elif action=='changes':
    for k,v in pending.items(): print(k+'='+repr(v))
elif action in ['set','commit','revert']:
    with (root/'uci-events').open('a') as f: f.write(action+' '+key+'\n')
    assert key.startswith('dhcp.') if action=='set' else key=='dhcp'
    if action=='set':
        k,v=key.split('=',1); pending[k]=v
    elif action=='commit':
        if os.environ['MOCK_SCENARIO']=='commit-failed': sys.exit(8)
        committed.update(pending)
        config.write_text(json.dumps(committed, indent=2)+'\n')
        pending={}
    else: pending={}
    pending_path.write_text(json.dumps(pending))
else: sys.exit(2)
''')
        executable(root / 'bin/ubus', '''#!/bin/sh
[ "$*" = 'call network.interface.eth2v6 status' ] || exit 9
if [ "$MOCK_SCENARIO" = wan-down ]; then echo '{"up":false}'; else echo '{"up":true,"l3_device":"usb0"}'; fi
''')
        executable(root / 'etc/init.d/odhcpd', '''#!/bin/sh
[ "$*" = restart ] || exit 9
echo odhcpd-restart >> "$MOCK_ROOT/service-events"
if [ "$MOCK_SCENARIO" = restart-failed ] && [ ! -f "$MOCK_ROOT/failed-once" ]; then
    touch "$MOCK_ROOT/failed-once"
    exit 7
fi
''')
        transformed = re.sub(r'/(root|tmp|etc)/', lambda match: str(root) + match[0], source)
        installer = root / 'installer.sh'
        installer.write_text(transformed)
        env = dict(os.environ, MOCK_ROOT=str(root), MOCK_SCENARIO=scenario,
                   PATH=str(root / 'bin') + ':' + os.environ['PATH'])
        result = subprocess.run([args.shell, str(installer), '2_1'], env=env,
                                text=True, capture_output=True, timeout=12)
        backups = list((root / 'root').glob('c2000max-sim8260-ndp-backup-*'))
        services = (root / 'service-events').read_text().splitlines() if (root / 'service-events').exists() else []
        if scenario in ['normal', 'later-edit', 'later-pending']:
            assert result.returncode == 0, (scenario, result)
            expected = dict(original)
            expected.update({'dhcp.eth2v6': 'dhcp', 'dhcp.eth2v6.interface': 'eth2v6',
                             'dhcp.eth2v6.master': '1', 'dhcp.eth2v6.ndp': 'relay',
                             'dhcp.eth2v6.ra': 'disabled', 'dhcp.eth2v6.dhcpv6': 'disabled',
                             'dhcp.eth2v6.ignore': '1', 'dhcp.lan.ndp': 'relay'})
            assert json.loads(config.read_text()) == expected
            assert services == ['odhcpd-restart'] and len(backups) == 1
            backup = backups[0]
            assert (backup / 'dhcp').read_bytes() == original_bytes
            assert backup.stat().st_mode & 0o077 == 0
            assert (backup / 'rollback.sh').stat().st_mode & 0o077 == 0
            repeated = subprocess.run([args.shell, str(installer), '2_1'], env=env,
                                      text=True, capture_output=True, timeout=12)
            assert repeated.returncode == 0 and 'already configured' in repeated.stdout, repeated
            assert (root / 'service-events').read_text().splitlines() == services
            assert len(list((root / 'root').glob('c2000max-sim8260-ndp-backup-*'))) == 1
            if scenario == 'later-edit':
                expected['dhcp.lan.leasetime'] = '6h'
                config.write_text(json.dumps(expected, indent=2)+'\n')
            if scenario == 'later-pending':
                (root / 'pending.json').write_text(json.dumps({'dhcp.lan.start': '50'}))
            current = config.read_bytes()
            rolled = subprocess.run([args.shell, str(backup / 'rollback.sh')], env=env,
                                    text=True, capture_output=True, timeout=12)
            if scenario == 'normal':
                assert rolled.returncode == 0, rolled
                assert config.read_bytes() == original_bytes
                assert (root / 'service-events').read_text().splitlines() == ['odhcpd-restart'] * 2
            else:
                assert rolled.returncode != 0, rolled
                assert config.read_bytes() == current
                assert (root / 'service-events').read_text().splitlines() == services
        elif scenario in ['commit-failed', 'restart-failed']:
            assert result.returncode != 0, (scenario, result)
            assert config.read_bytes() == original_bytes
            assert json.loads((root / 'pending.json').read_text()) == {}
            assert len(backups) == 1
            assert services == ['odhcpd-restart'] * (2 if scenario == 'restart-failed' else 1)
        else:
            assert result.returncode != 0, (scenario, result)
            assert config.read_bytes() == original_bytes
            assert not backups and not services and not (root / 'uci-events').exists()
        assert json.loads((root / 'metadata.json').read_text()) == metadata
print(f'PASS: {len(scenarios)} scenarios ({args.shell}); NDP changes only, idempotence, rollback, conflict guards, failed commit/restart recovery')
