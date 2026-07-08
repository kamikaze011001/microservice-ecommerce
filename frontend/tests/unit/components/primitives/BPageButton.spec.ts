import { describe, expect, it, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/vue';
import BPageButton from '@/components/primitives/BPageButton.vue';

describe('BPageButton', () => {
  it('renders default slot inside a button', () => {
    render(BPageButton, { slots: { default: '3' } });
    const btn = screen.getByRole('button', { name: '3' });
    expect(btn).toBeInTheDocument();
    expect(btn).toHaveAttribute('type', 'button');
  });

  it('data-active is false by default and true when active', async () => {
    const { rerender, container } = render(BPageButton, {
      props: { active: false },
      slots: { default: '3' },
    });
    const btn = container.querySelector('.b-page-button') as HTMLElement;
    expect(btn.dataset.active).toBe('false');

    await rerender({ active: true });
    expect(btn.dataset.active).toBe('true');
  });

  it('emits native click when pressed', async () => {
    const onClick = vi.fn();
    render(BPageButton, {
      attrs: { onClick },
      slots: { default: '3' },
    });
    await fireEvent.click(screen.getByRole('button', { name: '3' }));
    expect(onClick).toHaveBeenCalledOnce();
  });
});
