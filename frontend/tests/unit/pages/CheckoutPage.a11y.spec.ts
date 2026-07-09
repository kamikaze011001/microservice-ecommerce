// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import CheckoutPage from '@/pages/CheckoutPage.vue';

const useCartQuery = vi.fn();

vi.mock('@/api/queries/cart', () => ({
  useCartQuery: (...a: unknown[]) => useCartQuery(...a),
}));
vi.mock('@/api/queries/orders', () => ({
  useCreateOrderMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
  useCancelOrderMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
}));
vi.mock('@/api/queries/payments', () => ({
  useCreatePaymentMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
}));

beforeEach(async () => {
  setActivePinia(createPinia());
  window.localStorage.clear();
  // A non-empty cart is required: an empty cart triggers watchEffect → router
  // replace('/cart'), which would unmount the page before axe can inspect it.
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

function mount() {
  return render(CheckoutPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('CheckoutPage — accessibility', () => {
  it('has no axe violations in its loaded (address form) state', async () => {
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('exposes exactly one <main> landmark and a level-1 heading', () => {
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(1);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/checkout/i);
  });

  it('labels every address field and names the submit control (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    expect(screen.getByLabelText(/street/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/city/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/state/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/postcode/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/country/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/phone/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /continue to payment/i })).toBeInTheDocument();
    // Keyboard reachability: first Tab lands on the first field, no trap before it.
    await user.tab();
    expect(screen.getByLabelText(/street/i)).toHaveFocus();
  });
});
