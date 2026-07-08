import { existsSync } from 'node:fs';
import { basename, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

const stripTs = (p) => basename(p).replace(/\.ts$/, '');

/**
 * Pick the next untested composable/store.
 * @param {string[]} sources         source paths (excluding *.spec.ts)
 * @param {Set<string>} specBasenames basenames (no extension) that already have a spec
 * @param {string[]} priority        basenames in preferred order; others sort after, by path
 * @returns {string | null}  the next untested source path, or null when all are tested.
 */
export function pickNextCoverage(sources, specBasenames, priority) {
  const rank = (p) => {
    const i = priority.indexOf(stripTs(p));
    return i === -1 ? priority.length : i;
  };
  const untested = sources
    .filter((p) => !specBasenames.has(stripTs(p)))
    .sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0));
  return untested[0] ?? null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const srcRoot = fileURLToPath(new URL('../src', import.meta.url));
  const testsRoot = fileURLToPath(new URL('../tests/unit', import.meta.url));
  const sources = ['composables', 'stores']
    .map((d) => `${srcRoot}/${d}`)
    .filter(existsSync)
    .flatMap((d) => walk(d, ['.ts']))
    .filter((p) => !p.endsWith('.spec.ts'))
    .map((p) => relative(srcRoot, p));
  const specBasenames = new Set(
    walk(testsRoot, ['.spec.ts']).map((p) => basename(p).replace(/\.spec\.ts$/, '')),
  );
  const next = pickNextCoverage(sources, specBasenames, ['useToast', 'usePageMeta']);
  console.log(next ?? 'DONE');
}
