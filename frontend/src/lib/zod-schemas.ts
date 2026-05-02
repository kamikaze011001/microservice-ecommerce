import { z } from 'zod';

export const emailSchema = z.string().email('Enter a valid email');

// Mirrors backend @ValidPassword:
// ^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[!@#$%^&*()])[A-Za-z\d!@#$%^&*()]{6,}$
export const passwordSchema = z
  .string()
  .regex(
    /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[!@#$%^&*()])[A-Za-z\d!@#$%^&*()]{6,}$/,
    'Min 6 chars with upper, lower, number, and special (!@#$%^&*())',
  );

export const loginSchema = z.object({
  username: z.string().min(1, 'Required'),
  password: z.string().min(1, 'Required'),
});
export type LoginInput = z.infer<typeof loginSchema>;

export const registerSchema = z
  .object({
    username: z.string().min(1, 'Required'),
    email: emailSchema,
    password: passwordSchema,
    confirmPassword: z.string(),
  })
  .refine((d) => d.password === d.confirmPassword, {
    path: ['confirmPassword'],
    message: 'Passwords do not match',
  });
export type RegisterInput = z.infer<typeof registerSchema>;

export const activateSchema = z.object({
  email: emailSchema,
  otp: z.string().regex(/^\d{4,8}$/, 'Enter the code from your email'),
});
export type ActivateInput = z.infer<typeof activateSchema>;

export const resendOtpSchema = z.object({
  type: z.literal('REGISTER'),
  email: emailSchema,
});
export type ResendOtpInput = z.infer<typeof resendOtpSchema>;
