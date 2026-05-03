import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';

const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import ProductDetailPage from '@/pages/ProductDetailPage.vue';
import { useAuthStore } from '@/stores/auth';

const useProductDetailQuery = vi.fn();
vi.mock('@/api/queries/products', () => ({
  useProductDetailQuery: (...args: unknown[]) => useProductDetailQuery(...args),
  useProductListQuery: vi.fn(),
}));

const addMutate = vi.fn();
vi.mock('@/api/queries/cart', () => ({
  useAddToCartMutation: () => ({
    mutate: addMutate,
    isPending: { value: false },
  }),
}));

function makeProduct(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id: 'p1',
    name: 'Glass Vase',
    price: 49.5,
    attributes: { Material: 'Glass', Origin: 'Vietnam' },
    quantity: 5,
    category: 'home',
    image_url: null,
    ...overrides,
  };
}

beforeEach(async () => {
  vi.useFakeTimers();
  setActivePinia(createPinia());
  useProductDetailQuery.mockReset();
  addMutate.mockReset();
  router.addRoute({ path: '/products/:id', component: ProductDetailPage });
  await router.push('/products/p1');
  await router.isReady();
});

afterEach(() => {
  vi.useRealTimers();
});

function mount() {
  return render(ProductDetailPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('ProductDetailPage render', () => {
  it('renders name, formatted price, and attribute rows', () => {
    useProductDetailQuery.mockReturnValue({
      data: { value: makeProduct() },
      isLoading: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    expect(screen.getByRole('heading', { name: /glass vase/i })).toBeInTheDocument();
    expect(screen.getByText('$49.50')).toBeInTheDocument();
    expect(screen.getByText(/material/i)).toBeInTheDocument();
    expect(screen.getAllByText(/glass/i).length).toBeGreaterThan(0);
  });

  it('renders image fallback when image_url is null', () => {
    useProductDetailQuery.mockReturnValue({
      data: { value: makeProduct({ image_url: null }) },
      isLoading: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    expect(screen.getByRole('img', { name: /glass vase/i })).toBeInTheDocument();
  });

  it('routes to NotFoundPage on 404', () => {
    useProductDetailQuery.mockReturnValue({
      data: { value: undefined },
      isLoading: { value: false },
      isError: { value: true },
      error: {
        value: Object.assign(new Error('Not found'), { name: 'ApiError', status: 404, code: '' }),
      },
    });
    mount();
    expect(screen.getByText(/not in this issue/i)).toBeInTheDocument();
  });
});

describe('ProductDetailPage CTA', () => {
  it('guest sees LOGIN TO BUY linking to /login?next=/products/p1', () => {
    useProductDetailQuery.mockReturnValue({
      data: { value: makeProduct() },
      isLoading: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    const link = screen.getByRole('link', { name: /login to buy/i }) as HTMLAnchorElement;
    expect(link.getAttribute('href')).toBe('/login?next=/products/p1');
  });

  it('authed in-stock user sees enabled ADD TO CART button', () => {
    useProductDetailQuery.mockReturnValue({
      data: { value: makeProduct({ quantity: 5 }) },
      isLoading: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    const auth = useAuthStore();
    auth.login({ accessToken: 'x', refreshToken: 'y' });
    mount();
    const btn = screen.getByRole('button', { name: /add to cart/i });
    expect(btn).not.toBeDisabled();
    expect(screen.queryByText(/available phase 5/i)).toBeNull();
    expect(screen.queryByRole('link', { name: /login to buy/i })).toBeNull();
  });

  it('clicking ADD TO CART fires useAddToCartMutation with product and qty=1', async () => {
    useProductDetailQuery.mockReturnValue({
      data: {
        value: makeProduct({ id: 'p1', price: 49.5, quantity: 5 }),
      },
      isLoading: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    const auth = useAuthStore();
    auth.login({ accessToken: 'tok', refreshToken: 'rtok' });
    mount();
    const button = screen.getByRole('button', { name: /ADD TO CART/i });
    await user.click(button);
    expect(addMutate).toHaveBeenCalledWith(
      { product_id: 'p1', quantity: 1, price: 49.5 },
      expect.any(Object),
    );
  });

  it('sold-out (quantity = 0) hides CTA and shows SOLD OUT stamp', () => {
    useProductDetailQuery.mockReturnValue({
      data: { value: makeProduct({ quantity: 0 }) },
      isLoading: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    expect(screen.queryByRole('button', { name: /add to cart/i })).toBeNull();
    expect(screen.queryByRole('link', { name: /login to buy/i })).toBeNull();
    expect(screen.getByText(/sold out/i)).toBeInTheDocument();
  });
});
