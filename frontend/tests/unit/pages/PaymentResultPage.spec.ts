import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';
import { render, screen, waitFor } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import PaymentResultPage from '@/pages/PaymentResultPage.vue';

const orderData = ref<{ orderId: string; status: string } | undefined>(undefined);
const useOrderQuery = vi.fn();
const cancelMutate = vi.fn();
const createPayment = vi.fn();

vi.mock('@/api/queries/orders', () => ({
  useOrderQuery: (...a: unknown[]) => useOrderQuery(...a),
  useCancelOrderMutation: () => ({ mutateAsync: cancelMutate, isPending: { value: false } }),
}));
vi.mock('@/api/queries/payments', () => ({
  useCreatePaymentMutation: () => ({ mutateAsync: createPayment, isPending: { value: false } }),
}));

beforeEach(async () => {
  setActivePinia(createPinia());
  useOrderQuery.mockReset();
  cancelMutate.mockReset();
  createPayment.mockReset();
  orderData.value = undefined;
  localStorage.clear();
});

afterEach(() => vi.useRealTimers());

function mount(path: string) {
  return router.push(path).then(() =>
    render(PaymentResultPage, {
      global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
    }),
  );
}

describe('PaymentResultPage — success', () => {
  it('shows VERIFYING then PAID stamp once order status flips', async () => {
    useOrderQuery.mockReturnValue({
      data: orderData,
      isLoading: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    orderData.value = { orderId: 'o1', status: 'PROCESSING' };
    await mount('/payment/success?orderId=o1');
    expect(screen.getByText(/VERIFYING…/i)).toBeInTheDocument();
    orderData.value = { orderId: 'o1', status: 'PAID' };
    await waitFor(() => expect(screen.getByText(/^PAID$/)).toBeInTheDocument());
  });

  it('shows STILL PROCESSING after polling timeout (10s)', async () => {
    vi.useFakeTimers();
    useOrderQuery.mockReturnValue({
      data: ref({ orderId: 'o1', status: 'PROCESSING' }),
      isLoading: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    await mount('/payment/success?orderId=o1');
    expect(screen.getByText(/VERIFYING…/i)).toBeInTheDocument();
    await vi.advanceTimersByTimeAsync(10_000);
    await waitFor(() => expect(screen.getByText(/STILL PROCESSING/i)).toBeInTheDocument());
  });
});

describe('PaymentResultPage — cancel', () => {
  it('renders CANCELED stamp and exposes RETRY/CANCEL buttons', async () => {
    useOrderQuery.mockReturnValue({
      data: ref({ orderId: 'o1', status: 'PROCESSING' }),
      isLoading: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    await mount('/payment/cancel?orderId=o1');
    expect(screen.getByText(/PAYMENT CANCELED/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /RETRY PAYMENT/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /CANCEL ORDER/i })).toBeInTheDocument();
  });

  it('CANCEL ORDER calls cancel mutation and routes home', async () => {
    cancelMutate.mockResolvedValueOnce(undefined);
    useOrderQuery.mockReturnValue({
      data: ref({ orderId: 'o1', status: 'PROCESSING' }),
      isLoading: { value: false },
      isError: { value: false },
      error: { value: null },
    });
    await mount('/payment/cancel?orderId=o1');
    await userEvent.click(screen.getByRole('button', { name: /CANCEL ORDER/i }));
    await waitFor(() => expect(cancelMutate).toHaveBeenCalledWith('o1'));
  });
});
