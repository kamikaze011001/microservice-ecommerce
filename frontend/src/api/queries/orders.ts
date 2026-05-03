import { computed, type MaybeRefOrGetter, toValue, type Ref } from 'vue';
import { useQuery, useMutation, useQueryClient, keepPreviousData } from '@tanstack/vue-query';
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

export type OrderStatus = 'PENDING' | 'PROCESSING' | 'PAID' | 'CANCELED' | 'FAILED';

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
  content: OrderSummary[];
  page: number;
  size: number;
  total_elements: number;
}

export function useOrdersListQuery(params: { page: Ref<number>; size: number }) {
  return useQuery({
    queryKey: computed(() => ['orders', 'list', params.page.value, params.size] as const),
    queryFn: () =>
      apiFetch<OrdersListPage>(
        `/order-service/v1/orders?page=${params.page.value}&size=${params.size}`,
        { method: 'GET' },
      ),
    placeholderData: keepPreviousData,
  });
}

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
      apiFetch<OrderDetailBffData>(`/bff-service/v1/orders/${orderId.value}`, { method: 'GET' }),
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
