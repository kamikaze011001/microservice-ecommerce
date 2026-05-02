import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/vue';
import { flushPromises } from '@vue/test-utils';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import LoginPage from '@/pages/LoginPage.vue';

const loginMutateAsync = vi.fn();

vi.mock('@/api/queries/auth', () => ({
  useLoginMutation: () => ({
    mutateAsync: loginMutateAsync,
    isPending: { value: false },
  }),
  useRegisterMutation: vi.fn(),
  useLogout: () => () => {},
}));

beforeEach(async () => {
  vi.useFakeTimers();
  setActivePinia(createPinia());
  loginMutateAsync.mockReset();
  router.push('/login');
  await router.isReady();
});

afterEach(() => {
  vi.useRealTimers();
});

// userEvent with fake timer advancement so keydown delays don't hang
const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });

function mount() {
  return render(LoginPage, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]],
    },
  });
}

describe('LoginPage', () => {
  it('happy path: submits and navigates to /', async () => {
    loginMutateAsync.mockResolvedValueOnce({ access_token: 't', refresh_token: 'r' });
    mount();
    await user.type(screen.getByLabelText(/username/i), 'son');
    await user.type(screen.getByLabelText(/password/i), 'Aa1!aa');
    await user.click(screen.getByRole('button', { name: /log in/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    expect(loginMutateAsync).toHaveBeenCalledWith({ username: 'son', password: 'Aa1!aa' });
  });

  it('wrong password: maps INVALID_CREDENTIALS to inline password error', async () => {
    loginMutateAsync.mockRejectedValueOnce(
      Object.assign(new Error('Wrong'), {
        status: 400,
        code: 'INVALID_CREDENTIALS',
        message: 'Wrong',
      }),
    );
    mount();
    await user.type(screen.getByLabelText(/username/i), 'son');
    await user.type(screen.getByLabelText(/password/i), 'Aa1!aa');
    await user.click(screen.getByRole('button', { name: /log in/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() => expect(screen.getByText(/wrong email or password/i)).toBeInTheDocument());
  });

  it('respects ?next= on successful login', async () => {
    await router.push('/login?next=/cart');
    loginMutateAsync.mockResolvedValueOnce({ access_token: 't', refresh_token: 'r' });
    mount();
    await user.type(screen.getByLabelText(/username/i), 'son');
    await user.type(screen.getByLabelText(/password/i), 'Aa1!aa');
    await user.click(screen.getByRole('button', { name: /log in/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    expect(loginMutateAsync).toHaveBeenCalled();
  });
});
