// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import ProductDetailPage from '@/pages/ProductDetailPage.vue';
import { useAuthStore } from '@/stores/auth';

const useProductDetailQuery = vi.fn();
vi.mock('@/api/queries/products', () => ({
  useProductDetailQuery: (...args: unknown[]) => useProductDetailQuery(...args),
  useProductListQuery: vi.fn(),
}));
vi.mock('@/api/queries/cart', () => ({
  useAddToCartMutation: () => ({ mutate: vi.fn(), isPending: { value: false } }),
}));

beforeEach(async () => {
  setActivePinia(createPinia());
  // Authed + in-stock is the richest loaded state: it renders the ADD TO CART
  // button (a real keyboard target) rather than the guest login link or sold-out stamp.
  useProductDetailQuery.mockReturnValue({
    data: {
      value: {
        id: 'p1',
        name: 'Glass Vase',
        price: 49.5,
        attributes: { Material: 'Glass', Origin: 'Vietnam' },
        quantity: 5,
        category: 'home',
        image_url: null,
      },
    },
    isLoading: { value: false },
    isError: { value: false },
    error: { value: null },
  });
  useAuthStore().login({ accessToken: 'x', refreshToken: 'y' });
  router.addRoute({ path: '/products/:id', component: ProductDetailPage });
  await router.push('/products/p1');
  await router.isReady();
});

function mount() {
  return render(ProductDetailPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('ProductDetailPage — accessibility', () => {
  it('has no axe violations in its loaded (authed, in-stock) state', async () => {
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('exposes exactly one <main> landmark and a level-1 heading', () => {
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(1);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/glass vase/i);
  });

  it('gives the product image an accessible name and names the CTA (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    // Image fallback still exposes the product name via alt text.
    expect(screen.getByRole('img', { name: /glass vase/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /add to cart/i })).toBeInTheDocument();
    // Keyboard reachability: the CTA is the sole focusable control, so first Tab lands on it.
    await user.tab();
    expect(screen.getByRole('button', { name: /add to cart/i })).toHaveFocus();
  });
});
