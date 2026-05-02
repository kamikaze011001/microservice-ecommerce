import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BToast from '@/components/primitives/BToast.vue';

describe('BToast', () => {
  it('renders title, body, and tone class', () => {
    const { container } = render(BToast, {
      props: { tone: 'success', title: 'Saved!', body: 'All good.' },
    });
    expect(screen.getByText('Saved!')).toBeInTheDocument();
    expect(screen.getByText('All good.')).toBeInTheDocument();
    expect(container.querySelector('.b-toast.tone-success')).not.toBeNull();
  });

  it('clicking the close button emits dismiss', async () => {
    const onDismiss = vi.fn();
    render(BToast, {
      props: { title: 'Hi', onDismiss },
    });
    await userEvent.click(screen.getByRole('button', { name: /close/i }));
    expect(onDismiss).toHaveBeenCalledTimes(1);
  });
});
