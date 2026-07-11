import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiError } from '@/api/error';

const { errorSpy } = vi.hoisted(() => ({ errorSpy: vi.fn() }));
vi.mock('@/composables/useToast', () => ({ useToast: () => ({ error: errorSpy }) }));
import { useApiError } from '@/composables/useApiError';

beforeEach(() => errorSpy.mockClear());

describe('useApiError', () => {
  it('extracts field errors from an ApiError', () => {
    const { fieldErrors } = useApiError();
    expect(fieldErrors(new ApiError(400, 'validation.failed', 'bad', { email: 'x' }))).toEqual({
      email: 'x',
    });
  });
  it('returns empty field map for non-ApiError', () => {
    const { fieldErrors } = useApiError();
    expect(fieldErrors(new Error('boom'))).toEqual({});
  });
  it('notifies with the backend message as the toast body, not the title', () => {
    const { notify } = useApiError();
    notify(new ApiError(500, 'common.internal_error', 'Server exploded'));
    expect(errorSpy).toHaveBeenCalledWith('Error', 'Server exploded');
  });
  it('notifies with the fallback body for a non-ApiError', () => {
    const { notify } = useApiError();
    notify(new Error('boom'), 'Custom fallback.');
    expect(errorSpy).toHaveBeenCalledWith('Error', 'Custom fallback.');
  });
});
