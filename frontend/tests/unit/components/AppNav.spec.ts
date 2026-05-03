import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render } from '@testing-library/vue';
import { createPinia, setActivePinia } from 'pinia';
import { ref } from 'vue';
import { createRouter, createMemoryHistory } from 'vue-router';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import AppNav from '@/components/layout/AppNav.vue';
import { useAuthStore, AUTH_STORAGE_KEY } from '@/stores/auth';

vi.mock('@/api/queries/profile', () => ({
  useProfileQuery: () => ({
    data: ref({
      id: 'u1',
      name: 'Son Anh',
      email: 'son@example.com',
      gender: null,
      address: null,
    }),
    isLoading: ref(false),
    isError: ref(false),
  }),
}));
vi.mock('@/api/queries/auth', () => ({ useLogout: () => () => {} }));

const router = createRouter({
  history: createMemoryHistory(),
  routes: [
    { path: '/', component: { template: '<div />' } },
    { path: '/account', component: { template: '<div />' } },
    { path: '/login', component: { template: '<div />' } },
  ],
});

beforeEach(() => {
  setActivePinia(createPinia());
  localStorage.clear();
  localStorage.setItem(
    AUTH_STORAGE_KEY,
    JSON.stringify({ accessToken: 'h.eyJzdWIiOiJ1MSJ9.s', refreshToken: 'r' }),
  );
});

describe('AppNav greeting', () => {
  it('shows HI, {NAME} from profile, not @{uuid}', async () => {
    useAuthStore();
    const { findByTestId } = render(AppNav, {
      global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
    });
    const el = await findByTestId('nav-user');
    expect(el.textContent).toBe('HI, SON ANH');
  });
});
