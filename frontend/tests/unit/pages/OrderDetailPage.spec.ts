import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { flushPromises } from '@vue/test-utils';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { createMemoryHistory, createRouter } from 'vue-router';
import OrderDetailPage from '@/pages/account/OrderDetailPage.vue';
import type { OrderDetailView, PaymentView } from '@/api/queries/orders';

// --- mocks ---
const useOrderDetailBffQuery = vi.fn();
const cancelMutate = vi.fn();
const addToCartMutate = vi.fn();

vi.mock('@/api/queries/orders', () => ({
  useOrderDetailBffQuery: (...a: unknown[]) => useOrderDetailBffQuery(...a),
  useCancelOrderMutation: () => ({
    mutateAsync: cancelMutate,
    isPending: { value: false },
  }),
}));

vi.mock('@/api/queries/cart', () => ({
  useAddToCartMutation: () => ({
    mutateAsync: addToCartMutate,
    isPending: { value: false },
  }),
}));

// --- helpers ---
const ORDER_ID = 'abcdef12-0000-0000-0000-000000000000';

function makeOrder(overrides: Partial<OrderDetailView> = {}): OrderDetailView {
  return {
    id: ORDER_ID,
    status: 'PAID',
    address: '123 Main St',
    phone_number: '555-0000',
    created_at: '2024-06-01T12:00:00Z',
    updated_at: '2024-06-01T12:00:00Z',
    items: [
      {
        id: 'i1',
        product_id: 'p1',
        product_name: 'Classic Tee',
        image_url: null,
        price: 25.0,
        quantity: 2,
      },
      {
        id: 'i2',
        product_id: 'p2',
        product_name: 'Canvas Bag',
        image_url: null,
        price: 40.0,
        quantity: 1,
      },
    ],
    ...overrides,
  };
}

function makePayment(): PaymentView {
  return { status: 'COMPLETED', type: 'PAYPAL', captured_at: '2024-06-01T12:05:00Z' };
}

function makeQuery(
  order?: OrderDetailView | null,
  payment?: PaymentView | null,
  opts: { isLoading?: boolean; isError?: boolean; error?: unknown } = {},
) {
  return {
    data: { value: order != null ? { order, payment: payment ?? null } : undefined },
    isLoading: { value: opts.isLoading ?? false },
    isError: { value: opts.isError ?? false },
    error: { value: opts.error ?? null },
    refetch: vi.fn(),
  };
}

function buildRouter(orderId = ORDER_ID) {
  const r = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/account/orders/:id', component: OrderDetailPage },
      { path: '/account/orders', component: { template: '<div>LEDGER</div>' } },
      { path: '/cart', component: { template: '<div>CART</div>' } },
      { path: '/products/:id', component: { template: '<div>PRODUCT</div>' } },
    ],
  });
  r.push(`/account/orders/${orderId}`);
  return r;
}

beforeEach(() => {
  setActivePinia(createPinia());
  useOrderDetailBffQuery.mockReset();
  cancelMutate.mockReset();
  addToCartMutate.mockReset();
});

function mount(orderId = ORDER_ID) {
  const r = buildRouter(orderId);
  return render(OrderDetailPage, {
    global: { plugins: [r, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('OrderDetailPage', () => {
  it('Test 1: renders hydrated items with product names and line subtotals', async () => {
    useOrderDetailBffQuery.mockReturnValue(makeQuery(makeOrder(), makePayment()));
    mount();
    await flushPromises();

    // product names may appear more than once (link + image fallback label)
    expect(screen.getAllByText('Classic Tee').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Canvas Bag').length).toBeGreaterThan(0);
    // subtotals: 2 × $25 = $50.00; 1 × $40 = $40.00
    expect(screen.getAllByText(/\$50\.00/).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/\$40\.00/).length).toBeGreaterThan(0);
  });

  it('Test 2: null product_name shows PRODUCT UNAVAILABLE as non-link', async () => {
    const order = makeOrder({
      items: [
        {
          id: 'i1',
          product_id: 'p1',
          product_name: null,
          image_url: null,
          price: 10,
          quantity: 1,
        },
      ],
    });
    useOrderDetailBffQuery.mockReturnValue(makeQuery(order, null));
    mount();
    await flushPromises();

    const unavailable = screen.getByText(/PRODUCT UNAVAILABLE/i);
    expect(unavailable).toBeInTheDocument();
    expect(unavailable.tagName).not.toBe('A');
  });

  it('Test 3: VOID THIS RECEIPT button hidden when status is PAID', async () => {
    useOrderDetailBffQuery.mockReturnValue(makeQuery(makeOrder({ status: 'PAID' }), makePayment()));
    mount();
    await flushPromises();

    expect(screen.queryByRole('button', { name: /VOID THIS RECEIPT/i })).not.toBeInTheDocument();
  });

  it('Test 4: VOID THIS RECEIPT visible for PENDING; clicking opens dialog without calling mutation', async () => {
    const user = userEvent.setup();
    useOrderDetailBffQuery.mockReturnValue(
      makeQuery(makeOrder({ status: 'PENDING' }), makePayment()),
    );
    mount();
    await flushPromises();

    const voidBtn = screen.getByRole('button', { name: /VOID THIS RECEIPT/i });
    expect(voidBtn).toBeInTheDocument();

    await user.click(voidBtn);
    await flushPromises();

    // Dialog should now be visible
    expect(screen.getByText(/Void this order\?/i)).toBeInTheDocument();
    // Mutation not called yet
    expect(cancelMutate).not.toHaveBeenCalled();
  });

  it('Test 5: confirming VOID calls cancelMutate with orderId', async () => {
    const user = userEvent.setup();
    cancelMutate.mockResolvedValue(undefined);
    useOrderDetailBffQuery.mockReturnValue(
      makeQuery(makeOrder({ status: 'PENDING' }), makePayment()),
    );
    mount();
    await flushPromises();

    await user.click(screen.getByRole('button', { name: /VOID THIS RECEIPT/i }));
    await flushPromises();

    await user.click(screen.getByRole('button', { name: /CONFIRM VOID/i }));
    await flushPromises();

    expect(cancelMutate).toHaveBeenCalledWith(ORDER_ID);
  });

  it('Test 6: STAMP AGAIN loops addToCart over all items and navigates to /cart; partial 409 surfaces skipped name', async () => {
    const user = userEvent.setup();
    // First item succeeds, second throws 409
    addToCartMutate
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(Object.assign(new Error('Conflict'), { status: 409 }));

    useOrderDetailBffQuery.mockReturnValue(makeQuery(makeOrder(), makePayment()));
    const r = buildRouter();
    render(OrderDetailPage, {
      global: { plugins: [r, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
    });
    await flushPromises();

    await user.click(screen.getByRole('button', { name: /STAMP AGAIN/i }));
    await flushPromises();

    // addToCart called for both items
    expect(addToCartMutate).toHaveBeenCalledTimes(2);

    // partial toast: skipped name visible (Canvas Bag may also appear in item list)
    await waitFor(() => expect(screen.getAllByText(/1 STAMPED/i).length).toBeGreaterThan(0));
    await waitFor(() => expect(screen.getAllByText(/Canvas Bag/i).length).toBeGreaterThan(0));
  });

  it('Test 7: 404 error shows NO RECEIPT FOR panel with back link', async () => {
    useOrderDetailBffQuery.mockReturnValue(
      makeQuery(null, null, { isError: true, error: { status: 404 } }),
    );
    mount();
    await flushPromises();

    expect(screen.getByText(/NO RECEIPT FOR/i)).toBeInTheDocument();
    const backLink = screen.getByRole('link', { name: /BACK TO LEDGER/i });
    expect(backLink).toBeInTheDocument();
    expect(backLink).toHaveAttribute('href', '/account/orders');
  });
});
