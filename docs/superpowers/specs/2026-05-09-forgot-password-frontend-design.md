# Forgot Password — Frontend Design

**Status:** approved
**Branch:** `feat/refresh-token-tier-2`
**Author:** Son Anh
**Date:** 2026-05-09

## Goal

Wire up the existing backend forgot-password flow on the Vue frontend. The
authorization-server already exposes the three required endpoints; the SPA has
no UI for them yet.

This is a frontend-only change. No backend, no gateway role config, no Swagger
regen.

## Backend (already in place — for reference)

All three endpoints live under `authorization-server` and are already
`PERMIT_ALL` at the gateway via the `/authorization-server/v1/auth**` rule in
`docker/api_role.json`.

| Step | Endpoint | Request body | Response |
|---|---|---|---|
| 1 | `POST /authorization-server/v1/auth:forgot-password` | `{ email }` | 200 OK, sends OTP to email |
| 2 | `POST /authorization-server/v1/auth:verify-forgot-pass-otp` | `{ email, otp }` | 200 with `{ reset_password_key }` |
| 3 | `POST /authorization-server/v1/auth:reset-password` | `{ reset_password_key, email, password, confirm_password }` | 200 OK |

Resend reuses the existing `POST /authorization-server/v1/auth:resend-otp`
with `{ type: "forgot_password", email }`. The FE already has
`useResendOtpMutation` and the zod `resendOtpSchema` accepts that enum value.

OTP TTL is 3 minutes (`CacheConstant.Otp.FORGOT_PASSWORD_MINUTE`). The
`reset_password_key` is one-shot and short-lived; the password reset also
revokes all refresh-token families per `feat(auth): wipe refresh-token
families on password change/reset`.

## User flow

```
LoginPage
  └─ "Forgot password?" link  ──► /forgot-password
                                   │
                                   ├─ Step 1: Email          POST auth:forgot-password
                                   │     └─ on 200 ──► Step 2 (email locked)
                                   │
                                   ├─ Step 2: OTP            POST auth:verify-forgot-pass-otp
                                   │     • Resend (30s cooldown) → auth:resend-otp { type:"forgot_password" }
                                   │     └─ on 200 ──► Step 3 (carry reset_password_key in memory)
                                   │
                                   └─ Step 3: New password   POST auth:reset-password
                                         └─ on 200 ──► /login?reset=ok
                                                       LoginPage shows a one-line
                                                       "Password updated" banner that
                                                       clears on first keystroke.
```

**Flow shape (decision A).** Single route, single component, three sub-templates
selected by a `step: 1 | 2 | 3` ref. State (`email`, `resetPasswordKey`) is
component-local — refresh = restart from step 1. We deliberately do *not*
persist the reset key in `sessionStorage`; it is a one-shot credential and the
3-minute TTL means a single-sitting completion is the realistic case. This
mirrors `ActivatePage.vue` and the Stripe/GitHub pattern.

**Post-success (decision A).** Redirect to `/login?reset=ok`; a small banner
on `LoginPage` confirms the change and clears as soon as the user types. We
do *not* auto-login — the back-to-back issue/wipe ceremony of resetting and
then immediately logging in adds a failure mode for no real UX gain.

## File changes

**New**
- `frontend/src/pages/ForgotPasswordPage.vue` — the 3-step component
- `frontend/tests/unit/pages/ForgotPasswordPage.test.ts` — happy path + key error branches

**Modified**
- `frontend/src/lib/zod-schemas.ts` — three new schemas (below)
- `frontend/src/api/queries/auth.ts` — three new mutations (below)
- `frontend/src/router/index.ts` — register `/forgot-password` with `meta.guestOnly`
- `frontend/src/pages/LoginPage.vue` — "Forgot password?" link + `?reset=ok` banner

## Zod schemas (added to `src/lib/zod-schemas.ts`)

```ts
export const forgotPasswordSchema = z.object({
  email: emailSchema,
});
export type ForgotPasswordInput = z.infer<typeof forgotPasswordSchema>;

export const verifyForgotOtpSchema = z.object({
  email: emailSchema,
  otp: z.string().regex(/^\d{4,8}$/, 'Enter the code from your email'),
});
export type VerifyForgotOtpInput = z.infer<typeof verifyForgotOtpSchema>;

export const resetPasswordSchema = z
  .object({
    password: passwordSchema,        // reuses existing @ValidPassword regex
    confirmPassword: z.string(),
  })
  .refine((d) => d.password === d.confirmPassword, {
    path: ['confirmPassword'],
    message: 'Passwords do not match',
  });
export type ResetPasswordInput = z.infer<typeof resetPasswordSchema>;
```

`email` and `resetPasswordKey` are not part of the Step 3 form schema — they
are carried in component state from earlier steps and merged into the
mutation payload.

## Mutations (added to `src/api/queries/auth.ts`)

Follows the existing `apiFetchUnsafe` + hand-written shape pattern used by
`callLogin`/`callRegister`/`callActivate`. Wire format is **snake_case**.

```ts
async function callForgotPassword(input: { email: string }): Promise<void> {
  await apiFetchUnsafe<unknown>('/authorization-server/v1/auth:forgot-password', {
    method: 'POST',
    body: JSON.stringify({ email: input.email }),
  });
}

async function callVerifyForgotOtp(
  input: VerifyForgotOtpInput,
): Promise<{ reset_password_key: string }> {
  return apiFetchUnsafe<{ reset_password_key: string }>(
    '/authorization-server/v1/auth:verify-forgot-pass-otp',
    { method: 'POST', body: JSON.stringify({ email: input.email, otp: input.otp }) },
  );
}

async function callResetPassword(input: {
  resetPasswordKey: string;
  email: string;
  password: string;
  confirmPassword: string;
}): Promise<void> {
  await apiFetchUnsafe<unknown>('/authorization-server/v1/auth:reset-password', {
    method: 'POST',
    body: JSON.stringify({
      reset_password_key: input.resetPasswordKey,
      email: input.email,
      password: input.password,
      confirm_password: input.confirmPassword,
    }),
  });
}

export function useForgotPasswordMutation()  { return useMutation({ mutationFn: callForgotPassword }); }
export function useVerifyForgotOtpMutation() { return useMutation({ mutationFn: callVerifyForgotOtp }); }
export function useResetPasswordMutation()   { return useMutation({ mutationFn: callResetPassword }); }
```

Resend reuses the existing `useResendOtpMutation` with
`{ type: 'forgot_password', email }`.

## `ForgotPasswordPage.vue` structure

Three independent `useForm()` instances — one per step — each with its own
schema, errors, and submit handler. Cleaner than swapping schemas on a single
form.

```vue
<script setup lang="ts">
const step = ref<1 | 2 | 3>(1);
const email = ref('');               // captured at step 1, locked thereafter
const resetPasswordKey = ref('');    // captured at step 2, used at step 3

// Step 1 form (forgotPasswordSchema):
//   on success → email.value = values.email; step.value = 2
//
// Step 2 form (verifyForgotOtpSchema, email defaulted from state):
//   + resend cooldown (30s, mirrors ActivatePage.vue)
//   on success → resetPasswordKey.value = data.reset_password_key; step.value = 3
//
// Step 3 form (resetPasswordSchema):
//   on success → router.push('/login?reset=ok')
</script>

<template>
  <main class="forgot">
    <h1>RESET PASSWORD</h1>
    <p class="forgot__progress">STEP {{ step }} OF 3 · {{ stepLabel }}</p>

    <form v-if="step === 1" @submit.prevent="onSubmitEmail">  …  </form>
    <form v-if="step === 2" @submit.prevent="onSubmitOtp">    …  </form>
    <form v-if="step === 3" @submit.prevent="onSubmitReset">  …  </form>

    <p class="forgot__alt">
      Remember it? <RouterLink to="/login">BACK TO LOG IN</RouterLink>
    </p>
  </main>
</template>
```

Style: copy `.activate` styles from `ActivatePage.vue` wholesale (same width,
heading, gap, mobile breakpoint), rename to `.forgot`. Step 2's OTP input
reuses `autocomplete="one-time-code"` and `inputmode="numeric"` like Activate.

## Error handling

Field errors stay inside `setErrors({ field: msg })` on the relevant step's
form. Step transitions only happen on `mutateAsync` resolve; rejection keeps
the user on the current step with the message rendered next to the offending
field. Use the same `err as { code?: string; message?: string }` narrowing
already in `LoginPage`/`ActivatePage` — no new error helper.

| Step | Likely error | UX |
|---|---|---|
| 1 | Email not registered | `setErrors({ email: 'No account found for this email' })` |
| 1 | OTP cooldown ("otp is still in use") | server message under email field; fall back to "Please wait a moment before trying again" |
| 2 | Wrong / expired OTP | `setErrors({ otp: 'Invalid or expired code' })`; clear OTP input |
| 2 | Resend network failure | inline error under OTP field; cooldown does **not** start |
| 3 | Backend `@ValidPassword` rejects | `setErrors({ password: <server message> })` (client-side `passwordSchema` should catch first) |
| 3 | `reset_password_key` expired / wrong | `setErrors({ confirmPassword: 'Reset link expired. Start over.' })` + a "Start over" button that sets `step.value = 1` |

## `LoginPage` changes

Add to the existing `.login__alt` block:

```vue
<RouterLink to="/forgot-password">FORGOT PASSWORD?</RouterLink>
```

Plus a one-line banner driven by `route.query.reset === 'ok'`:

```ts
const showResetSuccess = ref(route.query.reset === 'ok');
// In the existing username/password computed setters, set
// showResetSuccess.value = false on the first keystroke.
```

```vue
<p v-if="showResetSuccess" class="login__alt login__alt--ok">
  Password updated. Sign in with your new password.
</p>
```

Add a `--ok` modifier with a green tint; no new component.

## Router

Append to the routes array in `src/router/index.ts`:

```ts
{ path: '/forgot-password', component: ForgotPasswordPage, meta: { guestOnly: true } },
```

The existing `guestOnly` guard in `router.beforeEach` redirects logged-in
users to `/`.

## Tests (`tests/unit/pages/ForgotPasswordPage.test.ts`)

Vitest + `@testing-library/vue` + `happy-dom`, mocking the three new
mutation hooks plus `useResendOtpMutation`. Cases:

1. **Happy path** — submits email → moves to step 2; submits OTP → moves to step 3; submits new password → calls `router.push('/login?reset=ok')`.
2. **Step 1 error** — email-not-found surfaces as a field error and stays on step 1.
3. **Step 2 error** — invalid OTP surfaces as a field error, clears the input, stays on step 2.
4. **Step 2 resend** — clicking resend calls `useResendOtpMutation` with `{ type: 'forgot_password', email }` and starts a 30-second cooldown; clicking again during cooldown is a no-op.
5. **Step 3 password mismatch** — zod refine catches it client-side, no mutation fires.
6. **Step 3 expired key** — server error surfaces a "Start over" affordance that returns to step 1 when clicked.

E2E is out of scope for this design — the existing register→activate E2E
pattern can be mirrored later as a follow-up if needed.

## Out of scope

- Backend changes (already complete).
- E2E tests (unit covers the state machine; follow-up if desired).
- Auto-login after reset (decision B was rejected).
- Multi-route flow + sessionStorage persistence (decision B was rejected).
- Storybook entries / design-system updates — this page reuses `BButton` and
  `BInput` primitives unchanged.
