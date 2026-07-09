// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { axe } from 'vitest-axe';

describe('vitest-axe toolchain (jsdom)', () => {
  it('reports NO violations for accessible markup', async () => {
    const el = document.createElement('div');
    el.innerHTML = '<button type="button">Save</button>';
    document.body.appendChild(el);
    const results = await axe(el);
    expect(results).toHaveNoViolations();
  });

  it('reports a violation for an input with no accessible name', async () => {
    const el = document.createElement('div');
    el.innerHTML = '<input type="text" />';
    document.body.appendChild(el);
    const results = await axe(el);
    // Proves axe's structural rules actually execute in this (jsdom) environment: a bare input
    // with no accessible name must be flagged. NB: this asserts axe runs here — it does not,
    // on its own, prove the docblock is present (axe also runs under the pinned happy-dom v15).
    expect(results.violations.length).toBeGreaterThan(0);
  });
});
