import { computed, type MaybeRefOrGetter, toValue } from 'vue';
import { useQuery, keepPreviousData } from '@tanstack/vue-query';
import { apiFetch } from '@/api/client';

export interface ProductDto {
  id: string;
  name: string;
  price: number;
  attributes: Record<string, unknown> | null;
  quantity: number;
  category: string | null;
  image_url: string | null;
}

export interface ProductPage {
  page: number;
  size: number;
  total: number;
  data: ProductDto[];
}

export interface ProductListParams {
  keyword?: string;
  category?: string;
  page: number;
  size: number;
}

function buildListQs(p: ProductListParams): string {
  const qs = new URLSearchParams();
  qs.set('page', String(p.page));
  qs.set('size', String(p.size));
  if (p.keyword && p.keyword.trim() !== '') qs.set('keyword', p.keyword.trim());
  if (p.category && p.category.trim() !== '') qs.set('category', p.category.trim());
  return qs.toString();
}

export function useProductListQuery(params: MaybeRefOrGetter<ProductListParams>) {
  const queryKey = computed(() => {
    const p = toValue(params);
    return ['products', 'list', p] as const;
  });
  return useQuery({
    queryKey,
    queryFn: async () => {
      const p = toValue(params);
      return apiFetch<ProductPage>(`/product-service/v1/products?${buildListQs(p)}`, {
        method: 'GET',
      });
    },
    placeholderData: keepPreviousData,
    staleTime: 30_000,
  });
}

export function useProductDetailQuery(id: MaybeRefOrGetter<string>) {
  const queryKey = computed(() => ['products', 'detail', toValue(id)] as const);
  return useQuery({
    queryKey,
    queryFn: () =>
      apiFetch<ProductDto>(`/product-service/v1/products/${encodeURIComponent(toValue(id))}`, {
        method: 'GET',
      }),
    enabled: computed(() => !!toValue(id)),
    staleTime: 30_000,
  });
}
