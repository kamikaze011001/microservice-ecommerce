// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import OrdersPage from '@/pages/account/OrdersPage.vue';
import { useAuthStore } from '@/stores/auth';
import type { OrderSummary } from '@/api/queries/orders';

const useOrdersListQuery = vi.fn();
vi.mock('@/api/queries/orders', () => ({
  useOrdersListQuery: (...a: unknown[]) => useOrdersListQuery(...a),
}));

function order(i: number): OrderSummary {
  return {
    id: `order-${i}-abcdef01`,
    status: 'COMPLETED',
    address: '1 Press St',
    phone_number: '555-0100',
    created_at: '2026-06-01T10:00:00Z',
    updated_at: '2026-06-01T10:00:00Z',
    total_amount: 42.5 * i,
    item_count: i,
    first_item_image_url: null,
  };
}

beforeEach(async () => {
  setActivePinia(createPinia());
  // Loaded, multi-page state: renders the receipt sheet (rows) AND the Pagination
  // nav (total 25 / size 20 → 2 pages) — the richest interactive surface on the page.
  useOrdersListQuery.mockReturnValue({
    data: { value: { data: [order(1), order(2), order(3)], page: 1, size: 20, total: 25 } },
    isLoading: { value: false },
    isError: { value: false },
    refetch: vi.fn(),
  });
  useAuthStore().login({ accessToken: 'x', refreshToken: 'y' });
  await router.push('/account/orders');
  await router.isReady();
});

function mount() {
  return render(OrdersPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

// OrdersPage is a layout-embedded fragment: AccountLayout owns the page's single
// <main> landmark. Mounted in isolation the top-level masthead/<h1> aren't wrapped
// by that main, so the document-level rules the layout owns are scoped out here.
// (This iteration ALSO fixed a real bug: OrdersPage previously rendered its own
// <main>, nesting a second main landmark inside AccountLayout's — now a <div>.)
const LAYOUT_OWNED_RULES = {
  'landmark-one-main': { enabled: false },
  'page-has-heading-one': { enabled: false },
  region: { enabled: false },
} as const;

describe('OrdersPage — accessibility', () => {
  it('has no axe violations in its loaded (receipts + pager) state', async () => {
    const { container } = mount();
    expect(await axe(container, { rules: LAYOUT_OWNED_RULES })).toHaveNoViolations();
  });

  it('is a fragment (no own <main>) but still provides the level-1 heading', () => {
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(0);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/ledger/i);
  });

  it('names the receipt region and pagination controls (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    // The receipt sheet is a named region landmark.
    expect(screen.getByRole('region', { name: /order receipts/i })).toBeInTheDocument();
    // Pagination is a named nav with one button per page; page 1 is the current page.
    const pager = screen.getByRole('navigation', { name: /pagination/i });
    expect(pager).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '1' })).toHaveAttribute('aria-current', 'page');
    expect(screen.getByRole('button', { name: '2' })).toBeInTheDocument();
    // Each receipt is a link to its detail page; keyboard: first Tab lands on the first row.
    const rows = screen.getAllByRole('link');
    expect(rows[0]).toHaveAttribute('href', '/account/orders/order-1-abcdef01');
    await user.tab();
    expect(rows[0]).toHaveFocus();
  });
});
