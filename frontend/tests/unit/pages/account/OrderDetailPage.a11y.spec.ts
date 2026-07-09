// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import OrderDetailPage from '@/pages/account/OrderDetailPage.vue';
import { useAuthStore } from '@/stores/auth';
import type { OrderDetailBffData } from '@/api/queries/orders';

const useOrderDetailBffQuery = vi.fn();
vi.mock('@/api/queries/orders', () => ({
  useOrderDetailBffQuery: (...a: unknown[]) => useOrderDetailBffQuery(...a),
  // Real refs so the template unwraps them to boolean false (buttons enabled/operable).
  useCancelOrderMutation: () => ({ mutateAsync: vi.fn(), isPending: ref(false) }),
}));
vi.mock('@/api/queries/cart', () => ({
  useAddToCartMutation: () => ({ mutateAsync: vi.fn(), isPending: ref(false) }),
}));

const loaded: OrderDetailBffData = {
  order: {
    id: 'order-1-abcdef01',
    status: 'PROCESSING', // PROCESSING → canCancel, so both action buttons render (richest state)
    address: '1 Press St, Ink City',
    phone_number: '555-0100',
    created_at: '2026-06-01T10:00:00Z',
    updated_at: '2026-06-01T10:00:00Z',
    items: [
      {
        id: 'it1',
        product_id: 'p1',
        product_name: 'Glass Vase',
        image_url: null,
        price: 49.5,
        quantity: 2,
      },
      {
        id: 'it2',
        product_id: 'p2',
        product_name: 'Brass Lamp',
        image_url: null,
        price: 120,
        quantity: 1,
      },
    ],
  },
  payment: null,
};

beforeEach(async () => {
  setActivePinia(createPinia());
  useOrderDetailBffQuery.mockReturnValue({
    data: { value: loaded },
    isLoading: { value: false },
    isError: { value: false },
    error: { value: null },
    refetch: vi.fn(),
  });
  useAuthStore().login({ accessToken: 'x', refreshToken: 'y' });
  await router.push('/account/orders/order-1-abcdef01');
  await router.isReady();
});

function mount() {
  return render(OrderDetailPage, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]],
      // ToastViewport renders <TransitionGroup tag="ol" aria-label="Notifications">.
      // VTU auto-stubs it to a roleless <transition-group-stub>, which axe flags for
      // aria-label-on-no-role — a stub artifact, not a real defect (in the browser it
      // is a real <ol>, where aria-label is valid). Render the real element instead.
      stubs: { transition: false, 'transition-group': false },
    },
  });
}

// OrderDetailPage is a layout-embedded fragment: AccountLayout owns the page's single
// <main> landmark. Mounted in isolation the top-level header/<h1> and total/meta/action
// blocks aren't wrapped by that main, so the document-level rules the layout owns are
// scoped out here. (This iteration ALSO fixed a real bug: OrderDetailPage previously
// rendered its own <main>, nesting a second main inside AccountLayout's — now a <div>.)
const LAYOUT_OWNED_RULES = {
  'landmark-one-main': { enabled: false },
  'page-has-heading-one': { enabled: false },
  region: { enabled: false },
} as const;

describe('OrderDetailPage — accessibility', () => {
  it('has no axe violations in its loaded (receipt) state', async () => {
    const { container } = mount();
    expect(await axe(container, { rules: LAYOUT_OWNED_RULES })).toHaveNoViolations();
  });

  it('is a fragment (no own <main>) but still provides the level-1 heading', () => {
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(0);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/receipt/i);
  });

  it('names the items region + actions and keeps items keyboard-reachable (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    // Line items live in a named region landmark.
    expect(screen.getByRole('region', { name: /order items/i })).toBeInTheDocument();
    // Both actions are reachable by accessible name (PROCESSING order can be voided).
    expect(screen.getByRole('button', { name: /stamp again/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /void this receipt/i })).toBeInTheDocument();
    // Each named item links to its product; keyboard: first Tab lands on the first item link.
    const links = screen.getAllByRole('link');
    expect(links[0]).toHaveAttribute('href', '/products/p1');
    await user.tab();
    expect(links[0]).toHaveFocus();
  });
});
