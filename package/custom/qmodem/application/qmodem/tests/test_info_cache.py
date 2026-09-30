#!/usr/bin/env python3
"""Exercise the shared info cache with real concurrent shell processes."""
import json
import os
import shlex
import subprocess
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
util = (root / 'files/usr/share/qmodem/modem_util.sh').read_text().replace('. /lib/functions.sh', ':')

with tempfile.TemporaryDirectory() as temp:
    d = Path(temp)
    (d/'util').write_text(util)
    worker = d/'worker'
    worker.write_text(f'''#!/bin/bash
source {shlex.quote(str(d/'util'))}
lock() {{
  case "$1" in
    -n) exec 9>"$2"; flock -xn 9 ;;
    -u) flock -u 9; exec 9>&- ;;
  esac
}}
json_init() {{ :; }}
json_add_array() {{ :; }}
json_close_array() {{ :; }}
generate() {{ echo worker >> "$DIR/started"; }}
json_dump() {{
  printf '%s' '{{"modem_info":['
  touch "$DIR/writing"
  while [ ! -f "$DIR/release" ]; do sleep 0.02; done
  if [ "$BROKEN" != 1 ]; then printf '%s' '{{"value":"new"}}]}}'; fi
}}
qmodem_info_cache 10 "$DIR/cache" generate
''')

    def run_async(broken=False):
        env = dict(os.environ, DIR=str(d), BROKEN='1' if broken else '0')
        return subprocess.Popen(['bash', str(worker)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def result(proc):
        out, err = proc.communicate(timeout=5)
        assert proc.returncode == 0, (out, err)
        return json.loads(out)

    def await_writing():
        deadline = time.monotonic() + 3
        while not (d/'writing').exists():
            assert time.monotonic() < deadline, 'worker did not start'
            time.sleep(.02)

    def reset():
        for name in ['cache', 'release', 'writing', 'started']:
            (d/name).unlink(missing_ok=True)

    # A cache miss has one producer. Other readers get valid pending JSON,
    # never a touched empty file or another slow worker.
    producer = run_async(); await_writing()
    assert not (d/'cache').exists()
    for _ in range(3):
        assert result(run_async()) == {'modem_info': [], 'cache_pending': True}
    assert (d/'started').read_text().splitlines() == ['worker']
    (d/'release').touch()
    assert result(producer) == {'modem_info': [{'value': 'new'}]}
    assert result(run_async()) == {'modem_info': [{'value': 'new'}]}
    assert len((d/'started').read_text().splitlines()) == 1

    # Keep a complete stale snapshot available throughout replacement.
    reset(); old = '{"modem_info":[{"value":"old"}]}'
    (d/'cache').write_text(old); os.utime(d/'cache', (1, 1))
    producer = run_async(); await_writing()
    assert (d/'cache').read_text() == old
    assert result(run_async()) == json.loads(old)
    assert (d/'cache').read_text() == old
    (d/'release').touch(); assert result(producer)['modem_info'][0]['value'] == 'new'

    # A truncated writer leaves the previous valid snapshot untouched.
    reset(); (d/'cache').write_text(old); os.utime(d/'cache', (1, 1))
    (d/'release').touch(); assert result(run_async(True)) == json.loads(old)
    assert (d/'cache').read_text() == old
    assert not list(d.glob('cache.tmp.*'))
    assert result(run_async())['modem_info'][0]['value'] == 'new', 'failure must release its lock'

    # A recent malformed cache and a future timestamp after NTP must refresh.
    reset(); (d/'cache').write_text('{'); (d/'release').touch()
    assert result(run_async())['modem_info'][0]['value'] == 'new'
    os.utime(d/'cache', (time.time()+1000, time.time()+1000))
    assert result(run_async())['modem_info'][0]['value'] == 'new'
    assert len((d/'started').read_text().splitlines()) == 2

print('PASS: concurrent cache misses, atomic stale replacement, invalid writers, malformed cache and clock changes')
