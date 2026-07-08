import { describe, it, expect } from 'vitest';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { pickNextCoverage } from '../../../scripts/next-coverage-target.mjs';

const priority = ['useToast', 'usePageMeta'];

describe('pickNextCoverage', () => {
  it('returns the highest-priority untested unit', () => {
    const sources = ['composables/usePageMeta.ts', 'composables/useToast.ts'];
    expect(pickNextCoverage(sources, new Set(), priority)).toBe('composables/useToast.ts');
  });

  it('skips units that already have a spec', () => {
    const sources = ['composables/useToast.ts', 'composables/usePageMeta.ts'];
    expect(pickNextCoverage(sources, new Set(['useToast']), priority)).toBe(
      'composables/usePageMeta.ts',
    );
  });

  it('orders non-priority units after priority ones, alphabetically by path', () => {
    const sources = ['stores/zeta.ts', 'stores/alpha.ts', 'composables/useToast.ts'];
    expect(pickNextCoverage(sources, new Set(), priority)).toBe('composables/useToast.ts');
    expect(pickNextCoverage(sources, new Set(['useToast']), priority)).toBe('stores/alpha.ts');
  });

  it('returns null when every source has a spec (stop condition)', () => {
    const sources = ['composables/useToast.ts', 'stores/auth.ts'];
    expect(pickNextCoverage(sources, new Set(['useToast', 'auth']), priority)).toBeNull();
  });
});
