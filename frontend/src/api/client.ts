import createClient, { type Middleware } from 'openapi-fetch';
import type { ZodType, ZodTypeDef } from 'zod';
import type { paths } from './schema';
import { ApiError } from './error';
import { useAuthStore } from '@/stores/auth';
import { router } from '@/router';
import { refreshAccessToken } from './refresh';

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:6868';
const REFRESH_PATH = '/authorization-server/v1/auth:refresh-token';

// Pre-login / PERMIT_ALL auth endpoints. These must NOT carry an Authorization
// header: the gateway's JwtAuthenticationFilter validates any token present
// BEFORE the PERMIT_ALL check, so a stale access token left in the store 401s the
// request before it reaches the controller (e.g. activate after a prior session).
// (refresh-token is excluded — it sends the REFRESH token deliberately via refresh.ts.)
const NO_AUTH_PATHS = [
  '/authorization-server/v1/auth:login',
  '/authorization-server/v1/auth:register',
  '/authorization-server/v1/auth:activate',
  '/authorization-server/v1/auth:resend-otp',
  '/authorization-server/v1/auth:forgot-password',
  '/authorization-server/v1/auth:verify-forgot-pass-otp',
  '/authorization-server/v1/auth:reset-password',
];

function isPublicAuthUrl(url: string): boolean {
  return NO_AUTH_PATHS.some((p) => url.includes(p));
}

function isRefreshUrl(url: string): boolean {
  return url.endsWith(REFRESH_PATH);
}

function redirectToLogin() {
  useAuthStore().clear();
  const next = router.currentRoute.value.fullPath;
  router.replace({ path: '/login', query: { next } });
}

interface ErrorData {
  code?: string;
  message?: string;
  errors?: Record<string, string>;
}
interface BaseResponse<T> {
  status: number;
  code: string;
  data: T;
}

export function extractError(
  status: number,
  body: BaseResponse<unknown> | null,
  statusText: string,
): ApiError {
  const d = (body?.data ?? null) as ErrorData | null;
  return new ApiError(status, d?.code ?? '', d?.message ?? statusText, d?.errors);
}

const authMiddleware: Middleware = {
  async onRequest({ request }) {
    const auth = useAuthStore();
    // Skip public auth routes — sending a stale token there 401s at the gateway.
    if (auth.accessToken && !isPublicAuthUrl(request.url)) {
      request.headers.set('Authorization', `Bearer ${auth.accessToken}`);
    }
    return request;
  },
};

const requestClones = new WeakMap<Request, Request>();

const cloneMiddleware: Middleware = {
  async onRequest({ request }) {
    if (!isRefreshUrl(request.url)) {
      requestClones.set(request, request.clone());
    }
    return request;
  },
};

const errorMiddleware: Middleware = {
  async onResponse({ request, response }) {
    if (response.status === 401 && !isRefreshUrl(request.url)) {
      const newAT = await refreshAccessToken();
      if (newAT) {
        const original = requestClones.get(request);
        if (original) {
          const retryReq = new Request(original);
          retryReq.headers.set('Authorization', `Bearer ${newAT}`);
          const retryRes = await fetch(retryReq);
          if (retryRes.ok) return retryRes;
          response = retryRes;
        }
      }
    }
    if (!response.ok) {
      let body: BaseResponse<unknown> | null = null;
      try {
        body = (await response.clone().json()) as BaseResponse<unknown>;
      } catch {
        /* non-JSON body */
      }
      if (response.status === 401) {
        redirectToLogin();
      }
      throw extractError(response.status, body, response.statusText);
    }
    return response;
  },
};

export const client = createClient<paths>({ baseUrl: BASE_URL });
client.use(authMiddleware, cloneMiddleware, errorMiddleware);

/**
 * Unvalidated escape hatch. Unwraps `BaseResponse.data` and trusts the caller's
 * generic type — runtime shape is not checked. Prefer `apiFetch` with a Zod
 * schema for any new code; this function exists only for callers not yet migrated.
 */
export async function apiFetchUnsafe<T = unknown>(path: string, init: RequestInit): Promise<T> {
  const auth = useAuthStore();
  const headers = new Headers(init.headers ?? {});
  headers.set('content-type', headers.get('content-type') ?? 'application/json');
  // Same rule as authMiddleware: never attach a token to public auth routes.
  if (auth.accessToken && !isPublicAuthUrl(path))
    headers.set('authorization', `Bearer ${auth.accessToken}`);

  let response: Response;
  try {
    response = await fetch(`${BASE_URL}${path}`, { ...init, headers });
  } catch (e) {
    throw new ApiError(0, 'NETWORK', (e as Error).message);
  }

  if (response.status === 401 && !isRefreshUrl(path)) {
    const newAT = await refreshAccessToken();
    if (newAT) {
      const retryHeaders = new Headers(headers);
      retryHeaders.set('authorization', `Bearer ${newAT}`);
      try {
        response = await fetch(`${BASE_URL}${path}`, { ...init, headers: retryHeaders });
      } catch (e) {
        throw new ApiError(0, 'NETWORK', (e as Error).message);
      }
    }
  }

  let body: BaseResponse<T> | null = null;
  try {
    body = (await response.json()) as BaseResponse<T>;
  } catch {
    /* non-JSON */
  }

  if (!response.ok) {
    if (response.status === 401) {
      redirectToLogin();
    }
    throw extractError(response.status, body, response.statusText);
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
