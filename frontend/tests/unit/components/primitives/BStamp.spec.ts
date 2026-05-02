import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import BStamp from '@/components/primitives/BStamp.vue';

describe('BStamp', () => {
  it('renders default slot label', () => {
    render(BStamp, { slots: { default: 'PAID' } });
    expect(screen.getByText('PAID')).toBeInTheDocument();
  });

  it('tone="ink" applies tone-ink class', () => {
    const { container } = render(BStamp, {
      props: { tone: 'ink' },
      slots: { default: 'CANCELED' },
    });
    expect(container.querySelector('.b-stamp.tone-ink')).not.toBeNull();
  });
});
