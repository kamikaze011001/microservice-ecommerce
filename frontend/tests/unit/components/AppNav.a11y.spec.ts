// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { ref } from 'vue';
import { setActivePinia, createPinia } from 'pinia';
import { createRouter, createMemoryHistory } from 'vue-router';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import AppNav from '@/components/layout/AppNav.vue';
import { useAuthStore, AUTH_STORAGE_KEY } from '@/stores/auth';

// Layout component: it renders the <nav> landmark, NOT a <main> or <h1>, so the
// document-level single-main/heading rubric does not apply. The a11y contract here
// is: the hamburger toggle exposes its state/target via ARIA, every action is
// reachable by accessible name, and the first Tab lands on the brand with no trap.
vi.mock('@/api/queries/profile', () => ({
  useProfileQuery: () => ({
    data: ref({ id: 'u1', name: 'Son Anh', email: 'son@example.com', gender: null, address: null }),
    isLoading: ref(false),
    isError: ref(false),
  }),
}));
vi.mock('@/api/queries/auth', () => ({
  useLogoutMutation: () => ({ mutate: vi.fn() }),
}));
vi.mock('@/api/queries/cart', () => ({
  useCartQuery: () => ({
    data: ref({ items: [{ productId: 'p1', quantity: 2 }] }),
    isLoading: ref(false),
    isError: ref(false),
  }),
}));

const router = createRouter({
  history: createMemoryHistory(),
  routes: [
    { path: '/', component: { template: '<div />' } },
    { path: '/account', component: { template: '<div />' } },
    { path: '/cart', component: { template: '<div />' } },
    { path: '/login', component: { template: '<div />' } },
  ],
});

function loggedIn() {
  localStorage.setItem(
    AUTH_STORAGE_KEY,
    JSON.stringify({ accessToken: 'h.eyJzdWIiOiJ1MSJ9.s', refreshToken: 'r' }),
  );
}

beforeEach(async () => {
  setActivePinia(createPinia());
  localStorage.clear();
  loggedIn();
  await router.push('/');
  await router.isReady();
});

function mount() {
  useAuthStore();
  return render(AppNav, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('AppNav — accessibility', () => {
  it('has no axe violations in its logged-in (menu closed) state', async () => {
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('exposes a single navigation landmark', () => {
    const { container } = mount();
    expect(container.querySelectorAll('nav')).toHaveLength(1);
  });

  it('gives the hamburger toggle an accessible name and expanded/controls state', async () => {
    const user = userEvent.setup();
    mount();
    // The icon-only toggle must carry a text alternative + its open/closed state for SR users.
    const toggle = screen.getByRole('button', { name: /open menu/i });
    expect(toggle).toHaveAttribute('aria-expanded', 'false');
    expect(toggle).toHaveAttribute('aria-controls', 'app-nav-menu');
    // Activating it flips the exposed state and renames the control.
    await user.click(toggle);
    expect(screen.getByRole('button', { name: /close menu/i })).toHaveAttribute(
      'aria-expanded',
      'true',
    );
  });

  it('names every action and lands the first Tab on the brand link (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    // Brand is the first focusable control — keyboard users reach content with no trap before it.
    const brand = screen.getByRole('link', { name: /issue nº01/i });
    await user.tab();
    expect(brand).toHaveFocus();
    // Every logged-in action is reachable by accessible name (role + name, not by test id).
    expect(screen.getAllByRole('link', { name: /cart/i }).length).toBeGreaterThan(0);
    expect(screen.getAllByRole('link', { name: /account/i }).length).toBeGreaterThan(0);
    expect(screen.getAllByRole('button', { name: /log out/i }).length).toBeGreaterThan(0);
  });
});
