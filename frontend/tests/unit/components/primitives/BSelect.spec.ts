import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import BSelect from '@/components/primitives/BSelect.vue';

const options = [
  { value: 'us', label: 'United States' },
  { value: 'vn', label: 'Vietnam' },
  { value: 'jp', label: 'Japan' },
];

describe('BSelect', () => {
  it('clicking trigger opens listbox; clicking option emits update:modelValue', async () => {
    const onUpdate = vi.fn();
    render(BSelect, {
      props: {
        modelValue: '',
        options,
        placeholder: 'Choose…',
        'onUpdate:modelValue': onUpdate,
      },
    });
    await userEvent.click(screen.getByRole('combobox'));
    await userEvent.click(await screen.findByRole('option', { name: 'Vietnam' }));
    expect(onUpdate).toHaveBeenCalledWith('vn');
  });

  // NOTE: Keyboard navigation (ArrowDown/Enter) inside the Select portal cannot be
  // tested under happy-dom. Reka UI's SelectItem.handleAndDispatchCustomEvent calls
  // target.addEventListener() on the keyboard event's target, which is null when the
  // event is dispatched into a portal in happy-dom (portal DOM is detached from the
  // test container's document). This is deferred to Task 19 live-browser DoD verification.
  it('renders all options in the open listbox', async () => {
    render(BSelect, {
      props: { modelValue: '', options, placeholder: 'Pick one' },
    });
    await userEvent.click(screen.getByRole('combobox'));
    expect(await screen.findByRole('option', { name: 'United States' })).toBeInTheDocument();
    expect(await screen.findByRole('option', { name: 'Vietnam' })).toBeInTheDocument();
    expect(await screen.findByRole('option', { name: 'Japan' })).toBeInTheDocument();
  });
});
