import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * Pick the next migration target from a consistency baseline map.
 * @param {Record<string, number>} baseline  file -> grandfathered raw-element count
 * @returns {{ file: string, count: number } | null}  smallest count > 0 (ties: lexicographic
 *   file path), or null when all entries are 0.
 */
export function pickNextMigration(baseline) {
  let best = null;
  for (const [file, count] of Object.entries(baseline)) {
    if (count <= 0) continue;
    if (best === null || count < best.count || (count === best.count && file < best.file)) {
      best = { file, count };
    }
  }
  return best;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const baseline = JSON.parse(
    readFileSync(fileURLToPath(new URL('./consistency-baseline.json', import.meta.url)), 'utf8'),
  );
  const next = pickNextMigration(baseline);
  console.log(next ? next.file : 'DONE');
}
