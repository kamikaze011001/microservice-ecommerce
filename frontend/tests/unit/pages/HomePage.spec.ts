import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { flushPromises } from '@vue/test-utils';
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

describe('HomePage search', () => {
  const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });

  it('debounces typing — 5 fast keystrokes produce 1 keyword change', async () => {
    let capturedGetter: (() => { keyword?: string }) | null = null;
    useProductListQuery.mockImplementation((paramsArg: () => { keyword?: string }) => {
      capturedGetter = paramsArg;
      return {
        data: { value: makePage(0) },
        isLoading: { value: false },
        isFetching: { value: false },
        isError: { value: false },
        error: { value: null },
      };
    });
    mount();
    expect(capturedGetter).not.toBeNull();
    const input = screen.getByLabelText(/search/i);
    await user.type(input, 'shoes');
    vi.advanceTimersByTime(399);
    await flushPromises();
    expect(capturedGetter!().keyword ?? '').toBe('');
    vi.advanceTimersByTime(1);
    await flushPromises();
    expect(capturedGetter!().keyword ?? '').toBe('shoes');
  });

  it('writes ?q= to URL after debounce', async () => {
    useProductListQuery.mockReturnValue({
      data: { value: makePage(0) },
      isLoading: { value: false },
      isFetching: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    await user.type(screen.getByLabelText(/search/i), 'lamp');
    vi.advanceTimersByTime(400);
    await flushPromises();
    expect(router.currentRoute.value.query.q).toBe('lamp');
  });

  it('hydrates input from ?q= on direct navigation', async () => {
    useProductListQuery.mockReturnValue({
      data: { value: makePage(0) },
      isLoading: { value: false },
      isFetching: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    await router.push('/?q=stool');
    await router.isReady();
    mount();
    expect((screen.getByLabelText(/search/i) as HTMLInputElement).value).toBe('stool');
    expect(screen.getByText(/no matches for/i)).toBeInTheDocument();
  });
});

describe('HomePage pagination + states', () => {
  const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });

  it('clicking page 2 writes ?page=2 to the URL', async () => {
    useProductListQuery.mockReturnValue({
      data: { value: { ...makePage(12), total: 36 } },
      isLoading: { value: false },
      isFetching: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    await user.click(screen.getByRole('button', { name: '2' }));
    await flushPromises();
    expect(router.currentRoute.value.query.page).toBe('2');
  });

  it('hydrates page from ?page= on direct navigation', async () => {
    useProductListQuery.mockImplementation((paramsArg: () => { page: number }) => {
      const p = paramsArg();
      return {
        data: { value: { ...makePage(12), page: p.page, total: 36 } },
        isLoading: { value: false },
        isFetching: { value: false },
        isError: { value: false },
        error: { value: null },
      };
    });
    await router.push('/?page=3');
    await router.isReady();
    mount();
    expect(screen.getByRole('button', { name: '3', current: 'page' })).toBeInTheDocument();
  });

  it('shows FETCHING stamp during refetch (data present + isFetching=true)', () => {
    useProductListQuery.mockReturnValue({
      data: { value: makePage(3) },
      isLoading: { value: false },
      isFetching: { value: true },
      isError: { value: false },
      error: { value: null },
    });
    mount();
    expect(screen.getByText(/fetching/i)).toBeInTheDocument();
  });

  it('shows OFFLINE banner with retry on network error', async () => {
    const refetch = vi.fn();
    useProductListQuery.mockReturnValue({
      data: { value: undefined },
      isLoading: { value: false },
      isFetching: { value: false },
      isError: { value: true },
      error: { value: { name: 'ApiError', status: 0, message: 'fail' } },
      refetch,
    });
    mount();
    expect(screen.getByText(/offline/i)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /retry/i }));
    expect(refetch).toHaveBeenCalled();
  });
});
