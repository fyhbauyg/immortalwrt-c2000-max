import argparse
import hashlib
import tarfile
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser(description='Exercise the hotfix installer against OpenWrt libraries and simulated router state.')
parser.add_argument('--bundle', required=True, type=Path)
parser.add_argument('--jq', required=True, type=Path)
parser.add_argument('--shell', default='bash')
parser.add_argument('--baseline', default='b65c38c71e')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
bundle = args.bundle.resolve()
jq = args.jq.resolve()
oldtable = subprocess.check_output(['git', '-C', str(repo), 'show', args.baseline+':package/custom/qmodem/application/qmodem/files/usr/share/qmodem/modem_support.json'])
archive=bundle.with_suffix('.tar.gz')
with tarfile.open(archive) as packaged:
    assert all(member.mtime == 0 for member in packaged.getmembers())
with tempfile.TemporaryDirectory(prefix='sim8260-install-test-') as temporary:
    base = Path(temporary)
    bindir = base/'bin'; bindir.mkdir()
    (bindir/'jq').symlink_to(jq)
    (bindir/'id').write_text('#!/bin/sh\necho 0\n'); (bindir/'id').chmod(0o755)
    (bindir/'uci').write_text('''#!/usr/bin/env python3
import json,os,sys
path=os.environ['MOCK_UCI']; state=json.load(open(path)); args=[a for a in sys.argv[1:] if a!='-q']
action,key=args[:2] if len(args)>1 else (args[0],'')
if action=='get':
 if key not in state: sys.exit(1)
 value=state[key]; print(' '.join(value) if isinstance(value,list) else value)
elif action=='set':
 key,value=key.split('=',1);state[key]=value
elif action=='delete': state.pop(key,None)
elif action=='add_list':
 key,value=key.split('=',1);state.setdefault(key,[]).append(value)
elif action=='commit': pass
else: sys.exit(2)
json.dump(state,open(path,'w'))
'''); (bindir/'uci').chmod(0o755)
    # Diagnose uses fake read-only commands, including long IDs that must be removed.
    for name in ['lsusb','ip','ubus','ps','ping','nslookup','logread','dmesg']:
        (bindir/name).write_text('#!/bin/sh\necho "'+name+' $*"\necho "IMEI: 123456789012345"\necho "password=SECRET"\n')
        (bindir/name).chmod(0o755)

    def transform(text, root):
        text=re.sub(r'/(root|tmp|etc|usr|sys|dev|lib)/', lambda match: str(root)+match[0], text)
        text=text.replace('$bundle/payload'+str(root)+'/usr/', '$bundle/payload/usr/')
        text=text.replace('-C /tmp ', '-C '+shlex.quote(str(root/'tmp'))+' ')
        text=text.replace('"/$path"','"'+str(root)+'/$path"')
        text=text.replace('destination="/$path"','destination="'+str(root)+'/$path"')
        text=text.replace('[ -c "$port" ]', '[ -e "$port" ]')
        return text

    def fixture(label, fail_stop=False):
        root=base/label; root.mkdir()
        for path in ['tmp/sysinfo','root','etc/init.d','etc/config','dev','usr/share/qmodem/vendor','lib/config']:
            (root/path).mkdir(parents=True,exist_ok=True)
        (root/'tmp/sysinfo/board_name').write_text('nradio,c2000-max\n')
        (root/'dev/ttyUSB2').touch()
        (root/'etc/config/qmodem').write_text('original qmodem with user settings\n')
        (root/'usr/share/qmodem/modem_support.json').write_bytes(oldtable)
        for path, original, fixed in [line.split() for line in (bundle/'allowed-files.txt').read_text().splitlines()]:
            if original=='absent': continue
            blob=subprocess.check_output(['git','-C',str(repo),'show',args.baseline+':package/custom/qmodem/application/qmodem/files/'+path])
            assert hashlib.sha256(blob).hexdigest()==original
            (root/path).write_bytes(blob)
        # Source the actual OpenWrt libraries that expose the optional IPKG_INSTROOT.
        for target, source in [('lib/functions.sh', 'package/base-files/files/lib/functions.sh'),
                               ('lib/config/uci.sh', 'package/system/uci/files/lib/config/uci.sh')]:
            (root/target).write_text(transform((repo/source).read_text(), root))
        (root/'usr/share/qmodem/modem_util.sh').write_text(transform('''. /lib/functions.sh
at_timeout() {
 case "$2" in
 'AT+CGMM') printf '%s\\r\\n' 'AT+CGMM' '+CGMM: SIMCOM_SIM8260G-M2' OK ;;
 *) printf '%s\\r\\n' "command=$2" 'IMEI: 123456789012345' 'password=SECRET' OK ;;
 esac
}
''', root))
        (root/'usr/share/qmodem/fm350.sh').write_bytes((repo/'package/custom/qmodem/application/qmodem/files/usr/share/qmodem/fm350.sh').read_bytes())
        for service in ['qmodem_init','qmodem_network']:
            text='#!/bin/sh\necho "'+service+' $*" >> '+shlex.quote(str(root/'services'))+'\n'
            if fail_stop and service=='qmodem_init': text+='[ "$1" != stop ] || exit 1\n'
            (root/'etc/init.d'/service).write_text(text)
            (root/'etc/init.d'/service).chmod(0o755)
        local=root/'bundle'; local.mkdir()
        for path in bundle.rglob('*'):
            if not path.is_file(): continue
            destination=local/path.relative_to(bundle);destination.parent.mkdir(parents=True,exist_ok=True)
            if path.name in ['install.sh','rollback.sh','diagnose.sh']:
                destination.write_text(transform(path.read_text(),root))
            else: destination.write_bytes(path.read_bytes())
        # Transform diagnostic helper's source path, already done with all /usr/ references.
        uci=root/'uci.json';uci.write_text(json.dumps({'qmodem.2_1':'modem-device','qmodem.2_1.at_port':str(root/'dev/ttyUSB2'),'qmodem.2_1.name':'simcom_a8200_serias','qmodem.2_1.platform':'asrmicro','qmodem.2_1.pdp_index':'3','qmodem.2_1.apn':'auto','qmodem.2_1.enable_dial':'1','qmodem.other.apn':'custom-preserved'}))
        env=dict(os.environ,PATH=str(bindir)+':'+os.environ['PATH'],MOCK_UCI=str(uci))
        env.pop('IPKG_INSTROOT', None)
        return root,local,env

    root,local,env=fixture('nounset-reproduction')
    installer=local/'install.sh'
    installer.write_text(installer.read_text().replace('set -e\n', 'set -eu\n', 1))
    before=(root/'uci.json').read_bytes()
    result=subprocess.run([args.shell,str(installer),'2_1'],env=env,text=True,capture_output=True,timeout=12)
    assert result.returncode != 0 and 'IPKG_INSTROOT' in result.stderr, result
    assert (root/'uci.json').read_bytes()==before and not (root/'services').exists()
    assert not list((root/'root').glob('c2000max-sim8260-backup-*'))

    root,local,env=fixture('normal')
    initial={path:(root/path).read_bytes() for path,_,_ in [l.split() for l in (local/'allowed-files.txt').read_text().splitlines()] if (root/path).exists()}
    result=subprocess.run([args.shell,str(local/'install.sh'),'2_1'],env=env,text=True,capture_output=True,timeout=12)
    assert result.returncode==0,result
    state=json.loads((root/'uci.json').read_text())
    assert state['qmodem.2_1.platform']=='qualcomm' and state['qmodem.2_1.pdp_index']=='3'
    assert state['qmodem.2_1.apn']=='auto' and state['qmodem.other.apn']=='custom-preserved'
    table=json.loads((root/'usr/share/qmodem/modem_support.json').read_text())
    original_table=json.loads(oldtable)
    for candidate in [table,original_table]:
        for name in ['simcom_sim8260g-m2','sim8260g-m2']:
            candidate['modem_support']['usb'].pop(name,None)
    assert table==original_table
    assert (root/'services').read_text().splitlines()==['qmodem_init stop','qmodem_init start','qmodem_network redial 2_1']
    first_backup=next((root/'root').glob('c2000max-sim8260-backup-*'))
    repeat=subprocess.run([args.shell,str(local/'install.sh'),'2_1'],env=env,text=True,capture_output=True,timeout=12)
    assert repeat.returncode==0,repeat
    rollback=subprocess.run([args.shell,str(first_backup/'rollback.sh'),str(first_backup)],env=env,text=True,capture_output=True,timeout=12)
    assert rollback.returncode==0,rollback
    for path,blob in initial.items(): assert (root/path).read_bytes()==blob
    for path,_,_ in [line.split() for line in (local/'allowed-files.txt').read_text().splitlines()]:
        if path not in initial: assert not (root/path).exists()
    assert (root/'usr/share/qmodem/modem_support.json').read_bytes()==oldtable
    assert (root/'etc/config/qmodem').read_text()=='original qmodem with user settings\n'

    root,local,env=fixture('unknown')
    (root/'usr/share/qmodem/modem_dial.sh').write_text('#!/bin/sh\ncustom changes\n')
    result=subprocess.run([args.shell,str(local/'install.sh'),'2_1'],env=env,text=True,capture_output=True,timeout=12)
    assert result.returncode!=0 and not (root/'services').exists(),result

    root,local,env=fixture('failed-stop',True)
    result=subprocess.run([args.shell,str(local/'install.sh'),'2_1'],env=env,text=True,capture_output=True,timeout=12)
    assert result.returncode!=0 and (root/'usr/share/qmodem/modem_support.json').read_bytes()==oldtable,result
    for path,original,_ in [line.split() for line in (local/'allowed-files.txt').read_text().splitlines()]:
        if original=='absent': assert not (root/path).exists()
        else: assert hashlib.sha256((root/path).read_bytes()).hexdigest()==original

    root,local,env=fixture('diagnostic')
    result=subprocess.run([args.shell,str(local/'diagnose.sh'),'2_1'],env=env,text=True,capture_output=True,timeout=15)
    assert result.returncode==0,result
    folder=next(path for path in (root/'tmp').glob('sim8260-diag-*') if path.is_dir())
    assert folder.is_dir()
    files=list(folder.glob('at-*.txt')); assert len(files)==20
    content='\n'.join(p.read_text() for p in files)
    assert '123456789012345' not in content and 'SECRET' not in content and '[redacted-id]' in content
    assert not (root/'services').exists()
print('PASS ('+args.shell+'): real OpenWrt libraries, reproduced nounset failure before changes, no-regex jq installer, preserve custom APN/CID/other profiles, repeat installation, rollback, unknown-version guard, failure recovery and read-only redacted diagnostics')
