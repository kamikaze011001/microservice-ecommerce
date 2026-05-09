import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/vue';
import { flushPromises } from '@vue/test-utils';
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

  it('step 1: submitting a valid email calls forgot mutation and moves to step 2', async () => {
    forgotMutateAsync.mockResolvedValueOnce(undefined);
    mount();
    await user.type(screen.getByLabelText(/email/i), 'son@example.com');
    await user.click(screen.getByRole('button', { name: /send code/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    expect(forgotMutateAsync).toHaveBeenCalledWith({ email: 'son@example.com' });
    await waitFor(() => expect(screen.getByText(/step 2 of 3/i)).toBeInTheDocument());
  });

  it('step 1: server error surfaces as inline email error', async () => {
    forgotMutateAsync.mockRejectedValueOnce(
      Object.assign(new Error('No account found'), { status: 404 }),
    );
    mount();
    await user.type(screen.getByLabelText(/email/i), 'nope@example.com');
    await user.click(screen.getByRole('button', { name: /send code/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() => expect(screen.getByText(/no account found/i)).toBeInTheDocument());
    expect(screen.getByText(/step 1 of 3/i)).toBeInTheDocument();
  });

  async function advanceToStep2(emailValue = 'son@example.com') {
    forgotMutateAsync.mockResolvedValueOnce(undefined);
    mount();
    await user.type(screen.getByLabelText(/email/i), emailValue);
    await user.click(screen.getByRole('button', { name: /send code/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() => expect(screen.getByText(/step 2 of 3/i)).toBeInTheDocument());
  }

  it('step 2: submitting a valid OTP calls verify mutation and moves to step 3', async () => {
    verifyMutateAsync.mockResolvedValueOnce({ reset_password_key: 'rpk-abc' });
    await advanceToStep2();
    await user.type(screen.getByLabelText(/code/i), '123456');
    await user.click(screen.getByRole('button', { name: /^verify$/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    expect(verifyMutateAsync).toHaveBeenCalledWith({
      email: 'son@example.com',
      otp: '123456',
    });
    await waitFor(() => expect(screen.getByText(/step 3 of 3/i)).toBeInTheDocument());
  });

  it('step 2: invalid OTP surfaces inline error and clears the input', async () => {
    verifyMutateAsync.mockRejectedValueOnce(
      Object.assign(new Error('Invalid or expired code'), { status: 400 }),
    );
    await advanceToStep2();
    await user.type(screen.getByLabelText(/code/i), '999999');
    await user.click(screen.getByRole('button', { name: /^verify$/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() => expect(screen.getByText(/invalid or expired code/i)).toBeInTheDocument());
    expect((screen.getByLabelText(/code/i) as HTMLInputElement).value).toBe('');
    expect(screen.getByText(/step 2 of 3/i)).toBeInTheDocument();
  });

  it('step 2: resend triggers mutation and disables button for 30s', async () => {
    resendMutateAsync.mockResolvedValueOnce(undefined);
    await advanceToStep2();
    const btn = screen.getByRole('button', { name: /resend code/i });
    await user.click(btn);
    vi.advanceTimersByTime(10);
    await flushPromises();
    expect(resendMutateAsync).toHaveBeenCalledWith({
      type: 'forgot_password',
      email: 'son@example.com',
    });
    expect(btn).toBeDisabled();
    expect(btn.textContent ?? '').toMatch(/30/);
    vi.advanceTimersByTime(30_000);
    await flushPromises();
    expect(btn).not.toBeDisabled();
  });
});
