import { readFileSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

const RAW = /<(?:button|input|select)[\s>/]/g;

/** Per-file count (relative to rootDir) of raw restricted elements, skipping files under primitivesDir. */
export function countRawElements(rootDir, primitivesDir) {
  const counts = {};
  for (const file of walk(rootDir, ['.vue'])) {
    const rel = relative(rootDir, file);
    // Path-segment match, not substring: skip files *under* primitivesDir only,
    // so a sibling like `components/primitives-legacy/` is NOT silently excluded.
    if (rel === primitivesDir || rel.startsWith(primitivesDir + '/')) continue;
    const matches = readFileSync(file, 'utf8').match(RAW);
    if (matches) counts[rel] = matches.length;
  }
  return counts;
}

/** Files whose current count exceeds the grandfathered baseline (new drift). */
export function findNewRawElements(counts, baseline) {
  const violations = [];
  for (const [file, count] of Object.entries(counts)) {
    const allowed = baseline[file] ?? 0;
    if (count > allowed) violations.push({ file, count, allowed });
  }
  return violations;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const src = fileURLToPath(new URL('../src', import.meta.url));
  const baseline = JSON.parse(
    readFileSync(fileURLToPath(new URL('./consistency-baseline.json', import.meta.url)), 'utf8'),
  );
  const violations = findNewRawElements(countRawElements(src, 'components/primitives'), baseline);
  if (violations.length) {
    console.error('✗ new raw <button>/<input>/<select> outside primitives (reuse B* or update the baseline):');
    for (const v of violations) console.error(`  - ${v.file}: ${v.count} (baseline ${v.allowed})`);
    process.exit(1);
  }
  console.log('✓ primitive-reuse: no new raw elements beyond the baseline');
}
