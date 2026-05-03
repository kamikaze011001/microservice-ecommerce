import { describe, it, expect, vi } from 'vitest';
import { nextTick } from 'vue';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import AddressForm from '@/components/domain/AddressForm.vue';

// vee-validate flushes validation asynchronously; wait for Vue + microtasks
const flush = () => nextTick().then(() => new Promise((r) => setTimeout(r, 50)));

describe('AddressForm', () => {
  it('blocks submit when fields are empty and surfaces errors', async () => {
    const onSubmit = vi.fn();
    render(AddressForm, { props: { initial: undefined, onSubmit } });
    const submit = screen.getByRole('button', { name: /CONTINUE TO PAYMENT/i });
    await userEvent.click(submit);
    await flush();
    expect(onSubmit).not.toHaveBeenCalled();
    expect(screen.getByText(/Street is required/i)).toBeInTheDocument();
  });

  it('emits submit with structured + concatenated address on valid input', async () => {
    const onSubmit = vi.fn();
    render(AddressForm, { props: { initial: undefined, onSubmit } });
    await userEvent.type(screen.getByLabelText(/STREET/i), '123 Main St');
    await userEvent.type(screen.getByLabelText(/CITY/i), 'Brooklyn');
    await userEvent.type(screen.getByLabelText(/STATE/i), 'NY');
    await userEvent.type(screen.getByLabelText(/POSTCODE/i), '11201');
    await userEvent.clear(screen.getByLabelText(/COUNTRY/i));
    await userEvent.type(screen.getByLabelText(/COUNTRY/i), 'US');
    await userEvent.type(screen.getByLabelText(/PHONE/i), '+15551234567');
    await userEvent.click(screen.getByRole('button', { name: /CONTINUE TO PAYMENT/i }));
    await flush();

    expect(onSubmit).toHaveBeenCalledTimes(1);
    const arg = onSubmit.mock.calls[0][0];
    expect(arg).toMatchObject({
      structured: {
        street: '123 Main St',
        city: 'Brooklyn',
        state: 'NY',
        postcode: '11201',
        country: 'US',
        phone: '+15551234567',
      },
      address: '123 Main St, Brooklyn, NY 11201, US',
      phone: '+15551234567',
    });
  });
});
