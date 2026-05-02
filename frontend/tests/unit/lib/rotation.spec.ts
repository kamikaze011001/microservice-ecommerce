import { describe, expect, it } from 'vitest';
import { hashRotate } from '@/lib/rotation';

describe('hashRotate', () => {
  it('is deterministic for the same seed', () => {
    expect(hashRotate('abc')).toBe(hashRotate('abc'));
  });

  it('produces values within ±maxDegrees', () => {
    for (const seed of ['a', 'product-1', 'order-99', '🌶']) {
      const v = hashRotate(seed, 0.5);
      expect(v).toBeGreaterThanOrEqual(-0.5);
      expect(v).toBeLessThanOrEqual(0.5);
    }
  });

  it('respects custom max', () => {
    expect(Math.abs(hashRotate('seed', 4))).toBeLessThanOrEqual(4);
  });

  it('produces different values for different seeds', () => {
    expect(hashRotate('a')).not.toBe(hashRotate('b'));
  });
});
