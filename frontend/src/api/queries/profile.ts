import type { MaybeRefOrGetter } from 'vue';
import { useQuery, useMutation, useQueryClient } from '@tanstack/vue-query';
import { apiFetchUnsafe } from '@/api/client';

export interface ProfileData {
  id: string;
  name: string;
  email: string;
  gender: 'MALE' | 'FEMALE' | 'OTHER' | null;
  address: string | null;
  avatar_url?: string | null;
}

const PROFILE_KEY = ['profile'] as const;

export function useProfileQuery(options?: { enabled?: MaybeRefOrGetter<boolean> }) {
  return useQuery({
    queryKey: PROFILE_KEY,
    queryFn: () =>
      apiFetchUnsafe<ProfileData>('/authorization-server/v1/users/self', { method: 'GET' }),
    enabled: options?.enabled,
  });
}

export function useUpdateProfileMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { name?: string; gender?: string | null; address?: string | null }) =>
      apiFetchUnsafe<ProfileData>('/authorization-server/v1/users/self', {
        method: 'PUT',
        body: JSON.stringify(body),
      }),
    onSuccess: () => qc.invalidateQueries({ queryKey: PROFILE_KEY }),
  });
}

export function useChangePasswordMutation() {
  return useMutation({
    mutationFn: (body: {
      old_password: string;
      new_password: string;
      confirm_new_password: string;
    }) =>
      apiFetchUnsafe<void>('/authorization-server/v1/users/self:update-password', {
        method: 'PATCH',
        body: JSON.stringify(body),
      }),
  });
}

export interface PresignResponse {
  upload_url: string;
  object_key: string;
  expires_at: string;
}

export function useAvatarPresignMutation() {
  return useMutation({
    mutationFn: (body: { content_type: string; size_bytes: number }) =>
      apiFetchUnsafe<PresignResponse>('/authorization-server/v1/users/self/avatar/presign', {
        method: 'POST',
        body: JSON.stringify(body),
      }),
  });
}

export function useAttachAvatarMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { object_key: string }) =>
      apiFetchUnsafe<{ avatar_url: string }>('/authorization-server/v1/users/self/avatar', {
        method: 'PUT',
        body: JSON.stringify(body),
      }),
    onSuccess: () => qc.invalidateQueries({ queryKey: PROFILE_KEY }),
  });
}
