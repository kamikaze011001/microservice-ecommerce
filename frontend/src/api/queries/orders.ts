import { computed, type MaybeRefOrGetter, toValue, type Ref } from 'vue';
import { useQuery, useMutation, useQueryClient, keepPreviousData } from '@tanstack/vue-query';
import { z } from 'zod';
import { apiFetch, apiFetchUnsafe } from '@/api/client';

export interface OrderItemInput {
  product_id: string;
  quantity: number;
}

export interface CreateOrderInput {
  address: string;
  phone_number?: string;
  items: OrderItemInput[];
}

export const CreateOrderResponseSchema = z.object({
  order_id: z.string(),
});
export type CreateOrderResponse = z.infer<typeof CreateOrderResponseSchema>;

export type OrderStatus = 'PROCESSING' | 'COMPLETED' | 'CANCELED' | 'FAILED' | 'REFUNDED';

export interface OrderSummary {
  id: string;
  status: OrderStatus | string;
  address: string;
  phone_number: string;
  created_at: string;
  updated_at: string;
  total_amount: number;
  item_count: number;
  first_item_image_url: string | null;
}

export interface OrdersListPage {
  data: OrderSummary[];
  page: number;
  size: number;
  total: number;
}

export function useOrdersListQuery(params: { page: Ref<number>; size: number }) {
  return useQuery({
    queryKey: computed(() => ['orders', 'list', params.page.value, params.size] as const),
    queryFn: () =>
      apiFetchUnsafe<OrdersListPage>(
        `/order-service/v1/orders?page=${params.page.value}&size=${params.size}`,
        { method: 'GET' },
      ),
    placeholderData: keepPreviousData,
  });
}

export type OrderResponse = OrderDetailBffData;

export function useCreateOrderMutation() {
  return useMutation({
    mutationFn: (input: CreateOrderInput) =>
      apiFetch(
        '/order-service/v1/orders',
        { method: 'POST', body: JSON.stringify(input) },
        CreateOrderResponseSchema,
      ),
  });
}

export function useCancelOrderMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (orderId: string) =>
      apiFetchUnsafe<void>(`/order-service/v1/orders/${encodeURIComponent(orderId)}:cancel`, {
        method: 'PATCH',
      }),
    onSuccess: (_, orderId) => qc.invalidateQueries({ queryKey: ['order', orderId] }),
  });
}

export interface OrderDetailItem {
  id: string;
  product_id: string;
  product_name: string | null;
  image_url: string | null;
  price: number;
  quantity: number;
}

export interface OrderDetailView {
  id: string;
  status: string;
  address: string;
  phone_number: string;
  created_at: string;
  updated_at: string;
  items: OrderDetailItem[];
}

export interface PaymentView {
  status: string | null;
  type: string | null;
  captured_at?: string | null;
}

export interface OrderDetailBffData {
  order: OrderDetailView;
  payment: PaymentView | null;
}

export function useOrderDetailBffQuery(orderId: Ref<string>) {
  return useQuery({
    queryKey: computed(() => ['orders', 'detail', orderId.value] as const),
    queryFn: () =>
      apiFetchUnsafe<OrderDetailBffData>(`/bff-service/v1/orders/${orderId.value}`, {
        method: 'GET',
      }),
    enabled: computed(() => !!orderId.value),
    retry: (failureCount, err) => {
      const status = (err as { status?: number })?.status;
      if (status === 404) return false;
      return failureCount < 2;
    },
  });
}

interface OrderQueryOptions {
  polling?: boolean;
}

export function useOrderQuery(orderId: MaybeRefOrGetter<string>, opts: OrderQueryOptions = {}) {
  return useQuery({
    queryKey: computed(() => ['order', toValue(orderId)] as const),
    queryFn: () =>
      apiFetchUnsafe<OrderResponse>(
        `/bff-service/v1/orders/${encodeURIComponent(toValue(orderId))}`,
        {
          method: 'GET',
        },
      ),
    enabled: computed(() => !!toValue(orderId)),
    refetchInterval: (query) => {
      if (!opts.polling) return false;
      const data = query.state.data as OrderResponse | undefined;
      const status = data?.order?.status;
      if (status === 'COMPLETED' || status === 'CANCELED' || status === 'FAILED') {
        return false;
      }
      return 1000;
    },
  });
}
