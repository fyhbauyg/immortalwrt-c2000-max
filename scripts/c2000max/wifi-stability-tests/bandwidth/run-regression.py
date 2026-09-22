#!/usr/bin/env python3
"""Build exact callback bodies against host fakes; never touches driver trees."""
from pathlib import Path
import argparse
import difflib
import subprocess
import tempfile

base = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--source-tree', type=Path, help='prepared patched driver root containing mt_wifi/')
parser.add_argument('--baseline-tree', type=Path, help='optional unpatched driver root; must reproduce failures')
args = parser.parse_args()

def bodies(source):
    start = source.index('void CFG8021DRV_AP_PHYINIT(')
    end = source.index('\nint CFG80211DRV_AP_OpsSetChannel(', start)
    return source[start:end]

def tree_source(tree):
    return (tree / 'mt_wifi/os/linux/cfg80211/cfg80211drv.c').read_text()

cases = []
if args.source_tree:
    if args.baseline_tree:
        cases.append(('original', bodies(tree_source(args.baseline_tree))))
    cases.append(('patched', bodies(tree_source(args.source_tree))))
else:
    # Local patch preparation only. Prepared-tree regressions above do not
    # need audit staging, the original full source, or any production writes.
    original = (base / 'cfg80211drv.original.c').read_text()
    start = original.index('void CFG8021DRV_AP_PHYINIT(')
    end = original.index('\nint CFG80211DRV_AP_OpsSetChannel(', start)
    replacement = (base / 'bandwidth-functions.c').read_text()
    patched = original[:start] + replacement + '\n\n' + original[end:]
    (base / 'cfg80211drv.patched.c').write_text(patched)
    patch = ''.join(difflib.unified_diff(original.splitlines(True), patched.splitlines(True),
        fromfile='a/mt_wifi/os/linux/cfg80211/cfg80211drv.c',
        tofile='b/mt_wifi/os/linux/cfg80211/cfg80211drv.c'))
    (base / '024-fix-cfg80211-bandwidth-state-and-errors.patch').write_text(patch)
    cases = [('original', original[start:end]), ('patched', replacement)]
harness = (base / 'bw-harness.c').read_text()
with tempfile.TemporaryDirectory(prefix='c2000max-bw-regression-') as temporary:
    output = Path(temporary)
    for name, functions in cases:
        path = output / ('test-' + name + '.c')
        path.write_text(harness.replace('/* FUNCTIONS */', functions))
        flags = ['-Wno-unused-but-set-variable'] if name == 'original' else []
        subprocess.run(['cc', '-std=gnu99', '-Wall', '-Wextra', '-Werror', *flags,
            '-Wno-unused-parameter', '-Wno-unused-function', '-Wno-implicit-fallthrough',
            str(path), '-o', str(output / ('test-' + name))], check=True)
        proc = subprocess.run([str(output / ('test-' + name))], capture_output=True, text=True)
        print(name + ':\n' + proc.stdout + proc.stderr, flush=True)
        if name == 'original' and proc.returncode == 0:
            raise SystemExit('Original unexpectedly passed: regression is not discriminating')
        if name == 'patched' and proc.returncode != 0:
            raise SystemExit('Patched callbacks failed')
print('PASS: callback regression passed.')
