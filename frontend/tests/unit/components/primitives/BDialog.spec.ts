import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BDialog from '@/components/primitives/BDialog.vue';

describe('BDialog', () => {
  it('open=true renders title in a portal; close button emits update:open=false', async () => {
    const onUpdate = vi.fn();
    render(BDialog, {
      props: { open: true, title: 'Confirm', 'onUpdate:open': onUpdate },
      slots: { default: '<p>body</p>' },
    });
    // Portal content is async (useMounted) — use findBy* to wait for it
    expect(await screen.findByText('Confirm')).toBeInTheDocument();
    expect(await screen.findByText('body')).toBeInTheDocument();
    // Fallback: click close button (Esc via happy-dom window listeners is unreliable)
    await userEvent.click(screen.getByRole('button', { name: /close/i }));
    expect(onUpdate).toHaveBeenCalledWith(false);
  });

  it('renders the footer slot when provided', async () => {
    render(BDialog, {
      props: { open: true, title: 'Confirm' },
      slots: {
        default: '<p>are you sure?</p>',
        footer: '<button>OK</button>',
      },
    });
    // Portal content is async — wait for it
    expect(await screen.findByRole('button', { name: 'OK' })).toBeInTheDocument();
  });
});
