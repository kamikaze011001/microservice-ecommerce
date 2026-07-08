import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BFileButton from '@/components/primitives/BFileButton.vue';

describe('BFileButton', () => {
  it('renders the slot label in a button plus a hidden file input', () => {
    const { container } = render(BFileButton, {
      props: { accept: 'image/png', inputAriaLabel: 'Upload avatar' },
      slots: { default: 'CHANGE PHOTO' },
    });
    expect(screen.getByRole('button', { name: 'CHANGE PHOTO' })).toBeInTheDocument();
    const input = container.querySelector('input[type="file"]') as HTMLInputElement;
    expect(input).not.toBeNull();
    expect(input).toHaveAttribute('accept', 'image/png');
    expect(input).toHaveAttribute('aria-label', 'Upload avatar');
  });

  it('clicking the button opens the file picker', async () => {
    const { container } = render(BFileButton, { slots: { default: 'PICK' } });
    const input = container.querySelector('input[type="file"]') as HTMLInputElement;
    const clickSpy = vi.spyOn(input, 'click').mockImplementation(() => {});
    await userEvent.click(screen.getByRole('button', { name: 'PICK' }));
    expect(clickSpy).toHaveBeenCalledOnce();
  });

  it('emits select with the chosen File and resets the input', async () => {
    const { container, emitted } = render(BFileButton, { slots: { default: 'PICK' } });
    const input = container.querySelector('input[type="file"]') as HTMLInputElement;
    const file = new File(['x'], 'a.png', { type: 'image/png' });
    await userEvent.upload(input, file);

    const events = emitted('select');
    expect(events).toHaveLength(1);
    const [selected] = events[0] as [File];
    expect(selected.name).toBe('a.png');
    // Reset so re-picking the SAME file still fires.
    expect(input.value).toBe('');
  });

  it('forwards loading to the inner button (disabled + aria-busy)', () => {
    render(BFileButton, { props: { loading: true }, slots: { default: 'PICK' } });
    const btn = screen.getByRole('button', { name: 'PICK' });
    expect(btn).toBeDisabled();
    expect(btn).toHaveAttribute('aria-busy', 'true');
  });
});
