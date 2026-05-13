import { useMutation, useQueryClient } from '@tanstack/vue-query';
import { useRouter } from 'vue-router';
import { apiFetchUnsafe } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import type {
  LoginInput,
  RegisterInput,
  ActivateInput,
  ResendOtpInput,
  VerifyForgotOtpInput,
} from '@/lib/zod-schemas';

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:6868';

interface LoginResponseData {
  access_token: string;
  refresh_token: string;
}

async function callLogin(input: LoginInput): Promise<LoginResponseData> {
  return apiFetchUnsafe<LoginResponseData>('/authorization-server/v1/auth:login', {
    method: 'POST',
    body: JSON.stringify({ username: input.username, password: input.password }),
  });
}

async function callRegister(input: Omit<RegisterInput, 'confirmPassword'>): Promise<void> {
  await apiFetchUnsafe<unknown>('/authorization-server/v1/auth:register', {
    method: 'POST',
    body: JSON.stringify({
      username: input.username,
      email: input.email,
      password: input.password,
    }),
  });
}

async function callActivate(input: ActivateInput): Promise<void> {
  await apiFetchUnsafe<unknown>('/authorization-server/v1/auth:activate', {
    method: 'POST',
    body: JSON.stringify({ email: input.email, otp: input.otp }),
  });
}

async function callResendOtp(input: ResendOtpInput): Promise<void> {
  await apiFetchUnsafe<unknown>('/authorization-server/v1/auth:resend-otp', {
    method: 'POST',
    body: JSON.stringify({ type: input.type, email: input.email }),
  });
}

async function callForgotPassword(input: { email: string }): Promise<void> {
  await apiFetchUnsafe<unknown>('/authorization-server/v1/auth:forgot-password', {
    method: 'POST',
    body: JSON.stringify({ email: input.email }),
  });
}

async function callVerifyForgotOtp(
  input: VerifyForgotOtpInput,
): Promise<{ reset_password_key: string }> {
  return apiFetchUnsafe<{ reset_password_key: string }>(
    '/authorization-server/v1/auth:verify-forgot-pass-otp',
    { method: 'POST', body: JSON.stringify({ email: input.email, otp: input.otp }) },
  );
}

async function callResetPassword(input: {
  resetPasswordKey: string;
  email: string;
  password: string;
  confirmPassword: string;
}): Promise<void> {
  await apiFetchUnsafe<unknown>('/authorization-server/v1/auth:reset-password', {
    method: 'POST',
    body: JSON.stringify({
      reset_password_key: input.resetPasswordKey,
      email: input.email,
      password: input.password,
      confirm_password: input.confirmPassword,
    }),
  });
}

export function useLoginMutation() {
  const auth = useAuthStore();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: callLogin,
    onSuccess(data) {
      auth.login({ accessToken: data.access_token, refreshToken: data.refresh_token });
      qc.invalidateQueries({ queryKey: ['currentUser'] });
    },
  });
}

export function useRegisterMutation() {
  return useMutation({
    mutationFn: async (input: RegisterInput) => {
      await callRegister(input);
    },
  });
}

export function useActivateMutation() {
  return useMutation({ mutationFn: callActivate });
}

export function useResendOtpMutation() {
  return useMutation({ mutationFn: callResendOtp });
}

export function useForgotPasswordMutation() {
  return useMutation({ mutationFn: callForgotPassword });
}

export function useVerifyForgotOtpMutation() {
  return useMutation({ mutationFn: callVerifyForgotOtp });
}

export function useResetPasswordMutation() {
  return useMutation({ mutationFn: callResetPassword });
}

export function useLogout() {
  const auth = useAuthStore();
  const qc = useQueryClient();
  return () => {
    auth.clear();
    qc.clear();
  };
}

export function useLogoutMutation() {
  const auth = useAuthStore();
  const qc = useQueryClient();
  const router = useRouter();
  return useMutation({
    mutationFn: async () => {
      const rt = auth.refreshToken;
      if (!rt) return;
      try {
        await fetch(`${BASE_URL}/authorization-server/v1/auth:logout`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${rt}` },
        });
      } catch {
        /* network failure — local clear still proceeds */
      }
    },
    onSettled: () => {
      auth.clear();
      qc.clear();
      router.replace('/login');
    },
  });
}

export function useLogoutAllMutation() {
  const auth = useAuthStore();
  const qc = useQueryClient();
  const router = useRouter();
  return useMutation({
    mutationFn: async () => {
      const at = auth.accessToken;
      if (!at) return;
      try {
        await fetch(`${BASE_URL}/authorization-server/v1/auth:logout-all`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${at}` },
        });
      } catch {
        /* network failure — local clear still proceeds */
      }
    },
    onSettled: () => {
      auth.clear();
      qc.clear();
      router.replace('/login');
    },
  });
}
