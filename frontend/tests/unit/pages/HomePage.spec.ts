import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import HomePage from '@/pages/HomePage.vue';

const useProductListQuery = vi.fn();

vi.mock('@/api/queries/products', () => ({
  useProductListQuery: (...args: unknown[]) => useProductListQuery(...args),
  useProductDetailQuery: vi.fn(),
}));

function makePage(items: number) {
  return {
    data: Array.from({ length: items }, (_, i) => ({
      id: `p${i + 1}`,
      name: `Product ${i + 1}`,
      price: 10 + i,
      attributes: {},
      quantity: 5,
      category: null,
      image_url: null,
    })),
    page: 1,
    size: 12,
    total: items,
  };
}

beforeEach(async () => {
  vi.useFakeTimers();
  setActivePinia(createPinia());
  useProductListQuery.mockReset();
  await router.push('/');
  await router.isReady();
});

afterEach(() => {
  vi.useRealTimers();
});

function mount() {
  return render(HomePage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('HomePage', () => {
  it('renders products from a successful list response', () => {
    useProductListQuery.mockReturnValue({
      data: { value: makePage(5) },
      isLoading: { value: false },
      isFetching: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    // Product 1 appears in both hero (first 3) and grid — use getAllByRole
    expect(screen.getAllByRole('heading', { level: 3, name: 'Product 1' }).length).toBeGreaterThan(
      0,
    );
    expect(screen.getByRole('heading', { level: 3, name: 'Product 5' })).toBeInTheDocument();
  });

  it('shows "ISSUE Nº01 / COMING SOON" stamp when total is zero with no keyword', () => {
    useProductListQuery.mockReturnValue({
      data: { value: { data: [], page: 1, size: 12, total: 0 } },
      isLoading: { value: false },
      isFetching: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    expect(screen.getByText(/coming soon/i)).toBeInTheDocument();
  });

  it('shows "STAMPING…" placeholder while loading first page', () => {
    useProductListQuery.mockReturnValue({
      data: { value: undefined },
      isLoading: { value: true },
      isFetching: { value: true },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    expect(screen.getByText(/stamping/i)).toBeInTheDocument();
  });
});
