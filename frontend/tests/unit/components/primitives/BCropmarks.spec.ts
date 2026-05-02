import { describe, expect, it } from 'vitest';
import { render } from '@testing-library/vue';
import BCropmarks from '@/components/primitives/BCropmarks.vue';

describe('BCropmarks', () => {
  it('renders 4 corner-mark elements', () => {
    const { container } = render(BCropmarks);
    expect(container.querySelectorAll('.b-cropmarks__mark')).toHaveLength(4);
  });

  it('inset prop is passed as a CSS custom property', () => {
    const { container } = render(BCropmarks, { props: { inset: '2rem' } });
    const root = container.querySelector('.b-cropmarks') as HTMLElement;
    expect(root.style.getPropertyValue('--b-cropmarks-inset')).toBe('2rem');
  });
});
