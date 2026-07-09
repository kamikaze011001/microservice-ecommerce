import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { useToast } from '@/composables/useToast';
import { useToastStore } from '@/stores/toast';

describe('useToast', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('info() pushes a toast with tone=info and forwards title + body', () => {
    const toast = useToast();
    const store = useToastStore();
    toast.info('Heads up', 'details here');
    expect(store.items).toHaveLength(1);
    expect(store.items[0]).toMatchObject({
      tone: 'info',
      title: 'Heads up',
      body: 'details here',
    });
  });

  it('success() and error() map to their respective tones', () => {
    const toast = useToast();
    const store = useToastStore();
    toast.success('Saved');
    toast.error('Failed');
    expect(store.items.map((i) => i.tone)).toEqual(['success', 'error']);
    expect(store.items.map((i) => i.title)).toEqual(['Saved', 'Failed']);
  });

  it('forwards the duration option through to the pushed item', () => {
    const toast = useToast();
    const store = useToastStore();
    toast.info('Quick', undefined, { duration: 1000 });
    expect(store.items[0].duration).toBe(1000);
    // auto-dismiss fires at the forwarded duration, not the 4000 default
    vi.advanceTimersByTime(999);
    expect(store.items).toHaveLength(1);
    vi.advanceTimersByTime(1);
    expect(store.items).toHaveLength(0);
  });

  it('returns the new toast id so callers can dismiss it', () => {
    const toast = useToast();
    const store = useToastStore();
    const id = toast.success('Sticky');
    expect(id).toEqual(expect.any(String));
    toast.dismiss(id);
    expect(store.items).toHaveLength(0);
    // dismiss also cancels the auto-dismiss timer — no late mutation
    vi.advanceTimersByTime(10000);
    expect(store.items).toHaveLength(0);
  });
});
