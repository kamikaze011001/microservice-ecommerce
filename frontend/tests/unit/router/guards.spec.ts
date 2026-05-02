import { beforeEach, describe, expect, it } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { router } from '@/router';
import { useAuthStore } from '@/stores/auth';

beforeEach(async () => {
  setActivePinia(createPinia());
  localStorage.clear();
  router.push('/');
  await router.isReady();
});

describe('route guards', () => {
  it('guest hitting /cart redirects to /login?next=/cart', async () => {
    await router.push('/cart');
    expect(router.currentRoute.value.path).toBe('/login');
    expect(router.currentRoute.value.query.next).toBe('/cart');
  });

  it('authenticated user hitting /login is bounced to /', async () => {
    const auth = useAuthStore();
    auth.login({ accessToken: 'h.eyJzdWIiOiJzb24ifQ.s', refreshToken: 'r' });
    await router.push('/login');
    expect(router.currentRoute.value.path).toBe('/');
  });

  it('authenticated user can reach /cart', async () => {
    const auth = useAuthStore();
    auth.login({ accessToken: 'h.eyJzdWIiOiJzb24ifQ.s', refreshToken: 'r' });
    await router.push('/cart');
    expect(router.currentRoute.value.path).toBe('/cart');
  });
});
