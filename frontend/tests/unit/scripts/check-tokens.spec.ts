import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { findHardcodedHex } from '../../../scripts/check-tokens.mjs';

describe('findHardcodedHex', () => {
  let root: string;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'tok-'));
  });
  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it('flags a hard-coded hex in a .vue', () => {
    writeFileSync(join(root, 'A.vue'), '<style>.x{color:#ff4f1c}</style>');
    expect(findHardcodedHex(root)).toHaveLength(1);
  });

  it('flags a hard-coded hex in a .ts', () => {
    writeFileSync(join(root, 'a.ts'), 'export const c = "#1c1c1c";');
    expect(findHardcodedHex(root)).toHaveLength(1);
  });

  it('ignores var(--token) usage', () => {
    writeFileSync(join(root, 'A.vue'), '<style>.x{color:var(--spot)}</style>');
    expect(findHardcodedHex(root)).toHaveLength(0);
  });

  it('honours the ignore list', () => {
    writeFileSync(join(root, 'skip.ts'), 'const c = "#abcdef";');
    expect(findHardcodedHex(root, ['skip.ts'])).toHaveLength(0);
  });
});
