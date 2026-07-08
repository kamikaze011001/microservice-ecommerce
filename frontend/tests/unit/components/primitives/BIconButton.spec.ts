import { describe, expect, it, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/vue';
import BIconButton from '@/components/primitives/BIconButton.vue';

describe('BIconButton', () => {
  it('renders slot content inside a bare button with a fallen-through aria-label', () => {
    render(BIconButton, {
      attrs: { 'aria-label': 'Open menu' },
      slots: { default: '<svg data-testid="icon" />' },
    });
    const btn = screen.getByRole('button', { name: 'Open menu' });
    expect(btn).toBeInTheDocument();
    expect(btn).toHaveAttribute('type', 'button');
    expect(btn.querySelector('[data-testid="icon"]')).not.toBeNull();
  });

  it('emits native click when pressed', async () => {
    const onClick = vi.fn();
    render(BIconButton, {
      attrs: { 'aria-label': 'Toggle', onClick },
      slots: { default: 'x' },
    });
    await fireEvent.click(screen.getByRole('button', { name: 'Toggle' }));
    expect(onClick).toHaveBeenCalledOnce();
  });

  it('is disabled when the disabled prop is set', () => {
    render(BIconButton, {
      props: { disabled: true },
      attrs: { 'aria-label': 'Toggle' },
      slots: { default: 'x' },
    });
    expect(screen.getByRole('button', { name: 'Toggle' })).toBeDisabled();
  });
});
