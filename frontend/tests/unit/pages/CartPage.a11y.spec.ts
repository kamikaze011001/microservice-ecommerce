// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import CartPage from '@/pages/CartPage.vue';

const useCartQuery = vi.fn();

vi.mock('@/api/queries/cart', () => ({
  useCartQuery: (...a: unknown[]) => useCartQuery(...a),
  useUpdateCartItemMutation: () => ({ mutate: vi.fn(), isPending: { value: false } }),
  useRemoveCartItemMutation: () => ({ mutate: vi.fn(), isPending: { value: false } }),
}));

beforeEach(async () => {
  setActivePinia(createPinia());
  // Two-line loaded state: exercises CartLineItem steppers/remove + CartSummary
  // + the checkout CTA — the richest interactive surface on this page.
  useCartQuery.mockReturnValue({
    data: {
      value: {
        shopping_cart_id: 'c1',
        user_id: 'u1',
        items: Array.from({ length: 2 }, (_, i) => ({
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
  await router.push('/cart');
  await router.isReady();
});

function mount() {
  return render(CartPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('CartPage — accessibility', () => {
  it('has no axe violations in its loaded (line-items) state', async () => {
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('exposes exactly one <main> landmark and a level-1 heading', () => {
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(1);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/cart/i);
  });

  it('names every interactive control and keeps the first Tab reachable (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    // Icon-only steppers/remove expose accessible names via aria-label; two rows → two of each.
    expect(screen.getAllByRole('button', { name: /increase quantity/i })).toHaveLength(2);
    expect(screen.getAllByRole('button', { name: /decrease quantity/i })).toHaveLength(2);
    expect(screen.getAllByRole('button', { name: /remove from cart/i })).toHaveLength(2);
    expect(screen.getByRole('button', { name: /proceed to checkout/i })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Product 1' })).toBeInTheDocument();
    // Keyboard reachability: first Tab lands on the first product link (the decrease
    // stepper is disabled at quantity 1, so the product link is the first focusable).
    await user.tab();
    expect(screen.getByRole('link', { name: 'Product 1' })).toHaveFocus();
  });
});
