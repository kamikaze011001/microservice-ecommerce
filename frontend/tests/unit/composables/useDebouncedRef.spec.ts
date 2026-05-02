import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { useDebouncedRef } from '@/composables/useDebouncedRef';

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

describe('useDebouncedRef', () => {
  it('coalesces rapid writes into a single trailing value', () => {
    const r = useDebouncedRef('', 400);
    r.value = 'a';
    r.value = 'ab';
    r.value = 'abc';
    expect(r.value).toBe('');
    vi.advanceTimersByTime(399);
    expect(r.value).toBe('');
    vi.advanceTimersByTime(1);
    expect(r.value).toBe('abc');
  });

  it('subsequent writes after settle restart the debounce window', () => {
    const r = useDebouncedRef(0, 200);
    r.value = 1;
    vi.advanceTimersByTime(200);
    expect(r.value).toBe(1);
    r.value = 2;
    expect(r.value).toBe(1);
    vi.advanceTimersByTime(200);
    expect(r.value).toBe(2);
  });
});
