// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import HomePage from '@/pages/HomePage.vue';

// Top-level page: it owns its own <main> + <h1> (the hero headline), so the standard
// document-level rubric applies (single <main>, level-1 heading). The <h1> only renders
// when hero items exist, so the guard mounts the primary loaded state (products, page 1).
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

function loaded(items: number) {
  useProductListQuery.mockReturnValue({
    data: { value: makePage(items) },
    isLoading: { value: false },
    isFetching: { value: false },
    isError: { value: false },
    error: { value: null },
    refetch: vi.fn(),
  });
}

beforeEach(async () => {
  setActivePinia(createPinia());
  useProductListQuery.mockReset();
  loaded(5);
  await router.push('/');
  await router.isReady();
});

function mount() {
  return render(HomePage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('HomePage — accessibility', () => {
  it('has no axe violations in its primary loaded (catalog) state', async () => {
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('exposes exactly one <main> landmark and a level-1 heading', () => {
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(1);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/in stock/i);
  });

  it('names the browse landmarks and labels the search field (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    // Search input is labeled so SR users can find it by name, not placeholder alone.
    expect(screen.getByLabelText(/search/i)).toBeInTheDocument();
    // Spotlight + Catalog sections are named regions (via their sr-only <h2> headings),
    // which also keep the heading order h1 → h2 → h3 intact for assistive tech.
    expect(screen.getByRole('region', { name: /catalog/i })).toBeInTheDocument();
    expect(screen.getByRole('region', { name: /spotlight/i })).toBeInTheDocument();
    // Keyboard reachability: the spotlight product links come first in DOM order, so the
    // first Tab lands on the first product link — content is reachable with no trap before it.
    const firstProduct = screen.getAllByRole('link', { name: /product 1/i })[0];
    await user.tab();
    expect(firstProduct).toHaveFocus();
  });
});
