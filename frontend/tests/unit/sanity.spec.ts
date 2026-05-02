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

  it('extends expect with jest-dom matchers', () => {
    const div = document.createElement('div');
    div.textContent = 'paper';
    document.body.appendChild(div);
    expect(div).toBeInTheDocument();
    expect(div).toHaveTextContent('paper');
    document.body.removeChild(div);
  });
});
