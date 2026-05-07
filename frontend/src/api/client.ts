import createClient, { type Middleware } from 'openapi-fetch';
import type { ZodType, ZodTypeDef } from 'zod';
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
 * Unvalidated escape hatch. Unwraps `BaseResponse.data` and trusts the caller's
 * generic type — runtime shape is not checked. Prefer `apiFetch` with a Zod
 * schema for any new code; this function exists only for callers not yet migrated.
 */
export async function apiFetchUnsafe<T = unknown>(path: string, init: RequestInit): Promise<T> {
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

/**
 * Validated fetch: parses `BaseResponse.data` through the supplied Zod schema.
 * The return type is derived from the schema, so the TS type can never drift
 * from the runtime contract. A schema mismatch throws an `ApiError` with code
 * `SCHEMA_MISMATCH` so wire-format drift surfaces at the boundary instead of
 * silently producing `undefined` deeper in the call stack.
 */
export async function apiFetch<S extends ZodType<unknown, ZodTypeDef, unknown>>(
  path: string,
  init: RequestInit,
  schema: S,
): Promise<ReturnType<S['parse']>> {
  const data = await apiFetchUnsafe<unknown>(path, init);
  const result = schema.safeParse(data);
  if (!result.success) {
    const issue = result.error.issues[0];
    const where = issue?.path.length ? issue.path.join('.') : '<root>';
    throw new ApiError(
      0,
      'SCHEMA_MISMATCH',
      `Response from ${path} did not match expected shape at ${where}: ${issue?.message ?? 'unknown'}`,
    );
  }
  return result.data as ReturnType<S['parse']>;
}
