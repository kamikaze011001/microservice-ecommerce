import { computed, type MaybeRefOrGetter, toValue } from 'vue';
import { useQuery, useMutation, useQueryClient } from '@tanstack/vue-query';
import { apiFetch } from '@/api/client';

export interface OrderItemInput {
  product_id: string;
  quantity: number;
}

export interface CreateOrderInput {
  address: string;
  phone_number?: string;
  items: OrderItemInput[];
}

export interface CreateOrderResponse {
  orderId: string;
}

export type OrderStatus = 'PROCESSING' | 'PAID' | 'CANCELED' | 'FAILED';

export interface OrderResponse {
  orderId: string;
  status: OrderStatus;
  totalAmount?: number;
  items?: Array<{ product_id: string; quantity: number; unit_price: number; name?: string }>;
  address?: string;
  createdAt?: string;
}

export function useCreateOrderMutation() {
  return useMutation({
    mutationFn: (input: CreateOrderInput) =>
      apiFetch<CreateOrderResponse>('/order-service/v1/orders', {
        method: 'POST',
        body: JSON.stringify(input),
      }),
  });
}

export function useCancelOrderMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (orderId: string) =>
      apiFetch<void>(`/order-service/v1/orders/${encodeURIComponent(orderId)}:cancel`, {
        method: 'PATCH',
      }),
    onSuccess: (_, orderId) => qc.invalidateQueries({ queryKey: ['order', orderId] }),
  });
}

interface OrderQueryOptions {
  polling?: boolean;
}

export function useOrderQuery(orderId: MaybeRefOrGetter<string>, opts: OrderQueryOptions = {}) {
  return useQuery({
    queryKey: computed(() => ['order', toValue(orderId)] as const),
    queryFn: () =>
      apiFetch<OrderResponse>(`/bff-service/v1/orders/${encodeURIComponent(toValue(orderId))}`, {
        method: 'GET',
      }),
    enabled: computed(() => !!toValue(orderId)),
    refetchInterval: (query) => {
      if (!opts.polling) return false;
      const data = query.state.data as OrderResponse | undefined;
      if (data?.status === 'PAID' || data?.status === 'CANCELED' || data?.status === 'FAILED') {
        return false;
      }
      return 1000;
    },
  });
}
