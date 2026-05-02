import { describe, it, expect } from 'vitest';
import { passwordSchema, loginSchema, registerSchema } from '@/lib/zod-schemas';

describe('passwordSchema (matches backend @ValidPassword)', () => {
  it.each([
    ['Aa1!aa', true],
    ['Abcdef1!', true],
    ['short', false],
    ['nouppercase1!', false],
    ['NOLOWERCASE1!', false],
    ['NoDigits!!', false],
    ['NoSpecial1A', false],
    ['Has space 1!', false],
  ])('rule for %s → ok=%s', (value, ok) => {
    expect(passwordSchema.safeParse(value).success).toBe(ok);
  });
});

describe('loginSchema', () => {
  it('requires username and password', () => {
    expect(loginSchema.safeParse({ username: '', password: '' }).success).toBe(false);
    expect(loginSchema.safeParse({ username: 'son', password: 'x' }).success).toBe(true);
  });
});

describe('registerSchema', () => {
  it('rejects mismatched confirm', () => {
    const r = registerSchema.safeParse({
      username: 'son',
      email: 'son@example.com',
      password: 'Aa1!aa',
      confirmPassword: 'different',
    });
    expect(r.success).toBe(false);
  });

  it('accepts a clean payload', () => {
    const r = registerSchema.safeParse({
      username: 'son',
      email: 'son@example.com',
      password: 'Aa1!aa',
      confirmPassword: 'Aa1!aa',
    });
    expect(r.success).toBe(true);
  });
});
