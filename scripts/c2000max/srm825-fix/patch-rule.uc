import { readfile, writefile } from 'fs';
let rules = json(readfile(ARGV[0]));
let rule = rules?.modem_port_rule?.usb?.['2dee:4d23'];
if (type(rule) != 'object' || type(rule.include) != 'array' || index(rule.include, '1.1') < 0)
    die('Unexpected SRM825 ECM rule; no change made.\n');
// Legacy scanners apply this list to both serial and network interfaces.
if (index(rule.include, '1.5') < 0) push(rule.include, '1.5');
if (!writefile(ARGV[1], sprintf('%J\n', rules))) die('Failed to write rule file.\n');
