import { describe, it, expect, vi, beforeEach } from 'vitest';
import { withSetup } from '../../helpers/withSetup';
import * as client from '@/api/client';
import {
  useCartQuery,
  useAddToCartMutation,
  useUpdateCartItemMutation,
  useRemoveCartItemMutation,
} from '@/api/queries/cart';

beforeEach(() => {
  vi.restoreAllMocks();
});

describe('queries/cart', () => {
  it('useCartQuery GETs /bff-service/v1/cart', async () => {
    const apiFetch = vi.spyOn(client, 'apiFetch').mockResolvedValueOnce({
      shopping_cart_id: 'c1',
      user_id: 'u1',
      items: [],
    });
    const [, app] = withSetup(() => useCartQuery());
    await Promise.resolve();
    await Promise.resolve();
    expect(apiFetch).toHaveBeenCalledWith('/bff-service/v1/cart', { method: 'GET' });
    app.unmount();
  });

  it('useAddToCartMutation POSTs add-item with body', async () => {
    const apiFetch = vi.spyOn(client, 'apiFetch').mockResolvedValueOnce(undefined);
    const [mutation, app] = withSetup(() => useAddToCartMutation());
    await mutation.mutateAsync({ product_id: 'p1', quantity: 2, price: 25 });
    expect(apiFetch).toHaveBeenCalledWith('/bff-service/v1/cart:add-item', {
      method: 'POST',
      body: JSON.stringify({ product_id: 'p1', quantity: 2, price: 25 }),
    });
    app.unmount();
  });

  it('useUpdateCartItemMutation PATCHes update-item', async () => {
    const apiFetch = vi.spyOn(client, 'apiFetch').mockResolvedValueOnce(undefined);
    const [mutation, app] = withSetup(() => useUpdateCartItemMutation());
    await mutation.mutateAsync({ shopping_cart_item_id: 'i1', quantity: 3 });
    expect(apiFetch).toHaveBeenCalledWith('/bff-service/v1/cart:update-item', {
      method: 'PATCH',
      body: JSON.stringify({ shopping_cart_item_id: 'i1', quantity: 3 }),
    });
    app.unmount();
  });

  it('useRemoveCartItemMutation DELETEs with itemId query', async () => {
    const apiFetch = vi.spyOn(client, 'apiFetch').mockResolvedValueOnce(undefined);
    const [mutation, app] = withSetup(() => useRemoveCartItemMutation());
    await mutation.mutateAsync({ shopping_cart_item_id: 'i1' });
    expect(apiFetch).toHaveBeenCalledWith('/bff-service/v1/cart:delete-item?itemId=i1', {
      method: 'DELETE',
    });
    app.unmount();
  });
});
