import { describe, it, expect } from 'vitest';
// @ts-expect-error — .mjs script has no type declarations; resolved at runtime by Vitest
import { pickNextA11y } from '../../../scripts/next-a11y-target.mjs';

const priority = ['LoginPage', 'RegisterPage', 'AppNav'];

describe('pickNextA11y', () => {
  it('returns the highest-priority unguarded target', () => {
    const sources = ['pages/RegisterPage.vue', 'pages/LoginPage.vue'];
    expect(pickNextA11y(sources, new Set(), priority)).toBe('pages/LoginPage.vue');
  });

  it('skips targets that already have an a11y guard', () => {
    const sources = ['pages/LoginPage.vue', 'pages/RegisterPage.vue'];
    expect(pickNextA11y(sources, new Set(['LoginPage']), priority)).toBe('pages/RegisterPage.vue');
  });

  it('orders non-priority targets after priority ones, alphabetically by path', () => {
    const sources = ['pages/CartPage.vue', 'pages/ActivatePage.vue', 'pages/LoginPage.vue'];
    expect(pickNextA11y(sources, new Set(), priority)).toBe('pages/LoginPage.vue');
    expect(pickNextA11y(sources, new Set(['LoginPage']), priority)).toBe('pages/ActivatePage.vue');
  });

  it('returns null when every target is guarded (stop condition)', () => {
    const sources = ['pages/LoginPage.vue', 'components/layout/AppNav.vue'];
    expect(pickNextA11y(sources, new Set(['LoginPage', 'AppNav']), priority)).toBeNull();
  });
});
