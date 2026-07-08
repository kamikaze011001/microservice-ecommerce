import { describe, it, expect } from 'vitest';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { pickNextMigration } from '../../../scripts/next-migration-target.mjs';

describe('pickNextMigration', () => {
  it('returns the entry with the lowest count > 0', () => {
    expect(pickNextMigration({ 'a.vue': 3, 'b.vue': 1, 'c.vue': 2 })).toEqual({
      file: 'b.vue',
      count: 1,
    });
  });

  it('breaks ties lexicographically by file path', () => {
    expect(pickNextMigration({ 'z.vue': 2, 'a.vue': 2 })).toEqual({ file: 'a.vue', count: 2 });
  });

  it('skips entries already at 0', () => {
    expect(pickNextMigration({ 'done.vue': 0, 'todo.vue': 5 })).toEqual({
      file: 'todo.vue',
      count: 5,
    });
  });

  it('returns null when every entry is 0 (stop condition)', () => {
    expect(pickNextMigration({ 'a.vue': 0, 'b.vue': 0 })).toBeNull();
  });

  it('returns null for an empty baseline', () => {
    expect(pickNextMigration({})).toBeNull();
  });
});
