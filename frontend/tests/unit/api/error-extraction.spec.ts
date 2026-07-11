import { describe, it, expect } from 'vitest';
import { extractError } from '@/api/client';

describe('extractError', () => {
  it('reads code, message and field errors from data', () => {
    const body = {
      status: 400,
      code: 'Bad Request',
      data: {
        code: 'validation.failed',
        message: 'One or more fields are invalid.',
        errors: { email: 'must be valid' },
      },
    };
    const e = extractError(400, body, 'Bad Request');
    expect(e.code).toBe('validation.failed');
    expect(e.message).toBe('One or more fields are invalid.');
    expect(e.errors).toEqual({ email: 'must be valid' });
  });

  it('falls back to statusText when data is absent', () => {
    const e = extractError(500, null, 'Server Error');
    expect(e.message).toBe('Server Error');
  });
});
