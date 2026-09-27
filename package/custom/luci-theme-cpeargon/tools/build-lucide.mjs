// Build a tiny local SVG sprite from Lucide's official ESM icon definitions.
// Usage: node tools/build-lucide.mjs PATH_TO_lucide/dist/esm/icons
import { writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const names = [
  'activity', 'arrow-right', 'blocks', 'card-sim', 'chart-no-axes-combined',
  'circle-user-round', 'cpu', 'download', 'external-link', 'eye', 'eye-off',
  'gauge', 'globe', 'hard-drive', 'house', 'key-round', 'layout-dashboard',
  'memory-stick', 'menu', 'monitor', 'moon', 'network', 'orbit', 'radio-tower',
  'router', 'settings', 'shield', 'signal', 'smartphone', 'sun', 'thermometer',
  'upload', 'wifi'
];
const iconsDir = process.argv[2] && resolve(process.argv[2]);
if (!iconsDir) throw new Error('Provide Lucide dist/esm/icons directory');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const escape = value => String(value).replace(/[&"<>]/g, ch => ({ '&':'&amp;', '"':'&quot;', '<':'&lt;', '>':'&gt;' })[ch]);
const symbols = [];
for (const name of names) {
  const nodes = (await import(pathToFileURL(resolve(iconsDir, `${name}.js`)).href)).default;
  const paths = nodes.map(([tag, attrs]) => `<${tag} ${Object.entries(attrs).map(([key, value]) => `${key}="${escape(value)}"`).join(' ')} />`).join('');
  symbols.push(`<symbol id="${name}" viewBox="0 0 24 24">${paths}</symbol>`);
}
const sprite = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" style="display:none"><defs>${symbols.join('')}</defs></svg>`;
await writeFile(resolve(root, 'htdocs/luci-static/cpeargon/icon/lucide.svg'), sprite);
console.log(`Built ${names.length} Lucide icons (${Buffer.byteLength(sprite)} bytes)`);
