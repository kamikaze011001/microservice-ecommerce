import { beforeEach, describe, expect, it } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { useAuthStore, AUTH_STORAGE_KEY } from '@/stores/auth';

const FAKE_TOKEN = 'h.eyJzdWIiOiJzb24iLCJleHAiOjk5OTk5OTk5OTl9.s';

beforeEach(() => {
  setActivePinia(createPinia());
  localStorage.clear();
});

describe('useAuthStore.login', () => {
  it('sets tokens, derives username from JWT, persists to localStorage', () => {
    const auth = useAuthStore();
    auth.login({ accessToken: FAKE_TOKEN, refreshToken: 'r' });
    expect(auth.accessToken).toBe(FAKE_TOKEN);
    expect(auth.refreshToken).toBe('r');
    expect(auth.username).toBe('son');
    expect(auth.isLoggedIn).toBe(true);
    expect(JSON.parse(localStorage.getItem(AUTH_STORAGE_KEY)!)).toMatchObject({
      accessToken: FAKE_TOKEN,
      refreshToken: 'r',
    });
  });
});

describe('useAuthStore.clear / logout', () => {
  it('clear() empties state and localStorage', () => {
    const auth = useAuthStore();
    auth.login({ accessToken: FAKE_TOKEN, refreshToken: 'r' });
    auth.clear();
    expect(auth.accessToken).toBeNull();
    expect(auth.isLoggedIn).toBe(false);
    expect(localStorage.getItem(AUTH_STORAGE_KEY)).toBeNull();
  });
});

describe('useAuthStore hydration', () => {
  it('reads existing localStorage on init', () => {
    localStorage.setItem(
      AUTH_STORAGE_KEY,
      JSON.stringify({ accessToken: FAKE_TOKEN, refreshToken: 'r' }),
    );
    const auth = useAuthStore();
    expect(auth.isLoggedIn).toBe(true);
    expect(auth.username).toBe('son');
  });
});

describe('storage event sync', () => {
  it('clears the store when another tab removes the key', () => {
    const auth = useAuthStore();
    auth.login({ accessToken: FAKE_TOKEN, refreshToken: 'r' });
    window.dispatchEvent(new StorageEvent('storage', { key: AUTH_STORAGE_KEY, newValue: null }));
    expect(auth.isLoggedIn).toBe(false);
  });
});
