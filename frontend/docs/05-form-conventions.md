# Form conventions

VeeValidate + Zod. Schemas live in `src/lib/zod-schemas.ts` and are reused for **two** purposes:

1. Form validation (via `toTypedSchema`).
2. Runtime parsing of API responses in `src/api/queries/`.

If a schema only validates a form, you're missing half the value. Define once, use both places.

## Schema location and naming

`src/lib/zod-schemas.ts` exports schemas grouped by domain.

```ts
import { z } from 'zod';

// ─── Atoms (reused across forms + responses) ───
export const emailSchema = z.string().email('Enter a valid email');
export const passwordSchema = z
  .string()
  .min(8, 'Min 8 chars')
  .regex(/[A-Z]/, 'One uppercase')
  .regex(/[a-z]/, 'One lowercase')
  .regex(/\d/, 'One number');

// ─── Composites ───
export const loginSchema = z.object({
  email: emailSchema,
  password: z.string().min(1, 'Required'),
});
export type LoginInput = z.infer<typeof loginSchema>;

export const registerSchema = z
  .object({
    email: emailSchema,
    password: passwordSchema,
    confirmPassword: z.string(),
  })
  .refine((d) => d.password === d.confirmPassword, {
    path: ['confirmPassword'],
    message: 'Passwords do not match',
  });
export type RegisterInput = z.infer<typeof registerSchema>;

export const addressSchema = z.object({
  street: z.string().min(1, 'Required'),
  city: z.string().min(1, 'Required'),
  state: z.string().min(1, 'Required'),
  postcode: z.string().min(1, 'Required'),
  country: z.string().min(2, 'Required'),
  phone: z.string().min(7, 'Required'),
});
export type AddressInput = z.infer<typeof addressSchema>;
```

Password schema **must match** backend `@ValidPassword`. When the backend rule changes, this file changes too — that's the contract.

## Form component shape

```vue
<script setup lang="ts">
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { loginSchema } from '@/lib/zod-schemas';
import { useLoginMutation } from '@/api/queries/auth';

const { mutateAsync: login, isPending } = useLoginMutation();

const { handleSubmit, errors, defineField, setErrors } = useForm({
  validationSchema: toTypedSchema(loginSchema),
});

const [email, emailAttrs] = defineField('email');
const [password, passwordAttrs] = defineField('password');

const onSubmit = handleSubmit(async (values) => {
  try {
    await login(values);
    // navigation handled in the mutation onSuccess
  } catch (err) {
    // see "Server-error mapping" below
    if (err.code === 'INVALID_CREDENTIALS') {
      setErrors({ password: 'Wrong email or password' });
    }
  }
});
</script>

<template>
  <form novalidate @submit.prevent="onSubmit">
    <BInput v-model="email" v-bind="emailAttrs" :error="errors.email" label="Email" />
    <BInput
      v-model="password"
      v-bind="passwordAttrs"
      :error="errors.password"
      type="password"
      label="Password"
    />
    <BButton type="submit" variant="spot" :disabled="isPending">
      {{ isPending ? 'STAMPING…' : 'LOG IN' }}
    </BButton>
  </form>
</template>
```

## Server-error mapping

Server-side validation (`400`, `409`, `422`) maps to **inline form errors**, not toasts. The interceptor classifies these as `validation`. Forms catch the error and call `setErrors({ field: message })`.

| Backend code                            | Form field                   | Message                         |
| --------------------------------------- | ---------------------------- | ------------------------------- |
| `INVALID_CREDENTIALS`                   | `password`                   | "Wrong email or password"       |
| `EMAIL_TAKEN`                           | `email`                      | "Email already in use"          |
| `ORDER_ALREADY_CANCELED`                | (n/a — toast on Orders page) | "Already canceled — refreshed." |
| Generic `validation` with field details | per `field`                  | server-provided `message`       |

Add new mappings here when a form ships.

## Hard rules

- **Schema lives in `src/lib/zod-schemas.ts`.** Never inline a `z.object` inside a form component.
- **Server validation → inline error.** No toasts for validation failures. Toasts are for `network` / `server` only.
- **Submit button shows loading copy.** "STAMPING…" while pending, voice from [`08-copy-and-voice.md`](./08-copy-and-voice.md).
- **Forms have `novalidate` on the `<form>` tag.** Browser native validation fights with our errors.
- **Empty success state still navigates.** `mutation.onSuccess` does router.push, not the form.
