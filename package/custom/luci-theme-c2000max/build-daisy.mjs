// Rebuild the small, offline daisyUI stylesheet from the official npm archive.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const archive = join(root, 'daisyui-5.6.6.tgz');
const expected = '71c8b8f03bfaa2cfdb56ca809a50ab0f22e51edf569eab7efe379d3215c42066';
const actual = createHash('sha256').update(readFileSync(archive)).digest('hex');
if (actual !== expected) throw new Error('Official daisyUI archive hash mismatch');

const parts = [
  'base/properties.css', 'base/reset.css', 'base/rootcolor.css', 'base/svg.css',
  'components/button.css', 'components/navbar.css', 'components/menu.css',
  'components/card.css', 'components/badge.css', 'components/alert.css', 'components/input.css'
];
const output = ['/*! daisyUI 5.6.6; MIT license. See DAISYUI-LICENSE. Selected components for C2000MAX. */', '@layer base, utilities;'];
for (const part of parts) {
  const result = spawnSync('tar', ['-xOzf', archive, `package/${part}`], { encoding: 'utf8', maxBuffer: 1024 * 1024 });
  if (result.status !== 0 || !result.stdout) throw new Error(`Unable to extract ${part}: ${result.stderr}`);
  output.push(result.stdout);
}
const destination = join(root, 'htdocs', 'luci-static', 'c2000max', 'daisyui.css');
writeFileSync(destination, output.join('\n'), 'utf8');
console.log(`Built ${destination} (${readFileSync(destination).length} bytes)`);
