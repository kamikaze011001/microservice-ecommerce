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
  type: z.enum(['active_account', 'forgot_password']),
  email: emailSchema,
});
export type ResendOtpInput = z.infer<typeof resendOtpSchema>;

export const addressSchema = z.object({
  street: z.string().min(3, 'Street is required'),
  city: z.string().min(2, 'City is required'),
  state: z.string().min(2, 'State / region is required'),
  postcode: z.string().regex(/^\S{3,10}$/, 'Postcode looks invalid'),
  country: z.string().regex(/^[A-Z]{2}$/, 'Use ISO-2 country code (e.g. US)'),
  phone: z.string().regex(/^\+?[0-9\s\-()]{7,20}$/, 'Phone looks invalid'),
});

export type AddressInput = z.infer<typeof addressSchema>;

export const profileSchema = z.object({
  name: z.string().min(1, 'Name is required').max(100, 'Max 100 chars'),
  gender: z.enum(['MALE', 'FEMALE', 'OTHER']).nullable(),
  address: z.string().max(500, 'Max 500 chars').optional().or(z.literal('')),
});
export type ProfileInput = z.infer<typeof profileSchema>;

export const changePasswordSchema = z
  .object({
    oldPassword: z.string().min(1, 'Required'),
    newPassword: z.string().min(8, 'At least 8 chars'),
    confirmNewPassword: z.string(),
  })
  .refine((d) => d.newPassword === d.confirmNewPassword, {
    message: 'Passwords do not match',
    path: ['confirmNewPassword'],
  });
export type ChangePasswordInput = z.infer<typeof changePasswordSchema>;
