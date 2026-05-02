import { describe, expect, it } from 'vitest';

describe('sanity', () => {
  it('runs vitest', () => {
    expect(1 + 1).toBe(2);
  });

  it('has happy-dom available', () => {
    const div = document.createElement('div');
    div.textContent = 'paper';
    expect(div.textContent).toBe('paper');
  });
});
