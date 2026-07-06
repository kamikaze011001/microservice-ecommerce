import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { findMissingStories } from '../../../scripts/check-story-coverage.mjs';

describe('findMissingStories', () => {
  let root: string;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'cov-'));
  });
  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it('flags a component with no sibling story', () => {
    writeFileSync(join(root, 'Foo.vue'), '<template/>');
    expect(findMissingStories(root)).toEqual(['Foo.vue']);
  });

  it('passes a component that has a sibling story', () => {
    writeFileSync(join(root, 'Foo.vue'), '<template/>');
    writeFileSync(join(root, 'Foo.stories.ts'), '');
    expect(findMissingStories(root)).toEqual([]);
  });

  it('respects the allowlist', () => {
    writeFileSync(join(root, 'Foo.vue'), '<template/>');
    expect(findMissingStories(root, ['Foo.vue'])).toEqual([]);
  });
});
