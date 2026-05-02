import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { useAuthStore } from '@/stores/auth';
import { ApiError } from '@/api/error';

const fetchMock = vi.fn();
const routerPush = vi.fn();

vi.mock('@/router', () => ({
  router: { currentRoute: { value: { fullPath: '/cart' } }, replace: routerPush },
}));

beforeEach(() => {
  setActivePinia(createPinia());
  fetchMock.mockReset();
  routerPush.mockReset();
  vi.stubGlobal('fetch', fetchMock);
  localStorage.clear();
});
afterEach(() => vi.unstubAllGlobals());

async function jsonRes(status: number, body: unknown): Promise<Response> {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

describe('apiFetch', () => {
  it('attaches Authorization header when logged in', async () => {
    const auth = useAuthStore();
    auth.login({ accessToken: 'h.e.s', refreshToken: 'r' });
    fetchMock.mockResolvedValueOnce(
      await jsonRes(200, { status: 200, code: 'OK', message: '', data: { ok: true } }),
    );
    const { apiFetch } = await import('@/api/client');
    await apiFetch('/anything', {});
    const headers = fetchMock.mock.calls[0][1].headers as Headers;
    expect(headers.get('authorization')).toBe('Bearer h.e.s');
  });

  it('unwraps data on 2xx', async () => {
    fetchMock.mockResolvedValueOnce(
      await jsonRes(200, { status: 200, code: 'OK', message: '', data: { id: 7 } }),
    );
    const { apiFetch } = await import('@/api/client');
    const data = await apiFetch('/x', {});
    expect(data).toEqual({ id: 7 });
  });

  it('throws ApiError on non-2xx', async () => {
    fetchMock.mockResolvedValueOnce(
      await jsonRes(400, { status: 400, code: 'BAD', message: 'nope', data: null }),
    );
    const { apiFetch } = await import('@/api/client');
    await expect(apiFetch('/x', {})).rejects.toMatchObject({
      status: 400,
      code: 'BAD',
      message: 'nope',
    });
  });

  it('on 401 clears store and pushes /login?next=…', async () => {
    const auth = useAuthStore();
    auth.login({ accessToken: 'h.e.s', refreshToken: 'r' });
    fetchMock.mockResolvedValueOnce(
      await jsonRes(401, { status: 401, code: 'UNAUTHORIZED', message: 'x', data: null }),
    );
    const { apiFetch } = await import('@/api/client');
    await expect(apiFetch('/x', {})).rejects.toBeInstanceOf(ApiError);
    expect(auth.isLoggedIn).toBe(false);
    expect(routerPush).toHaveBeenCalledWith({
      path: '/login',
      query: { next: '/cart' },
    });
  });

  it('on network failure throws ApiError(status=0)', async () => {
    fetchMock.mockRejectedValueOnce(new TypeError('Failed to fetch'));
    const { apiFetch } = await import('@/api/client');
    await expect(apiFetch('/x', {})).rejects.toMatchObject({ status: 0 });
  });
});
