import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { useAuthStore } from '@/stores/auth';
import { refreshAccessToken } from '@/api/refresh';

describe('refreshAccessToken', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.stubGlobal('fetch', vi.fn());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('returns null and clears auth when no refresh token present', async () => {
    const result = await refreshAccessToken();
    expect(result).toBeNull();
    expect(global.fetch).not.toHaveBeenCalled();
  });

  it('coalesces concurrent calls into a single network request', async () => {
    const auth = useAuthStore();
    auth.login({ accessToken: 'old-at', refreshToken: 'old-rt' });

    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          status: 200,
          code: 'OK',
          message: 'ok',
          data: { access_token: 'new-at', refresh_token: 'new-rt' },
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const [r1, r2, r3] = await Promise.all([
      refreshAccessToken(),
      refreshAccessToken(),
      refreshAccessToken(),
    ]);

    expect(r1).toBe('new-at');
    expect(r2).toBe('new-at');
    expect(r3).toBe('new-at');
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(auth.accessToken).toBe('new-at');
    expect(auth.refreshToken).toBe('new-rt');
  });

  it('clears auth and returns null on refresh failure', async () => {
    const auth = useAuthStore();
    auth.login({ accessToken: 'old-at', refreshToken: 'old-rt' });

    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce(
      new Response('{}', { status: 401 }),
    );

    const result = await refreshAccessToken();
    expect(result).toBeNull();
    expect(auth.accessToken).toBeNull();
    expect(auth.refreshToken).toBeNull();
  });
});
