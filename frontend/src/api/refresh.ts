import { useAuthStore } from '@/stores/auth';

const REFRESH_URL = `${import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:6868'}/authorization-server/v1/auth:refresh-token`;

let inflight: Promise<string | null> | null = null;

export async function refreshAccessToken(): Promise<string | null> {
  if (inflight) return inflight;
  inflight = doRefresh().finally(() => {
    inflight = null;
  });
  return inflight;
}

interface RefreshPayload {
  access_token: string;
  refresh_token: string;
}

interface BaseResponse<T> {
  status: number;
  code: string;
  message: string;
  data: T;
}

async function doRefresh(): Promise<string | null> {
  const auth = useAuthStore();
  const rt = auth.refreshToken;
  if (!rt) return null;

  try {
    const response = await fetch(REFRESH_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${rt}` },
    });
    if (!response.ok) {
      auth.clear();
      return null;
    }
    const body = (await response.json()) as BaseResponse<RefreshPayload>;
    const { access_token, refresh_token } = body.data;
    auth.login({ accessToken: access_token, refreshToken: refresh_token });
    return access_token;
  } catch {
    auth.clear();
    return null;
  }
}
