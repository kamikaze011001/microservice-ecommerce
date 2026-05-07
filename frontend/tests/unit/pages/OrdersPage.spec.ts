import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { flushPromises } from '@vue/test-utils';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import OrdersPage from '@/pages/account/OrdersPage.vue';
import type { OrderSummary } from '@/api/queries/orders';

const useOrdersListQuery = vi.fn();

vi.mock('@/api/queries/orders', () => ({
  useOrdersListQuery: (...a: unknown[]) => useOrdersListQuery(...a),
}));

function makeOrder(i: number): OrderSummary {
  return {
    id: `${i.toString().padStart(8, '0')}-order`,
    status: 'PAID',
    address: `${i} Main St`,
    phone_number: '555-0000',
    created_at: '2024-01-01T00:00:00Z',
    updated_at: '2024-01-01T00:00:00Z',
    total_amount: 100 + i,
    item_count: i + 1,
    first_item_image_url: null,
  };
}

function makePageResult(orders: OrderSummary[], total: number, page = 1) {
  return {
    data: {
      value: {
        data: orders,
        page,
        size: 20,
        total,
      },
    },
    isLoading: { value: false },
    isError: { value: false },
    error: { value: null },
    refetch: vi.fn(),
  };
}

beforeEach(async () => {
  setActivePinia(createPinia());
  useOrdersListQuery.mockReset();
  await router.push('/account/orders');
  await router.isReady();
});

function mount() {
  return render(OrdersPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('OrdersPage', () => {
  it('Test 1: renders 3 receipt rows from mocked query data', () => {
    const orders = [makeOrder(1), makeOrder(2), makeOrder(3)];
    useOrdersListQuery.mockReturnValue(makePageResult(orders, 3));
    mount();

    // Each row renders a RouterLink with Nº{shortId} — shortId = id.slice(0,8).toUpperCase()
    // IDs are "00000001-order", "00000002-order", "00000003-order"
    // slice(0,8) gives "00000001", "00000002", "00000003"
    expect(screen.getByText(/Nº00000001/i)).toBeInTheDocument();
    expect(screen.getByText(/Nº00000002/i)).toBeInTheDocument();
    expect(screen.getByText(/Nº00000003/i)).toBeInTheDocument();
  });

  it('Test 2: empty state — shows LEDGER UNPRINTED stamp and BROWSE THE ISSUE link', () => {
    useOrdersListQuery.mockReturnValue(makePageResult([], 0, 1));
    mount();

    expect(screen.getByText(/LEDGER UNPRINTED/i)).toBeInTheDocument();
    expect(screen.getByText(/NO RECEIPTS HAVE BEEN STAMPED YET\./i)).toBeInTheDocument();

    const cta = screen.getByRole('link', { name: /BROWSE THE ISSUE/i });
    expect(cta).toBeInTheDocument();
    expect(cta).toHaveAttribute('href', '/');
  });

  it('Test 3: pagination — renders pager when total_elements > size; clicking page 2 updates active button', async () => {
    const user = userEvent.setup();

    // Initial: page 1, 40 total → 2 pages
    useOrdersListQuery.mockReturnValue(makePageResult([makeOrder(1)], 40, 1));
    mount();

    // Pager should be visible with at least page 1 and page 2 buttons
    const btn1 = screen.getByRole('button', { name: '1' });
    const btn2 = screen.getByRole('button', { name: '2' });
    expect(btn1).toBeInTheDocument();
    expect(btn2).toBeInTheDocument();

    // Page 1 should be active initially
    expect(btn1).toHaveAttribute('data-active', 'true');
    expect(btn2).toHaveAttribute('data-active', 'false');

    // After clicking page 2, re-render with page=2 data
    useOrdersListQuery.mockReturnValue(makePageResult([makeOrder(1)], 40, 2));
    await user.click(btn2);
    await flushPromises();

    // data-active on the current page button should now be true for page 2
    expect(screen.getByRole('button', { name: '2', current: 'page' })).toBeInTheDocument();
  });
});
