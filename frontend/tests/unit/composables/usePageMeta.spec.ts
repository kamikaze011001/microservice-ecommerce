import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { render } from '@testing-library/vue';
import { h, nextTick, ref } from 'vue';
import { usePageMeta } from '@/composables/usePageMeta';

const DEFAULT_DESCRIPTION = 'Issue Nº01 — a small editorial storefront.';

// usePageMeta calls onUnmounted + watchEffect, so it needs a component context.
// Render a throwaway component whose setup wires it up; render() returns unmount.
function mountMeta(opts: Parameters<typeof usePageMeta>[0]) {
  return render({
    setup() {
      usePageMeta(opts);
      return () => h('div');
    },
  });
}

function descContent(): string | undefined {
  return (document.querySelector('meta[name="description"]') as HTMLMetaElement | null)?.content;
}

describe('usePageMeta', () => {
  beforeEach(() => {
    document.title = '';
    document.querySelectorAll('meta[name="description"]').forEach((m) => m.remove());
  });

  afterEach(() => {
    document.querySelectorAll('meta[name="description"]').forEach((m) => m.remove());
  });

  it('sets the document title and creates a description meta with the default copy', () => {
    mountMeta({ title: 'Product Page' });
    expect(document.title).toBe('Product Page');
    // no meta existed → the composable creates one
    expect(document.querySelectorAll('meta[name="description"]')).toHaveLength(1);
    expect(descContent()).toBe(DEFAULT_DESCRIPTION);
  });

  it('uses an explicit description when provided', () => {
    mountMeta({ title: 'About', description: 'Hand-set in Paris.' });
    expect(descContent()).toBe('Hand-set in Paris.');
  });

  it('reactively tracks a ref title', async () => {
    const title = ref('First');
    mountMeta({ title });
    expect(document.title).toBe('First');
    title.value = 'Second';
    await nextTick();
    expect(document.title).toBe('Second');
  });

  it('restores the prior title and description on unmount', () => {
    document.title = 'Original Title';
    const meta = document.createElement('meta');
    meta.name = 'description';
    meta.content = 'Base description';
    document.head.appendChild(meta);

    const { unmount } = mountMeta({ title: 'Temp Title', description: 'Temp description' });
    // updates the existing meta in place rather than creating a duplicate
    expect(document.title).toBe('Temp Title');
    expect(descContent()).toBe('Temp description');
    expect(document.querySelectorAll('meta[name="description"]')).toHaveLength(1);

    unmount();
    expect(document.title).toBe('Original Title');
    expect(descContent()).toBe('Base description');
  });
});
