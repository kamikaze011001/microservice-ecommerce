import { existsSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

/** Paths (relative to componentsDir) of *.vue with no sibling *.stories.ts, minus the allowlist. */
export function findMissingStories(componentsDir, allowlist = []) {
  const allow = new Set(allowlist);
  return walk(componentsDir, ['.vue'])
    .filter((vue) => !existsSync(vue.replace(/\.vue$/, '.stories.ts')))
    .map((vue) => relative(componentsDir, vue))
    .filter((rel) => !allow.has(rel));
}

// Components that legitimately have no story (none today; extend as needed).
const ALLOWLIST = [];

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const dir = fileURLToPath(new URL('../src/components', import.meta.url));
  const missing = findMissingStories(dir, ALLOWLIST);
  if (missing.length) {
    console.error('✗ components missing a *.stories.ts:');
    for (const m of missing) console.error('  - ' + m);
    process.exit(1);
  }
  console.log('✓ story-coverage: every component has a story');
}
