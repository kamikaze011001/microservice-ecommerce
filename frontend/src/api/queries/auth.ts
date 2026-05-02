import { useMutation, useQueryClient } from '@tanstack/vue-query';
import { apiFetch } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import type { LoginInput, RegisterInput } from '@/lib/zod-schemas';

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
  const auth = useAuthStore();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: RegisterInput) => {
      await callRegister(input);
      const tokens = await callLogin({
        username: input.username,
        password: input.password,
      });
      return tokens;
    },
    onSuccess(tokens) {
      auth.login({
        accessToken: tokens.access_token,
        refreshToken: tokens.refresh_token,
      });
      qc.invalidateQueries({ queryKey: ['currentUser'] });
    },
  });
}

export function useLogout() {
  const auth = useAuthStore();
  const qc = useQueryClient();
  return () => {
    auth.clear();
    qc.clear();
  };
}
