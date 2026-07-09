// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import PaymentResultPage from '@/pages/PaymentResultPage.vue';

// The page owns its own <main>, so the standard document-level rubric applies here
// (single <main> + a level-1 heading) — no LAYOUT_OWNED_RULES fragment carve-outs.
const useOrderQuery = vi.fn();
vi.mock('@/api/queries/orders', () => ({
  useOrderQuery: (...a: unknown[]) => useOrderQuery(...a),
  // Real refs so the template unwraps them to boolean false (buttons stay operable).
  useCancelOrderMutation: () => ({ mutateAsync: vi.fn(), isPending: ref(false) }),
}));
vi.mock('@/api/queries/payments', () => ({
  useCreatePaymentMutation: () => ({ mutateAsync: vi.fn(), isPending: ref(false) }),
}));

function setOrderStatus(status: string) {
  useOrderQuery.mockReturnValue({
    data: { value: { order: { id: 'order-1', status } } },
    isLoading: { value: false },
    isError: { value: false },
    error: { value: null },
  });
}

async function goto(path: string) {
  await router.push(path);
  await router.isReady();
}

beforeEach(() => {
  setActivePinia(createPinia());
  window.localStorage.clear();
  setOrderStatus('COMPLETED'); // success flow resolves to the "paid" terminal state
});

function mount() {
  return render(PaymentResultPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('PaymentResultPage — accessibility', () => {
  it('has no axe violations in the success (paid) confirmation state', async () => {
    await goto('/payment/success?orderId=order-1');
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('has no axe violations in the canceled state', async () => {
    await goto('/payment/cancel?orderId=order-1');
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('exposes exactly one <main> and a level-1 heading in the paid state', async () => {
    await goto('/payment/success?orderId=order-1');
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(1);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/confirmed/i);
  });

  it('links to the placed order in the paid state (SR + keyboard)', async () => {
    const user = userEvent.setup();
    await goto('/payment/success?orderId=order-1');
    mount();
    // Order status is announced as a named image, not silent decoration.
    expect(screen.getByRole('img', { name: /order status/i })).toBeInTheDocument();
    const link = screen.getByRole('link', { name: /view order/i });
    expect(link).toHaveAttribute('href', '/account/orders/order-1');
    // Keyboard: first Tab lands on the sole action (the order link), no trap before it.
    await user.tab();
    expect(link).toHaveFocus();
  });

  it('names the recovery actions and keeps them keyboard-reachable in the canceled state', async () => {
    const user = userEvent.setup();
    await goto('/payment/cancel?orderId=order-1');
    mount();
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/canceled/i);
    const retry = screen.getByRole('button', { name: /retry payment/i });
    expect(retry).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /cancel order/i })).toBeInTheDocument();
    // Keyboard: first Tab lands on the primary recovery action.
    await user.tab();
    expect(retry).toHaveFocus();
  });
});
