import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BCard from '@/components/primitives/BCard.vue';

describe('BCard', () => {
  it('renders default slot inside the card element', () => {
    render(BCard, { slots: { default: '<p>body content</p>' } });
    expect(screen.getByText('body content')).toBeInTheDocument();
  });

  it('hoverMisregister=true toggles is-misregister class on hover', async () => {
    const { container } = render(BCard, {
      props: { hoverMisregister: true },
      slots: { default: 'card' },
    });
    const card = container.querySelector('.b-card')!;
    expect(card.className).not.toContain('is-misregister');
    await userEvent.hover(card);
    expect(card.className).toContain('is-misregister');
  });
});
