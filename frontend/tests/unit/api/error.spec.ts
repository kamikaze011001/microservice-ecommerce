import { describe, it, expect } from 'vitest';
import { ApiError, classify } from '@/api/error';

describe('ApiError', () => {
  it('captures status, code, message', () => {
    const e = new ApiError(404, 'PRODUCT_NOT_FOUND', 'Not found');
    expect(e).toBeInstanceOf(Error);
    expect(e.status).toBe(404);
    expect(e.code).toBe('PRODUCT_NOT_FOUND');
    expect(e.message).toBe('Not found');
  });
});

describe('classify', () => {
  it.each([
    [401, 'auth-required'],
    [403, 'forbidden'],
    [404, 'not-found'],
    [400, 'validation'],
    [409, 'validation'],
    [422, 'validation'],
    [500, 'server'],
    [503, 'server'],
  ])('status %i → %s', (status, expected) => {
    expect(classify(new ApiError(status, '', ''))).toBe(expected);
  });

  it('returns network for status 0 (fetch threw)', () => {
    expect(classify(new ApiError(0, '', 'fetch failed'))).toBe('network');
  });
});
