import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import CartPage from '@/pages/CartPage.vue';

const useCartQuery = vi.fn();
const updateMutate = vi.fn();
const removeMutate = vi.fn();

vi.mock('@/api/queries/cart', () => ({
  useCartQuery: (...a: unknown[]) => useCartQuery(...a),
  useUpdateCartItemMutation: () => ({ mutate: updateMutate, isPending: { value: false } }),
  useRemoveCartItemMutation: () => ({ mutate: removeMutate, isPending: { value: false } }),
}));

beforeEach(async () => {
  vi.useFakeTimers({ shouldAdvanceTime: true });
  setActivePinia(createPinia());
  useCartQuery.mockReset();
  updateMutate.mockReset();
  removeMutate.mockReset();
  await router.push('/cart');
  await router.isReady();
});

afterEach(() => vi.useRealTimers());

function mount() {
  return render(CartPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

function withCart(items: number) {
  useCartQuery.mockReturnValue({
    data: {
      value: {
        shopping_cart_id: 'c1',
        user_id: 'u1',
        items: Array.from({ length: items }, (_, i) => ({
          shopping_cart_item_id: `i${i + 1}`,
          product_id: `p${i + 1}`,
          name: `Product ${i + 1}`,
          image_url: '',
          unit_price: 10 * (i + 1),
          quantity: 1,
          available_stock: 5,
        })),
      },
    },
    isLoading: { value: false },
    isFetching: { value: false },
    isError: { value: false },
    error: { value: null },
  });
}

describe('CartPage', () => {
  it('renders line items and subtotal', () => {
    withCart(2);
    mount();
    expect(screen.getAllByText('Product 1').length).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText('Product 2').length).toBeGreaterThanOrEqual(1);
    expect(screen.getByTestId('subtotal').textContent).toMatch(/\$30\.00/);
  });

  it('shows empty state when items are empty', () => {
    useCartQuery.mockReturnValue({
      data: { value: { shopping_cart_id: 'c1', user_id: 'u1', items: [] } },
      isLoading: { value: false },
      isFetching: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    expect(screen.getByText(/YOUR CART IS EMPTY/i)).toBeInTheDocument();
  });

  it('debounces qty stepper — 5 fast clicks fire 1 mutation', async () => {
    withCart(1);
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    mount();
    const inc = screen.getAllByLabelText('Increase quantity')[0];
    for (let i = 0; i < 5; i++) await user.click(inc);
    expect(updateMutate).toHaveBeenCalledTimes(0);
    await vi.advanceTimersByTimeAsync(450);
    expect(updateMutate).toHaveBeenCalledTimes(1);
    expect(updateMutate.mock.calls[0][0]).toMatchObject({
      shopping_cart_item_id: 'i1',
      quantity: 5,
    });
  });
});
