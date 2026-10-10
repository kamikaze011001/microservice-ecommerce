import { describe, expect, it } from 'vitest';
import { resolveApiBaseUrl, UNSET } from '@/api/baseUrl';

describe('resolveApiBaseUrl', () => {
  it('prefers the runtime value — one image, any environment', () => {
    expect(
      resolveApiBaseUrl('http://api.preview-x.microecom.local', 'http://api.microecom.local'),
    ).toBe('http://api.preview-x.microecom.local');
  });

  it('falls back to the build-time value when the container sets nothing', () => {
    expect(resolveApiBaseUrl(UNSET, 'http://api.microecom.local')).toBe(
      'http://api.microecom.local',
    );
    expect(resolveApiBaseUrl(undefined, 'http://api.microecom.local')).toBe(
      'http://api.microecom.local',
    );
  });

  it('keeps an empty runtime value — "" means same-origin relative calls', () => {
    expect(resolveApiBaseUrl('', 'http://api.microecom.local')).toBe('');
  });

  it('keeps an empty build-time value (the AWS build) when there is no runtime value', () => {
    expect(resolveApiBaseUrl(UNSET, '')).toBe('');
  });

  it('defaults to the local gateway with neither', () => {
    expect(resolveApiBaseUrl(undefined, undefined)).toBe('http://localhost:6868');
  });
});
