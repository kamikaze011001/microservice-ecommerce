import { readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

/** Recursively collect absolute file paths under `dir` whose name ends with one of `exts`. */
export function walk(dir, exts) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      out.push(...walk(full, exts));
    } else if (exts.some((e) => name.endsWith(e))) {
      out.push(full);
    }
  }
  return out;
}
