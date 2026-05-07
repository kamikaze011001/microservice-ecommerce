import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { ref } from 'vue';
import { withSetup } from '../../helpers/withSetup';
import * as client from '@/api/client';
import {
  useCreateOrderMutation,
  useCancelOrderMutation,
  useOrderQuery,
} from '@/api/queries/orders';

beforeEach(() => {
  vi.useFakeTimers();
  vi.restoreAllMocks();
});
afterEach(() => vi.useRealTimers());

describe('queries/orders', () => {
  it('useCreateOrderMutation POSTs /orders', async () => {
    const apiFetch = vi.spyOn(client, 'apiFetch').mockResolvedValueOnce({ order_id: 'o1' });
    const [m, app] = withSetup(() => useCreateOrderMutation());
    const result = await m.mutateAsync({
      address: '123 Main, NYC, NY 11201, US',
      phone_number: '+15551234567',
      items: [{ product_id: 'p1', quantity: 1 }],
    });
    expect(result).toEqual({ order_id: 'o1' });
    expect(apiFetch).toHaveBeenCalledWith(
      '/order-service/v1/orders',
      {
        method: 'POST',
        body: JSON.stringify({
          address: '123 Main, NYC, NY 11201, US',
          phone_number: '+15551234567',
          items: [{ product_id: 'p1', quantity: 1 }],
        }),
      },
      expect.anything(),
    );
    app.unmount();
  });

  it('useCancelOrderMutation PATCHes /orders/{id}:cancel', async () => {
    const apiFetch = vi.spyOn(client, 'apiFetchUnsafe').mockResolvedValueOnce(undefined);
    const [m, app] = withSetup(() => useCancelOrderMutation());
    await m.mutateAsync('o1');
    expect(apiFetch).toHaveBeenCalledWith('/order-service/v1/orders/o1:cancel', {
      method: 'PATCH',
    });
    app.unmount();
  });

  it('useOrderQuery polls until order.status=COMPLETED', async () => {
    const apiFetch = vi
      .spyOn(client, 'apiFetchUnsafe')
      .mockResolvedValueOnce({ order: { id: 'o1', status: 'PROCESSING' }, payment: null })
      .mockResolvedValueOnce({ order: { id: 'o1', status: 'PROCESSING' }, payment: null })
      .mockResolvedValueOnce({ order: { id: 'o1', status: 'COMPLETED' }, payment: null });

    const orderId = ref('o1');
    const [q, app] = withSetup(() => useOrderQuery(orderId, { polling: true }));
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(1000);
    await vi.advanceTimersByTimeAsync(1000);
    await vi.advanceTimersByTimeAsync(1000);

    expect(apiFetch.mock.calls.length).toBeGreaterThanOrEqual(3);
    expect(q.data.value?.order?.status).toBe('COMPLETED');
    app.unmount();
  });
});
