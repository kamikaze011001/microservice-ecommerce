import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import BTag from '@/components/primitives/BTag.vue';

describe('BTag', () => {
  it('renders default slot', () => {
    render(BTag, { slots: { default: 'NEW' } });
    expect(screen.getByText('NEW')).toBeInTheDocument();
  });

  it('rotate prop sets inline rotation transform', () => {
    const { container } = render(BTag, {
      props: { rotate: 2 },
      slots: { default: 'tag' },
    });
    const el = container.querySelector('.b-tag') as HTMLElement;
    expect(el.style.transform).toBe('rotate(2deg)');
  });
});
