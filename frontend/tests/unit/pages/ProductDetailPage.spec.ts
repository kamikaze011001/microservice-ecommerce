import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import ProductDetailPage from '@/pages/ProductDetailPage.vue';

const useProductDetailQuery = vi.fn();
vi.mock('@/api/queries/products', () => ({
  useProductDetailQuery: (...args: unknown[]) => useProductDetailQuery(...args),
  useProductListQuery: vi.fn(),
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
