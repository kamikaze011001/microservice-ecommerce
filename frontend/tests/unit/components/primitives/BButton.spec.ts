import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BButton from '@/components/primitives/BButton.vue';

describe('BButton', () => {
  it('renders default slot text and emits click once', async () => {
    const onClick = vi.fn();
    render(BButton, { slots: { default: 'Press me' }, attrs: { onClick } });
    const btn = screen.getByRole('button', { name: /press me/i });
    await userEvent.click(btn);
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it('disabled blocks click; loading hides slot and shows spinner', async () => {
    const onClick = vi.fn();
    const { rerender } = render(BButton, {
      props: { disabled: true },
      slots: { default: 'Nope' },
      attrs: { onClick },
    });
    await userEvent.click(screen.getByRole('button'));
    expect(onClick).not.toHaveBeenCalled();

    await rerender({ disabled: false, loading: true });
    expect(screen.getByRole('button')).toHaveAttribute('aria-busy', 'true');
    expect(screen.getByTestId('b-button-spinner')).toBeInTheDocument();
  });
});
