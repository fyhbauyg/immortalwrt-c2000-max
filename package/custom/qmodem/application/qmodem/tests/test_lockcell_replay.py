#!/usr/bin/env python3
import os
import shlex
import subprocess
import tempfile
from pathlib import Path

qm = Path(__file__).resolve().parents[1]
root = qm.parents[4]

with tempfile.TemporaryDirectory() as directory:
    d = Path(directory)
    util = d / 'util.sh'
    util.write_text((qm / 'files/usr/share/qmodem/modem_util.sh').read_text().replace('. /lib/functions.sh', ':'))
    vendor = d / 'fibocom.sh'
    vendor.write_text((qm / 'files/usr/share/qmodem/vendor/fibocom.sh').read_text().replace('source /usr/share/qmodem/generic.sh', ':'))
    hook = d / 'hook.sh'
    hook.write_text((qm / 'files/usr/share/qmodem/modem_hook.sh').read_text().replace('. /lib/functions.sh', ':').replace('. /usr/share/qmodem/modem_util.sh', ':'))
    setup = f'''
source {shlex.quote(str(util))}
source {shlex.quote(str(vendor))}
calls={shlex.quote(str(d / 'calls'))}
attempts={shlex.quote(str(d / 'attempts'))}
FAKE_ENABLED=1
FAKE_COMMAND='AT+GTCELLLOCK=1,1,0,633984,101,1,5078'
FAKE_RESPONSE=$'\\r\\nOK\\r\\n'
FAIL_FIRST=0
config_section=modem
at_port=/dev/null
uci() {{
    case "$*" in
        '-q get qmodem.modem.lockcell_boot_hook_enabled') echo "$FAKE_ENABLED" ;;
        '-q get qmodem.modem.lockcell_boot_hook_delay') echo 0 ;;
        *) printf 'uci:%s\\n' "$*" >> "$calls" ;;
    esac
}}
config_load() {{ :; }}
config_get() {{
    case "$3" in
        at_port) printf -v "$1" /dev/zero ;;
        override_at_port) printf -v "$1" /dev/null ;;
        *) printf -v "$1" 0 ;;
    esac
}}
config_list_foreach() {{
    case "$2" in
        lockcell_boot_hook_at_cmds) "$3" "$FAKE_COMMAND" ;;
    esac
    return 0
}}
m_debug() {{ printf 'log:%s\\n' "$*" >> "$calls"; }}
sleep() {{ printf 'sleep:%s\\n' "$*" >> "$calls"; }}
at_timeout() {{
    printf 'at:%s:%s:%s\\n' "$1" "$2" "$3" >> "$calls"
    n=$(cat "$attempts" 2>/dev/null || echo 0)
    echo $((n + 1)) > "$attempts"
    if [[ "$FAIL_FIRST" == 1 && "$n" == 0 ]]; then echo ERROR; else printf '%s' "$FAKE_RESPONSE"; fi
}}
at() {{ at_timeout "$1" "$2" 5; }}
'''

    def run(body):
        (d / 'calls').write_text('')
        (d / 'attempts').write_text('0')
        result = subprocess.run(['bash', '-c', setup + '\n' + body], text=True, capture_output=True)
        assert result.returncode == 0, (body, result.stdout, result.stderr)
        return (d / 'calls').read_text()

    for stage in ['post_init', 'pre_dial']:
        calls = run(f'set -- modem {stage}; source {shlex.quote(str(hook))}')
        assert 'at:/dev/null:AT+GTCELLLOCK=' in calls and 'at:/dev/zero:' not in calls, calls
    calls = run('FAKE_ENABLED=0; qmodem_lockcell_boot_hook_replay modem /dev/null')
    assert 'at:' not in calls, calls
    calls = run('FAIL_FIRST=1; qmodem_lockcell_boot_hook_replay modem /dev/null')
    assert calls.count('at:') == 2 and 'uci:' not in calls, calls
    calls = run('FAKE_RESPONSE=ERROR; if qmodem_lockcell_boot_hook_replay modem /dev/null; then exit 8; fi')
    assert calls.count('at:') == 3 and 'saved settings retained' in calls and 'uci:' not in calls, calls
    calls = run('qmodem_lockcell_boot_hook_sync modem "" "$FAKE_COMMAND"')
    assert 'set qmodem.modem.lockcell_boot_hook_enabled=1' in calls, calls
    calls = run('qmodem_lockcell_boot_hook_sync modem 0 "$FAKE_COMMAND"')
    assert 'delete qmodem.modem.lockcell_boot_hook_at_cmds' in calls, calls
    lock = 'rat=1; pci=101; arfcn=633984; band=78; scs=1; en_boot_hook=1; lockcell_all'
    calls = run('FAKE_RESPONSE=ERROR; ' + lock)
    assert 'uci:' not in calls, calls
    calls = run('FAKE_RESPONSE=ERROR; pci=; arfcn=; lockcell_all')
    assert 'uci:' not in calls, calls
    calls = run('at() { echo OK; return 9; }; ' + lock)
    assert 'uci:' not in calls, calls
    calls = run('at() { echo OK; return 9; }; pci=; arfcn=; lockcell_all')
    assert 'uci:' not in calls, calls
    calls = run(lock)
    assert 'add_list qmodem.modem.lockcell_boot_hook_at_cmds=AT+GTCELLLOCK=1,1,0,633984,101,1,5078' in calls, calls
    calls = run('pci=; arfcn=; lockcell_all')
    assert 'delete qmodem.modem.lockcell_boot_hook_at_cmds' in calls, calls
    run("qmodem_at_response_ok $'AT+GTCELLLOCK=0\\r\\nOK\\r\\n'; if qmodem_at_response_ok $'OK\\n+CME ERROR: 10'; then exit 8; fi")

    # A spawned dial process must acquire its own locks, even while its
    # parent still owns a SIM transaction.
    fake = d / 'qmodem_network'
    fake.write_text('#!/bin/bash\nenv > "' + str(d / 'redial-env') + '"\n')
    fake.chmod(0o755)
    sim = d / 'sim.sh'
    sim.write_text((root / 'package/custom/c2000max-board/files/usr/sbin/c2000max-sim').read_text().replace('/etc/init.d/qmodem_network', str(fake)))
    subprocess.run(['bash', '-c', f'''
export C2000MAX_SIM_LIBRARY_ONLY=1 C2000MAX_SIM_SKIP_REDIAL=0
source {shlex.quote(str(sim))}
export QMODEM_AT_TRANSACTION_PORT=/dev/old
export QMODEM_AT_TRANSACTION_PORT_KEY=old
export QMODEM_AT_TRANSACTION_DAEMON_LOCK=/tmp/global
export QMODEM_AT_TRANSACTION_DAEMON_LOCKED=1
request_modem_redial modem
wait
'''], check=True)
    assert 'QMODEM_AT_TRANSACTION_' not in (d / 'redial-env').read_text()

print('PASS: saved lock replays on initialization and redial, overrides use correct tty, bounded failures retain UCI, only OK commits changes, redial owns fresh locks')
