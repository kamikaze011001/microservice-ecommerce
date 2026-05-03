import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import CheckoutPage from '@/pages/CheckoutPage.vue';

const useCartQuery = vi.fn();
const createOrder = vi.fn();
const createPayment = vi.fn();
const cancelOrder = vi.fn();

vi.mock('@/api/queries/cart', () => ({
  useCartQuery: (...a: unknown[]) => useCartQuery(...a),
}));
vi.mock('@/api/queries/orders', () => ({
  useCreateOrderMutation: () => ({ mutateAsync: createOrder, isPending: { value: false } }),
  useCancelOrderMutation: () => ({ mutateAsync: cancelOrder, isPending: { value: false } }),
}));
vi.mock('@/api/queries/payments', () => ({
  useCreatePaymentMutation: () => ({ mutateAsync: createPayment, isPending: { value: false } }),
}));

const originalLocation = window.location;
beforeEach(async () => {
  setActivePinia(createPinia());
  useCartQuery.mockReset();
  createOrder.mockReset();
  createPayment.mockReset();
  cancelOrder.mockReset();
  window.localStorage.clear();
  // jsdom location stub
  Object.defineProperty(window, 'location', {
    writable: true,
    value: { ...originalLocation, href: '' },
  });
  useCartQuery.mockReturnValue({
    data: {
      value: {
        shopping_cart_id: 'c1',
        user_id: 'u1',
        items: [
          {
            shopping_cart_item_id: 'i1',
            product_id: 'p1',
            name: 'Tee',
            image_url: '',
            unit_price: 25,
            quantity: 2,
            available_stock: 5,
          },
        ],
      },
    },
    isLoading: { value: false },
    isError: { value: false },
    error: { value: null },
  });
  await router.push('/checkout');
  await router.isReady();
});

afterEach(() => {
  Object.defineProperty(window, 'location', { writable: true, value: originalLocation });
});

function mount() {
  return render(CheckoutPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

async function fillValidForm() {
  await userEvent.type(screen.getByLabelText(/STREET/i), '123 Main St');
  await userEvent.type(screen.getByLabelText(/CITY/i), 'Brooklyn');
  await userEvent.type(screen.getByLabelText(/STATE/i), 'NY');
  await userEvent.type(screen.getByLabelText(/POSTCODE/i), '11201');
  await userEvent.type(screen.getByLabelText(/PHONE/i), '+15551234567');
}

describe('CheckoutPage', () => {
  it('blocks submit when address fields are empty', async () => {
    mount();
    await userEvent.click(screen.getByRole('button', { name: /CONTINUE TO PAYMENT/i }));
    expect(createOrder).not.toHaveBeenCalled();
    await waitFor(() => expect(screen.getByText(/Street is required/i)).toBeInTheDocument());
  });

  it('runs sequential mutations and redirects to approvalUrl', async () => {
    createOrder.mockResolvedValueOnce({ orderId: 'o1' });
    createPayment.mockResolvedValueOnce({ approvalUrl: 'https://paypal/x' });
    mount();
    await fillValidForm();
    await userEvent.click(screen.getByRole('button', { name: /CONTINUE TO PAYMENT/i }));
    await waitFor(() =>
      expect(createOrder).toHaveBeenCalledWith({
        address: '123 Main St, Brooklyn, NY 11201, US',
        phone_number: '+15551234567',
        items: [{ product_id: 'p1', quantity: 2 }],
      }),
    );
    await waitFor(() => expect(createPayment).toHaveBeenCalledWith({ orderId: 'o1' }));
    await waitFor(() => expect(window.location.href).toBe('https://paypal/x'));
    expect(localStorage.getItem('aibles.checkout.pendingOrderId')).toBe('o1');
  });

  it('shows pending-order banner when localStorage has a pendingOrderId on mount', async () => {
    localStorage.setItem('aibles.checkout.pendingOrderId', 'o42');
    mount();
    await waitFor(() =>
      expect(screen.getByText(/ORDER #o42 IS PENDING PAYMENT/i)).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: /RESUME PAYMENT/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /CANCEL ORDER/i })).toBeInTheDocument();
  });
});
