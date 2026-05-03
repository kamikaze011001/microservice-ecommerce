import createClient, { type Middleware } from 'openapi-fetch';
import type { paths } from './schema';
import { ApiError } from './error';
import { useAuthStore } from '@/stores/auth';
import { router } from '@/router';

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:6868';

interface BaseResponse<T> {
  status: number;
  code: string;
  message: string;
  data: T;
}

const authMiddleware: Middleware = {
  async onRequest({ request }) {
    const auth = useAuthStore();
    if (auth.accessToken) {
      request.headers.set('Authorization', `Bearer ${auth.accessToken}`);
    }
    return request;
  },
};

const errorMiddleware: Middleware = {
  async onResponse({ response }) {
    if (!response.ok) {
      let code = '';
      let message = response.statusText;
      try {
        const body = (await response.clone().json()) as BaseResponse<unknown>;
        code = body.code ?? '';
        message = body.message ?? message;
      } catch {
        /* non-JSON body */
      }
      if (response.status === 401) {
        useAuthStore().clear();
        const next = router.currentRoute.value.fullPath;
        router.replace({ path: '/login', query: { next } });
      }
      throw new ApiError(response.status, code, message);
    }
    return response;
  },
};

export const client = createClient<paths>({ baseUrl: BASE_URL });
client.use(authMiddleware, errorMiddleware);

/**
 * Thin escape hatch for endpoints not yet typed. Unwraps `BaseResponse.data`,
 * throws ApiError on non-2xx, runs through the same auth + 401-redirect path.
 */
export async function apiFetch<T = unknown>(path: string, init: RequestInit): Promise<T> {
  const auth = useAuthStore();
  const headers = new Headers(init.headers ?? {});
  headers.set('content-type', headers.get('content-type') ?? 'application/json');
  if (auth.accessToken) headers.set('authorization', `Bearer ${auth.accessToken}`);

  let response: Response;
  try {
    response = await fetch(`${BASE_URL}${path}`, { ...init, headers });
  } catch (e) {
    throw new ApiError(0, 'NETWORK', (e as Error).message);
  }

  let body: BaseResponse<T> | null = null;
  try {
    body = (await response.json()) as BaseResponse<T>;
  } catch {
    /* non-JSON */
  }

  if (!response.ok) {
    if (response.status === 401) {
      useAuthStore().clear();
      const next = router.currentRoute.value.fullPath;
      router.replace({ path: '/login', query: { next } });
    }
    throw new ApiError(response.status, body?.code ?? '', body?.message ?? response.statusText);
  }
  return (body?.data ?? (null as unknown)) as T;
}
