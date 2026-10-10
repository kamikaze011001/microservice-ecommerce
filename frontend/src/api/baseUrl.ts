// Where the SPA sends API calls. Resolved at RUNTIME first, so one image serves
// every environment: the container's Caddy answers /config.js with the env's
// API_BASE_URL (see ../../Caddyfile), loaded by index.html before the app.
// Without runtime config — `pnpm dev`, or a container without API_BASE_URL —
// the build-time VITE_API_BASE_URL applies, exactly as before.

declare global {
  interface Window {
    __APP_CONFIG__?: { apiBaseUrl?: string };
  }
}

// What Caddy writes when the container has no API_BASE_URL. A sentinel rather
// than an empty string, because "" is a real setting: the AWS build uses it for
// same-origin relative calls.
export const UNSET = '__build__';

export function resolveApiBaseUrl(
  runtime: string | undefined,
  buildTime: string | undefined,
): string {
  if (runtime !== undefined && runtime !== UNSET) return runtime;
  return buildTime ?? 'http://localhost:6868';
}

export const API_BASE_URL = resolveApiBaseUrl(
  typeof window === 'undefined' ? undefined : window.__APP_CONFIG__?.apiBaseUrl,
  import.meta.env.VITE_API_BASE_URL,
);
