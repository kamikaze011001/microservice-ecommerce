import { describe, it, expect, beforeEach } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { router } from '@/router';
import { useAuthStore, AUTH_STORAGE_KEY } from '@/stores/auth';

describe('account routes', () => {
  beforeEach(async () => {
    // Clear any persisted auth so the store initialises as logged-out
    localStorage.removeItem(AUTH_STORAGE_KEY);
    // Replace the active pinia so useAuthStore() in the nav guard gets a fresh instance
    setActivePinia(createPinia());
    // Also clear the store state in case the module-level singleton was already seeded
    useAuthStore().clear();
    // Reset router to a neutral route so re-navigating to the same path triggers the guard
    await router.push('/');
    await router.isReady();
  });

  it('redirects /account to /account/profile when authed', async () => {
    useAuthStore().login({ accessToken: 'access', refreshToken: 'refresh' });
    await router.push('/account');
    await router.isReady();
    expect(router.currentRoute.value.path).toBe('/account/profile');
  });

  it('redirects unauthed user to /login with next', async () => {
    await router.push('/account/profile');
    await router.isReady();
    expect(router.currentRoute.value.path).toBe('/login');
    expect(router.currentRoute.value.query.next).toBe('/account/profile');
  });
});
