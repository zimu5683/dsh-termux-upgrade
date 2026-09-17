/**
 * Pin every top-level package of a built `node_modules` tree into the manifest,
 * the way the dsh-termux repack does: `dependencies` holds exact versions and
 * `bundledDependencies` repeats the same names, so `npm pack` vendors the whole
 * resolved tree and `npm install -g <tarball>` needs no registry access and runs
 * no resolution or native rebuild on the device.
 *
 * Usage: node pin-manifest.mjs <package-dir>
 */
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2];
if (dir === undefined) throw new Error('usage: node pin-manifest.mjs <package-dir>');

const modules = join(dir, 'node_modules');
const names = [];
for (const entry of readdirSync(modules)) {
  if (entry.startsWith('.')) continue;
  const full = join(modules, entry);
  if (!statSync(full).isDirectory()) continue;
  if (entry.startsWith('@')) {
    for (const scoped of readdirSync(full)) {
      if (scoped.startsWith('.')) continue;
      if (statSync(join(full, scoped)).isDirectory()) names.push(`${entry}/${scoped}`);
    }
  } else {
    names.push(entry);
  }
}

const versions = new Map();
for (const name of names) {
  const manifest = JSON.parse(readFileSync(join(modules, name, 'package.json'), 'utf8'));
  if (manifest.version === undefined) throw new Error(`${name}: no version`);
  versions.set(name, manifest.version);
}

const manifestPath = join(dir, 'package.json');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const pinned = {};
for (const name of [...versions.keys()].sort()) pinned[name] = versions.get(name);
manifest.dependencies = pinned;
manifest.bundledDependencies = Object.keys(pinned);
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');

console.log(`${manifest.name}@${manifest.version}: pinned ${Object.keys(pinned).length} packages`);
