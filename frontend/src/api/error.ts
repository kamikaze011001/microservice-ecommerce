export type ApiErrorClass =
  | 'auth-required'
  | 'forbidden'
  | 'not-found'
  | 'not-activated'
  | 'validation'
  | 'server'
  | 'network';

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export function classify(err: ApiError): ApiErrorClass {
  if (err.status === 0) return 'network';
  if (err.status === 401) return 'auth-required';
  if (err.status === 403) return 'forbidden';
  if (err.status === 404) return 'not-found';
  if (err.status === 400 && /not activated/i.test(err.message)) return 'not-activated';
  if (err.status === 400 || err.status === 409 || err.status === 422) return 'validation';
  if (err.status >= 500) return 'server';
  return 'server';
}
