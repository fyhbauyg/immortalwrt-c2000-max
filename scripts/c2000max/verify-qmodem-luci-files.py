#!/usr/bin/env python3
"""Check QModem view routes and Lua compatibility in an assembled rootfs."""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
failures = []
required = [
    'www/luci-static/resources/qmodem/qmodem.js',
    'www/luci-static/resources/view/qmodem/overview.js',
    'usr/lib/lua/luci/cbi.lua',
    'usr/lib/lua/luci/ucodebridge.lua',
    'usr/share/luci/menu.d/luci-app-qmodem-next.json',
    'usr/share/rpcd/acl.d/luci-app-qmodem-next.json',
    'usr/share/luci/menu.d/luci-base.json',
    'usr/share/luci/menu.d/luci-mod-status.json',
]
for path in required:
    p = root / path
    if not p.is_file() or p.stat().st_size == 0:
        failures.append('missing or empty: /' + path)
for relative in ['usr/share/luci/menu.d/luci-base.json',
                 'usr/share/luci/menu.d/luci-mod-status.json',
                 'usr/share/luci/menu.d/luci-app-qmodem-next.json',
                 'usr/share/rpcd/acl.d/luci-app-qmodem-next.json']:
    menu = root / relative
    if not menu.is_file():
        continue
    try:
        entries = json.loads(menu.read_text())
        if not isinstance(entries, dict) or not entries:
            raise ValueError('expected a nonempty object')
        if relative.endswith('/luci-base.json') and 'admin' not in entries:
            raise ValueError('missing admin root route')
        if relative == 'usr/share/luci/menu.d/luci-app-qmodem-next.json':
            for route, entry in entries.items():
                action = entry.get('action', {})
                if action.get('type') == 'view':
                    view = root / ('www/luci-static/resources/view/' + action['path'] + '.js')
                    if not view.is_file() or not view.stat().st_size:
                        failures.append('missing view for ' + route + ': /' + str(view.relative_to(root)))
    except (ValueError, KeyError, AttributeError) as error:
        failures.append('invalid menu/ACL: /' + relative + ': ' + str(error))
print(json.dumps({'result': 'FAIL' if failures else 'PASS', 'failures': failures}, ensure_ascii=False))
sys.exit(bool(failures))
