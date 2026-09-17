import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

function topLevel(modules) {
  const out = [];
  for (const e of readdirSync(modules)) {
    if (e.startsWith('.')) continue;
    const full = join(modules, e);
    if (!statSync(full).isDirectory()) continue;
    if (e.startsWith('@')) {
      for (const s of readdirSync(full)) {
        if (s.startsWith('.')) continue;
        if (statSync(join(full, s)).isDirectory()) out.push(`${e}/${s}`);
      }
    } else out.push(e);
  }
  return out.sort();
}

const staging = topLevel(process.argv[2]);
const lines = readFileSync(process.argv[3], 'utf8').split('\n');
const inTgz = new Set();
for (const line of lines) {
  const m = /^package\/node_modules\/((?:@[^/]+\/)?[^/]+)\//.exec(line);
  if (m) inTgz.add(m[1]);
}
const missing = staging.filter((n) => !inTgz.has(n));
console.log('staging packages:', staging.length);
console.log('tarball packages:', inTgz.size);
console.log('MISSING from tarball:', missing.length);
for (const n of missing) console.log('  -', n);
