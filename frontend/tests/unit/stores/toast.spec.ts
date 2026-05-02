import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { useToastStore } from '@/stores/toast';

describe('toast store', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('push() adds an item with default tone=info, duration=4000, and auto-dismisses', () => {
    const store = useToastStore();
    const id = store.push({ title: 'Hello' });
    expect(store.items).toHaveLength(1);
    expect(store.items[0]).toMatchObject({ id, tone: 'info', title: 'Hello', duration: 4000 });
    vi.advanceTimersByTime(4000);
    expect(store.items).toHaveLength(0);
  });

  it('dismiss(id) removes the item and cancels the auto-dismiss timer', () => {
    const store = useToastStore();
    const id = store.push({ title: 'Bye', duration: 4000 });
    store.dismiss(id);
    expect(store.items).toHaveLength(0);
    vi.advanceTimersByTime(10000);
    expect(store.items).toHaveLength(0);
  });
});
