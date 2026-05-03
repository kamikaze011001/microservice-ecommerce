import { useQuery, useMutation, useQueryClient } from '@tanstack/vue-query';
import { apiFetch } from '@/api/client';

export interface CartItem {
  shopping_cart_item_id: string;
  product_id: string;
  name: string;
  image_url: string;
  unit_price: number;
  quantity: number;
  available_stock: number;
}

export interface CartResponse {
  shopping_cart_id: string;
  user_id: string;
  items: CartItem[];
}

export interface AddToCartInput {
  product_id: string;
  quantity: number;
  price: number;
}

export interface UpdateCartItemInput {
  shopping_cart_item_id: string;
  quantity: number;
}

export interface RemoveCartItemInput {
  shopping_cart_item_id: string;
}

const CART_KEY = ['cart'] as const;

export function useCartQuery() {
  return useQuery({
    queryKey: CART_KEY,
    queryFn: () => apiFetch<CartResponse>('/bff-service/v1/cart', { method: 'GET' }),
    staleTime: 0,
  });
}

export function useAddToCartMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: AddToCartInput) =>
      apiFetch<void>('/bff-service/v1/cart:add-item', {
        method: 'POST',
        body: JSON.stringify(input),
      }),
    onSuccess: () => qc.invalidateQueries({ queryKey: CART_KEY }),
  });
}

export function useUpdateCartItemMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: UpdateCartItemInput) =>
      apiFetch<void>('/bff-service/v1/cart:update-item', {
        method: 'PATCH',
        body: JSON.stringify(input),
      }),
    onMutate: async (input) => {
      await qc.cancelQueries({ queryKey: CART_KEY });
      const prev = qc.getQueryData<CartResponse>(CART_KEY);
      if (prev) {
        qc.setQueryData<CartResponse>(CART_KEY, {
          ...prev,
          items: prev.items.map((i) =>
            i.shopping_cart_item_id === input.shopping_cart_item_id
              ? { ...i, quantity: input.quantity }
              : i,
          ),
        });
      }
      return { prev };
    },
    onError: (_err, _input, ctx) => {
      if (ctx?.prev) qc.setQueryData(CART_KEY, ctx.prev);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: CART_KEY }),
  });
}

export function useRemoveCartItemMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: RemoveCartItemInput) =>
      apiFetch<void>(
        `/bff-service/v1/cart:delete-item?itemId=${encodeURIComponent(input.shopping_cart_item_id)}`,
        { method: 'DELETE' },
      ),
    onMutate: async (input) => {
      await qc.cancelQueries({ queryKey: CART_KEY });
      const prev = qc.getQueryData<CartResponse>(CART_KEY);
      if (prev) {
        qc.setQueryData<CartResponse>(CART_KEY, {
          ...prev,
          items: prev.items.filter((i) => i.shopping_cart_item_id !== input.shopping_cart_item_id),
        });
      }
      return { prev };
    },
    onError: (_err, _input, ctx) => {
      if (ctx?.prev) qc.setQueryData(CART_KEY, ctx.prev);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: CART_KEY }),
  });
}
