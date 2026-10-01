#!/usr/bin/env python3
"""Package the SIM8260 hotfix from a checkout without router access."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', default='7288f8dbb1', help='Known pre-fix QModem commit')
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
tools = Path(__file__).resolve().parent
package = repo / 'package/custom/qmodem/application/qmodem'
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
inventory=[]
for relative in ['usr/share/qmodem/modem_dial.sh', 'usr/share/qmodem/vendor/simcom.sh', 'usr/share/qmodem/pdp_address.sh', 'usr/share/qmodem/simcom_network.sh']:
    source=package/'files'/relative
    destination=output/'payload'/relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    fixed=hashlib.sha256(source.read_bytes()).hexdigest()
    git_path='package/custom/qmodem/application/qmodem/files/'+relative
    if relative.endswith(('pdp_address.sh','simcom_network.sh')):
        original='absent'
    else:
        original=hashlib.sha256(subprocess.check_output(['git','-C',str(repo),'show',args.baseline+':'+git_path])).hexdigest()
    inventory.append(f'{relative} {original} {fixed}')
for name in ['install.sh','diagnose.sh','rollback.sh','README.txt']:
    shutil.copyfile(tools/name,output/name)
profile=json.loads((package/'files/usr/share/qmodem/modem_support.json').read_text())['modem_support']['usb']['simcom_sim8260g-m2']
(output/'profile.json').write_text(json.dumps(profile, indent=2)+'\n')
(output/'allowed-files.txt').write_text('\n'.join(inventory)+'\n')
contents=['profile.json','allowed-files.txt']+[str(p.relative_to(output)).replace('\\','/') for p in (output/'payload').rglob('*') if p.is_file()]
(output/'payload.sha256').write_text(''.join(hashlib.sha256((output/p).read_bytes()).hexdigest()+'  '+p+'\n' for p in sorted(contents)))
archive=output.with_suffix('.tar.gz')
def metadata(info):
    info.uid=info.gid=0
    info.uname=info.gname='root'
    # Router clocks can lag while cellular service is offline.
    info.mtime=0
    info.pax_headers={}
    info.mode=0o755 if info.isdir() or info.name.endswith('.sh') else 0o644
    return info
with tarfile.open(archive,'w:gz') as tar:
    tar.add(output,arcname=output.name,filter=metadata)
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_name(archive.name+'.sha256').write_text(digest+'  '+archive.name+'\n')
print(f'{archive}\nSHA256 {digest}')
