import { describe, expect, it, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/vue';
import BTextButton from '@/components/primitives/BTextButton.vue';

describe('BTextButton', () => {
  it('renders default slot inside a button', () => {
    render(BTextButton, { slots: { default: 'LOG OUT' } });
    const btn = screen.getByRole('button', { name: 'LOG OUT' });
    expect(btn).toBeInTheDocument();
    expect(btn).toHaveAttribute('type', 'button');
  });

  it('lets a consumer class coexist on the root button', () => {
    render(BTextButton, {
      attrs: { class: 'app-nav__menu-link' },
      slots: { default: 'LOG OUT' },
    });
    const btn = screen.getByRole('button', { name: 'LOG OUT' });
    // Primitive's own class plus the consumer's — both land on the root.
    expect(btn).toHaveClass('b-text-button');
    expect(btn).toHaveClass('app-nav__menu-link');
  });

  it('emits native click when pressed', async () => {
    const onClick = vi.fn();
    render(BTextButton, { attrs: { onClick }, slots: { default: 'LOG OUT' } });
    await fireEvent.click(screen.getByRole('button', { name: 'LOG OUT' }));
    expect(onClick).toHaveBeenCalledOnce();
  });

  it('is disabled when the disabled prop is set', () => {
    render(BTextButton, { props: { disabled: true }, slots: { default: 'LOG OUT' } });
    expect(screen.getByRole('button', { name: 'LOG OUT' })).toBeDisabled();
  });
});
