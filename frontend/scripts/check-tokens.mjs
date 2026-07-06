import { readFileSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { walk } from './lib/walk.mjs';

// 3/4/6/8-digit hex colours only (avoids matching 5/7-digit noise).
const HEX = /#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b/;

/** Hard-coded hex colours in .vue/.ts under rootDir. `ignore` = path substrings to skip. */
export function findHardcodedHex(rootDir, ignore = []) {
  const hits = [];
  for (const file of walk(rootDir, ['.vue', '.ts'])) {
    if (ignore.some((ig) => file.includes(ig))) continue;
    readFileSync(file, 'utf8').split('\n').forEach((text, i) => {
      if (HEX.test(text)) hits.push({ file: relative(rootDir, file), line: i + 1, text: text.trim() });
    });
  }
  return hits;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = fileURLToPath(new URL('../src', import.meta.url));
  const hits = findHardcodedHex(root);
  if (hits.length) {
    console.error('✗ hard-coded hex colours found (use var(--token) from tokens.css):');
    for (const h of hits) console.error(`  - ${h.file}:${h.line}  ${h.text}`);
    process.exit(1);
  }
  console.log('✓ tokens: no hard-coded hex colours');
}
