import { ApiError } from '@/api/error';
import { useToast } from '@/composables/useToast';

export function useApiError() {
  const toast = useToast();

  const toApiError = (e: unknown): ApiError | null => (e instanceof ApiError ? e : null);

  const fieldErrors = (e: unknown): Record<string, string> => toApiError(e)?.errors ?? {};

  const notify = (e: unknown, fallback = 'Something went wrong. Please try again.') => {
    const err = toApiError(e);
    // useToast's error(title, body?) treats the first arg as a short label and the
    // second as detail — match every other call site by keeping a terse title and
    // surfacing the real backend message (err.message) as the body.
    toast.error('Error', err?.message || fallback);
  };

  return { toApiError, fieldErrors, notify };
}
