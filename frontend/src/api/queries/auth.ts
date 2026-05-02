import { useMutation, useQueryClient } from '@tanstack/vue-query';
import { apiFetch } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import type { LoginInput, RegisterInput, ActivateInput, ResendOtpInput } from '@/lib/zod-schemas';

interface LoginResponseData {
  access_token: string;
  refresh_token: string;
}

async function callLogin(input: LoginInput): Promise<LoginResponseData> {
  return apiFetch<LoginResponseData>('/authorization-server/v1/auth:login', {
    method: 'POST',
    body: JSON.stringify({ username: input.username, password: input.password }),
  });
}

async function callRegister(input: Omit<RegisterInput, 'confirmPassword'>): Promise<void> {
  await apiFetch<unknown>('/authorization-server/v1/auth:register', {
    method: 'POST',
    body: JSON.stringify({
      username: input.username,
      email: input.email,
      password: input.password,
    }),
  });
}

async function callActivate(input: ActivateInput): Promise<void> {
  await apiFetch<unknown>('/authorization-server/v1/auth:activate', {
    method: 'POST',
    body: JSON.stringify({ email: input.email, otp: input.otp }),
  });
}

async function callResendOtp(input: ResendOtpInput): Promise<void> {
  await apiFetch<unknown>('/authorization-server/v1/auth:resend-otp', {
    method: 'POST',
    body: JSON.stringify({ type: input.type, email: input.email }),
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

export function useLogout() {
  const auth = useAuthStore();
  const qc = useQueryClient();
  return () => {
    auth.clear();
    qc.clear();
  };
}
