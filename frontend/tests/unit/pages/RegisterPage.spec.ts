import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/vue';
import { flushPromises } from '@vue/test-utils';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import RegisterPage from '@/pages/RegisterPage.vue';

const registerMutateAsync = vi.fn();

vi.mock('@/api/queries/auth', () => ({
  useRegisterMutation: () => ({
    mutateAsync: registerMutateAsync,
    isPending: { value: false },
  }),
  useLoginMutation: vi.fn(),
  useLogout: () => () => {},
}));

beforeEach(async () => {
  vi.useFakeTimers();
  setActivePinia(createPinia());
  registerMutateAsync.mockReset();
  router.push('/register');
  await router.isReady();
});

afterEach(() => {
  vi.useRealTimers();
});

const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });

function mount() {
  return render(RegisterPage, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]],
    },
  });
}

describe('RegisterPage', () => {
  it('happy path: submits and navigates to /activate with email query', async () => {
    registerMutateAsync.mockResolvedValueOnce(undefined);
    mount();
    await user.type(screen.getByLabelText(/username/i), 'son');
    await user.type(screen.getByLabelText(/email/i), 'son@example.com');
    await user.type(screen.getByLabelText(/^password$/i), 'Aa1!aa');
    await user.type(screen.getByLabelText(/confirm password/i), 'Aa1!aa');
    await user.click(screen.getByRole('button', { name: /register/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() => expect(registerMutateAsync).toHaveBeenCalled());
    await waitFor(() => {
      expect(router.currentRoute.value.path).toBe('/activate');
      expect(router.currentRoute.value.query.email).toBe('son@example.com');
    });
  });

  it('renders "Activate your account" footer link', () => {
    mount();
    const link = screen.getByRole('link', { name: /activate your account/i });
    expect(link.getAttribute('href')).toBe('/activate');
  });

  it('shows password-rules error for weak password', async () => {
    mount();
    await user.type(screen.getByLabelText(/username/i), 'son');
    await user.type(screen.getByLabelText(/email/i), 'son@example.com');
    await user.type(screen.getByLabelText(/^password$/i), 'weak');
    await user.type(screen.getByLabelText(/confirm password/i), 'weak');
    await user.click(screen.getByRole('button', { name: /register/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() =>
      expect(screen.getByText(/min 6 chars with upper, lower, number/i)).toBeInTheDocument(),
    );
    expect(registerMutateAsync).not.toHaveBeenCalled();
  });
});
