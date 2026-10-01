#!/usr/bin/env python3
"""Run with a jq built --without-oniguruma, as shipped in this firmware."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

board = Path(__file__).resolve().parents[1]
led = board / 'files/usr/sbin/c2000max-leds'
jq = Path(sys.argv[1] if len(sys.argv) > 1 else shutil.which('jq')).resolve()
probe = subprocess.run([str(jq), '-n', '"x" | test("x")'], capture_output=True, text=True)
assert probe.returncode != 0 and 'without ONIGURUMA' in probe.stderr, (
    'Supply a jq built --without-oniguruma; a full host jq misses this regression.'
)

def info(*samples):
    return json.dumps({'modem_info': [
        {'key': key, 'value': value, 'extra_info': tag}
        for key, value, tag in samples
    ]}, ensure_ascii=False)

with tempfile.TemporaryDirectory(prefix='c2000max-led-jq-') as tmp:
    folder = Path(tmp)
    (folder / 'jq').symlink_to(jq)
    env = dict(os.environ, PATH=str(folder) + ':' + os.environ['PATH'])
    command = 'set -- --library; . ' + shlex.quote(str(led)) + '; parse_rsrp'
    # The SRM825 diagnostic has a plain RSRP entry with unit in a separate field.
    srm825 = json.dumps({'result': {}, 'modem_info': [
        {'key': 'network_mode', 'value': 'NR5G-SA Mode'},
        {'key': 'RSRP', 'value': '-103', 'unit': 'dBm',
         'type': 'progress_bar', 'class': 'Cell Information'}
    ]})
    cases = [
        ('SRM825 cache', srm825, '-103'),
        ('MT5700 plain numeric sample', info(('RSRP', '-77', 'NR')), '-77'),
        ('LTE numeric JSON value', info(('RSRP', -85, 'LTE')), '-85'),
        ('Unicode minus and units', info((' R s R p ', ' −85.4 dBm ', 'LTE')), '-85'),
        ('NR priority in NSA', info(('RSRP', '-95', 'NR'), ('RSRP', '-70', 'LTE')), '-95'),
        ('5G priority', info(('RSRP', '-70', 'LTE'), ('RSRP', '-96', '5g')), '-96'),
        ('last valid NR sample', info(('RSRP', '-95', 'NR'), ('RSRP', '-84', 'NR')), '-84'),
        ('invalid NR falls back to LTE', info(('RSRP', '-32768', 'NR'), ('RSRP', '-86', 'LTE')), '-86'),
        ('limits', info(('RSRP', '-156', ''), ('RSRP', '-31', '')), '-31'),
        ('out of range', info(('RSRP', '-157', ''), ('RSRP', '-30', '')), ''),
        ('sentinels and malformed values', info(('RSRP', None, ''), ('RSRP', 'unknown', ''),
            ('RSRP', '99', ''), ('RSRP', '-85 trailing', ''), ('RSRP', '--85', '')), ''),
        ('empty info', '{"modem_info":[]}', ''),
        ('missing info', '{}', ''),
        ('truncated cache', '{"modem_info":[', ''),
        ('multiple complete documents', info(('RSRP', '-77', 'LTE')) + '\n' + srm825, '-103'),
    ]
    for name, data, expected in cases:
        result = subprocess.run(['sh', '-c', command], input=data, env=env,
            capture_output=True, text=True, timeout=5)
        assert result.returncode == 0 and result.stdout.strip() == expected, (name, result)
    # The same cached sample must reach the physical RGB output, without AT reads.
    (folder / 'cache_cell_info_modem').write_text(srm825)
    for name in ['blue:sig1', 'blue:sig2', 'blue:sig3']:
        node = folder / name
        node.mkdir()
        for attr in ['trigger', 'brightness', 'delay_on', 'delay_off']:
            (node / attr).write_text('0')
    command = 'set -- --library; . ' + shlex.quote(str(led)) + '''
first_qmodem_section() { echo modem; }
data_online() { return 0; }
led_user_managed() { return 1; }
uci() { :; }
good=-80; weak=-90
update_signal
'''
    env.update(C2000MAX_MODEM_CACHE_DIR=str(folder), C2000MAX_LED_SYSFS=str(folder))
    subprocess.run(['sh', '-c', command], env=env, check=True, timeout=5)
    for name, value in zip(['blue:sig1', 'blue:sig2', 'blue:sig3'], [0, 0, 1]):
        assert (folder / name / 'trigger').read_text().strip() == 'none'
        assert (folder / name / 'brightness').read_text().strip() == str(value)

print('PASS: no-regex jq, 15 signal formats, NR priority, SRM825 cache and steady red RGB output')
