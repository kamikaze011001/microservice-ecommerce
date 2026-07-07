import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { countRawElements, findNewRawElements } from '../../../scripts/check-primitive-reuse.mjs';

describe('countRawElements', () => {
  let root: string;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'prim-'));
  });
  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it('counts raw button/input/select in a .vue', () => {
    writeFileSync(join(root, 'A.vue'), '<template><button/><input><select></select></template>');
    expect(countRawElements(root, 'primitives')).toEqual({ 'A.vue': 3 });
  });

  it('skips files under the primitives dir', () => {
    mkdirSync(join(root, 'primitives'));
    writeFileSync(join(root, 'primitives', 'BButton.vue'), '<template><button/></template>');
    expect(countRawElements(root, 'primitives')).toEqual({});
  });
});

describe('findNewRawElements', () => {
  it('flags a file whose count exceeds its baseline', () => {
    expect(findNewRawElements({ 'A.vue': 3 }, { 'A.vue': 2 })).toEqual([
      { file: 'A.vue', count: 3, allowed: 2 },
    ]);
  });

  it('passes a file at or below its baseline', () => {
    expect(findNewRawElements({ 'A.vue': 2 }, { 'A.vue': 2 })).toEqual([]);
  });

  it('flags a brand-new file not in the baseline', () => {
    expect(findNewRawElements({ 'New.vue': 1 }, {})).toEqual([
      { file: 'New.vue', count: 1, allowed: 0 },
    ]);
  });
});
