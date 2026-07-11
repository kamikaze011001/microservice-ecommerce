import { readFileSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

// A page is "bad" if it has an empty-binding catch (`catch {`), which always discards
// the caught error. That is the marker; the loop's human review catches subtler cases.
export function hasDiscardedCatch(src) {
  return /catch\s*\{/.test(src);
}

export function pickNextPage(pages) {
  const bad = pages.filter((p) => p.bad).map((p) => p.f).sort();
  return bad[0] ?? null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const srcRoot = fileURLToPath(new URL('../src', import.meta.url));
  const pages = walk(`${srcRoot}/pages`, ['.vue']).map((p) => ({
    f: relative(`${srcRoot}/pages`, p),
    bad: /catch\s*\{/.test(readFileSync(p, 'utf8')),
  }));
  console.log(pickNextPage(pages) ?? 'DONE');
}
