import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import ForgotPasswordPage from '@/pages/ForgotPasswordPage.vue';

const forgotMutateAsync = vi.fn();
const verifyMutateAsync = vi.fn();
const resetMutateAsync = vi.fn();
const resendMutateAsync = vi.fn();

vi.mock('@/api/queries/auth', () => ({
  useForgotPasswordMutation: () => ({
    mutateAsync: forgotMutateAsync,
    isPending: { value: false },
  }),
  useVerifyForgotOtpMutation: () => ({
    mutateAsync: verifyMutateAsync,
    isPending: { value: false },
  }),
  useResetPasswordMutation: () => ({
    mutateAsync: resetMutateAsync,
    isPending: { value: false },
  }),
  useResendOtpMutation: () => ({
    mutateAsync: resendMutateAsync,
    isPending: { value: false },
  }),
  useLoginMutation: vi.fn(),
  useRegisterMutation: vi.fn(),
  useActivateMutation: vi.fn(),
  useLogout: () => () => {},
}));

beforeEach(async () => {
  vi.useFakeTimers();
  setActivePinia(createPinia());
  forgotMutateAsync.mockReset();
  verifyMutateAsync.mockReset();
  resetMutateAsync.mockReset();
  resendMutateAsync.mockReset();
  await router.push('/forgot-password');
  await router.isReady();
});

afterEach(() => {
  vi.useRealTimers();
});

const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });

function mount() {
  return render(ForgotPasswordPage, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]],
    },
  });
}

describe('ForgotPasswordPage', () => {
  it('renders step 1 by default', () => {
    mount();
    expect(screen.getByText(/step 1 of 3/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/email/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /send code/i })).toBeInTheDocument();
  });
});

void user;
