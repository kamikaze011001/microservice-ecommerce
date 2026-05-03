import { describe, it, expect, vi, beforeEach } from 'vitest';
import { withSetup } from '../../helpers/withSetup';
import * as client from '@/api/client';
import { useCreatePaymentMutation } from '@/api/queries/payments';

beforeEach(() => vi.restoreAllMocks());

describe('queries/payments', () => {
  it('POSTs /payments?orderId=...', async () => {
    const apiFetch = vi
      .spyOn(client, 'apiFetch')
      .mockResolvedValueOnce({
        id: 'pp1',
        links: [{ rel: 'approve', href: 'https://paypal/approve/x' }],
      });
    const [m, app] = withSetup(() => useCreatePaymentMutation());
    const result = await m.mutateAsync({ orderId: 'o1' });
    expect(apiFetch).toHaveBeenCalledWith('/payment-service/v1/payments?orderId=o1', {
      method: 'POST',
    });
    expect(result.approvalUrl).toBe('https://paypal/approve/x');
    app.unmount();
  });
});
