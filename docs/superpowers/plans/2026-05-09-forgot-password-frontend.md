# Forgot Password (Frontend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a 3-step `/forgot-password` flow on the Vue SPA that consumes the already-shipped `auth:forgot-password`, `auth:verify-forgot-pass-otp`, and `auth:reset-password` endpoints, plus a "Forgot password?" entry point on the login page and a post-success banner.

**Architecture:** Single route, single Vue component, three sub-templates selected by a `step: 1 | 2 | 3` ref. Email and `reset_password_key` live in component memory only — no `sessionStorage`, no extra routes. Each step has its own `useForm()` (vee-validate + zod) and its own mutation. Resend reuses the existing `useResendOtpMutation`. On success, redirect to `/login?reset=ok` and show a banner that clears on first keystroke.

**Tech Stack:** Vue 3 Composition API, vee-validate + `@vee-validate/zod`, zod, TanStack Query (`@tanstack/vue-query`), Pinia, Vue Router, vitest + `@testing-library/vue` + `happy-dom`, `apiFetchUnsafe` from `src/api/client.ts`.

---

## Reference: Backend contracts (already shipped, no changes)

All under `authorization-server`, all `PERMIT_ALL` at the gateway. Wire format is **snake_case** (server uses `@JsonNaming(SnakeCaseStrategy.class)`).

| Step | Method + Path | Request body | 200 response body |
|---|---|---|---|
| 1 | `POST /authorization-server/v1/auth:forgot-password` | `{ email }` | `{}` (sends OTP email) |
| 2 | `POST /authorization-server/v1/auth:verify-forgot-pass-otp` | `{ email, otp }` | `{ reset_password_key }` |
| 3 | `POST /authorization-server/v1/auth:reset-password` | `{ reset_password_key, email, password, confirm_password }` | `{}` |
| Resend | `POST /authorization-server/v1/auth:resend-otp` | `{ type: "forgot_password", email }` | `{}` |

OTP TTL is 3 minutes server-side. The `reset_password_key` is one-shot and short-lived.

## Reference: File map

**New**
- `frontend/src/pages/ForgotPasswordPage.vue` — 3-step component
- `frontend/tests/unit/pages/ForgotPasswordPage.spec.ts` — vitest spec

**Modified**
- `frontend/src/lib/zod-schemas.ts` — add 3 schemas
- `frontend/src/api/queries/auth.ts` — add 3 mutations
- `frontend/src/router/index.ts` — register `/forgot-password`
- `frontend/src/pages/LoginPage.vue` — add link + `?reset=ok` banner
- `frontend/tests/unit/pages/LoginPage.spec.ts` — add banner test

All commands below run from `frontend/` unless noted.

---

## Task 1: Add zod schemas

**Files:**
- Modify: `frontend/src/lib/zod-schemas.ts` (append below the existing `resendOtpSchema` block)

- [ ] **Step 1: Add the three schemas**

Append to `src/lib/zod-schemas.ts` (after the `resendOtpSchema` / `ResendOtpInput` block, before `addressSchema`):

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
    password: passwordSchema,
    confirmPassword: z.string(),
  })
  .refine((d) => d.password === d.confirmPassword, {
    path: ['confirmPassword'],
    message: 'Passwords do not match',
  });
export type ResetPasswordInput = z.infer<typeof resetPasswordSchema>;
```

- [ ] **Step 2: Typecheck**

Run from `frontend/`: `pnpm typecheck`
Expected: clean exit (no errors).

- [ ] **Step 3: Commit**

```bash
git add frontend/src/lib/zod-schemas.ts
git commit -m "feat(fe): add zod schemas for forgot-password flow"
```

---

## Task 2: Add the three mutations

**Files:**
- Modify: `frontend/src/api/queries/auth.ts`

- [ ] **Step 1: Update the type import**

Replace the existing import line in `src/api/queries/auth.ts`:

```ts
import type { LoginInput, RegisterInput, ActivateInput, ResendOtpInput } from '@/lib/zod-schemas';
```

with:

```ts
import type {
  LoginInput,
  RegisterInput,
  ActivateInput,
  ResendOtpInput,
  VerifyForgotOtpInput,
} from '@/lib/zod-schemas';
```

- [ ] **Step 2: Add the three call functions**

Append after the existing `callResendOtp` function in `src/api/queries/auth.ts`:

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
```

- [ ] **Step 3: Add the three exported hooks**

Append after the existing `useResendOtpMutation` export:

```ts
export function useForgotPasswordMutation() {
  return useMutation({ mutationFn: callForgotPassword });
}

export function useVerifyForgotOtpMutation() {
  return useMutation({ mutationFn: callVerifyForgotOtp });
}

export function useResetPasswordMutation() {
  return useMutation({ mutationFn: callResetPassword });
}
```

- [ ] **Step 4: Typecheck**

Run: `pnpm typecheck`
Expected: clean exit.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/api/queries/auth.ts
git commit -m "feat(fe): add forgot-password mutations to auth queries"
```

---

## Task 3: Scaffold `ForgotPasswordPage.vue` (route renders empty step 1)

This task creates the file structure and route so subsequent test-driven steps have something to mount. We write a smoke test for the route + step 1 marker before adding behavior.

**Files:**
- Create: `frontend/src/pages/ForgotPasswordPage.vue`
- Modify: `frontend/src/router/index.ts`
- Create: `frontend/tests/unit/pages/ForgotPasswordPage.spec.ts`

- [ ] **Step 1: Write the failing scaffold test**

Create `frontend/tests/unit/pages/ForgotPasswordPage.spec.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import ForgotPasswordPage from '@/pages/ForgotPasswordPage.vue';

const forgotMutateAsync = vi.fn();
const verifyMutateAsync = vi.fn();
const resetMutateAsync = vi.fn();
const resendMutateAsync = vi.fn();

vi.mock('@/api/queries/auth', () => ({
  useForgotPasswordMutation: () => ({
    mutateAsync: forgotMutateAsync,
    isPending: { value: false },
  }),
  useVerifyForgotOtpMutation: () => ({
    mutateAsync: verifyMutateAsync,
    isPending: { value: false },
  }),
  useResetPasswordMutation: () => ({
    mutateAsync: resetMutateAsync,
    isPending: { value: false },
  }),
  useResendOtpMutation: () => ({
    mutateAsync: resendMutateAsync,
    isPending: { value: false },
  }),
  useLoginMutation: vi.fn(),
  useRegisterMutation: vi.fn(),
  useActivateMutation: vi.fn(),
  useLogout: () => () => {},
}));

beforeEach(async () => {
  vi.useFakeTimers();
  setActivePinia(createPinia());
  forgotMutateAsync.mockReset();
  verifyMutateAsync.mockReset();
  resetMutateAsync.mockReset();
  resendMutateAsync.mockReset();
  await router.push('/forgot-password');
  await router.isReady();
});

afterEach(() => {
  vi.useRealTimers();
});

const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });

function mount() {
  return render(ForgotPasswordPage, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]],
    },
  });
}

describe('ForgotPasswordPage', () => {
  it('renders step 1 by default', () => {
    mount();
    expect(screen.getByText(/step 1 of 3/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/email/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /send code/i })).toBeInTheDocument();
  });
});

// Make the unused `user` import OK for now; later tasks reference it.
void user;
```

- [ ] **Step 2: Run the test, expect failure**

Run: `pnpm test -- tests/unit/pages/ForgotPasswordPage.spec.ts`
Expected: FAIL — module `@/pages/ForgotPasswordPage.vue` not found, or "Cannot find module".

- [ ] **Step 3: Create the page with step 1 only**

Create `frontend/src/pages/ForgotPasswordPage.vue`:

```vue
<script setup lang="ts">
import { computed, ref } from 'vue';
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { useRouter } from 'vue-router';
import { forgotPasswordSchema } from '@/lib/zod-schemas';
import { useForgotPasswordMutation } from '@/api/queries/auth';
import { BButton, BInput } from '@/components/primitives';

const router = useRouter();
void router; // wired in later steps

const step = ref<1 | 2 | 3>(1);
const email = ref('');
const resetPasswordKey = ref('');
void resetPasswordKey; // populated in step 2

const stepLabel = computed(() =>
  step.value === 1 ? 'ENTER EMAIL' : step.value === 2 ? 'ENTER CODE' : 'NEW PASSWORD',
);

// ── Step 1: email ────────────────────────────────────────────────────────
const forgot = useForgotPasswordMutation();
const step1 = useForm({
  validationSchema: toTypedSchema(forgotPasswordSchema),
  initialValues: { email: '' },
});
const [emailModel, emailAttrs] = step1.defineField('email');
const emailField = computed({
  get: () => emailModel.value ?? '',
  set: (v) => {
    emailModel.value = v;
  },
});

const onSubmitEmail = step1.handleSubmit(async (values) => {
  try {
    await forgot.mutateAsync({ email: values.email });
    email.value = values.email;
    step.value = 2;
  } catch (err) {
    const e = err as { message?: string };
    step1.setErrors({ email: e?.message ?? 'Could not send the code' });
  }
});

const pending1 = computed(() => forgot.isPending?.value === true);
</script>

<template>
  <main class="forgot">
    <h1>RESET PASSWORD</h1>
    <p class="forgot__progress">STEP {{ step }} OF 3 · {{ stepLabel }}</p>

    <form v-if="step === 1" novalidate class="forgot__form" @submit.prevent="onSubmitEmail">
      <BInput
        v-model="emailField"
        v-bind="emailAttrs"
        :error="step1.errors.value.email"
        label="Email"
        autocomplete="email"
      />
      <BButton type="submit" variant="spot" :disabled="pending1">
        {{ pending1 ? 'SENDING…' : 'SEND CODE' }}
      </BButton>
    </form>

    <p class="forgot__alt">
      Remember it? <RouterLink to="/login">BACK TO LOG IN</RouterLink>
    </p>
  </main>
</template>

<style scoped>
.forgot {
  max-width: 28rem;
  margin: 0 auto;
  padding: var(--space-6);
  font-family: var(--font-display);
}
.forgot h1 {
  font-size: 2rem;
  margin-bottom: var(--space-4);
}
.forgot__progress {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  color: var(--muted-ink);
  margin-bottom: var(--space-6);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.forgot__form {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
}
.forgot__alt {
  font-family: var(--font-body);
  font-size: 0.875rem;
  color: var(--muted-ink);
  margin-top: var(--space-4);
}
.forgot__alt a {
  color: var(--spot-ink);
  text-decoration: underline;
}

@media (max-width: 37.49rem) {
  .forgot {
    padding: var(--space-6) var(--space-4);
  }
  .forgot h1 {
    font-size: 1.75rem;
  }
}
</style>
```

- [ ] **Step 4: Register the route**

In `frontend/src/router/index.ts`, add the import alongside the other page imports:

```ts
import ForgotPasswordPage from '@/pages/ForgotPasswordPage.vue';
```

And add this entry to the `routes` array, immediately after the `/activate` line:

```ts
    { path: '/forgot-password', component: ForgotPasswordPage, meta: { guestOnly: true } },
```

- [ ] **Step 5: Run the test, expect pass**

Run: `pnpm test -- tests/unit/pages/ForgotPasswordPage.spec.ts`
Expected: PASS — 1 test, "renders step 1 by default".

- [ ] **Step 6: Commit**

```bash
git add frontend/src/pages/ForgotPasswordPage.vue \
        frontend/src/router/index.ts \
        frontend/tests/unit/pages/ForgotPasswordPage.spec.ts
git commit -m "feat(fe): scaffold /forgot-password route with step-1 form"
```

---

## Task 4: Step 1 behavior — email submit transitions to step 2

**Files:**
- Modify: `frontend/tests/unit/pages/ForgotPasswordPage.spec.ts`
- Modify: `frontend/src/pages/ForgotPasswordPage.vue`

- [ ] **Step 1: Add the failing test**

Append inside the `describe('ForgotPasswordPage', () => { ... })` block in `tests/unit/pages/ForgotPasswordPage.spec.ts` (and remove the `void user;` line at the bottom of the file since `user` is now used):

```ts
  it('step 1: submitting a valid email calls forgot mutation and moves to step 2', async () => {
    forgotMutateAsync.mockResolvedValueOnce(undefined);
    mount();
    await user.type(screen.getByLabelText(/email/i), 'son@example.com');
    await user.click(screen.getByRole('button', { name: /send code/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    expect(forgotMutateAsync).toHaveBeenCalledWith({ email: 'son@example.com' });
    await waitFor(() => expect(screen.getByText(/step 2 of 3/i)).toBeInTheDocument());
  });

  it('step 1: server error surfaces as inline email error', async () => {
    forgotMutateAsync.mockRejectedValueOnce(
      Object.assign(new Error('No account found'), { status: 404 }),
    );
    mount();
    await user.type(screen.getByLabelText(/email/i), 'nope@example.com');
    await user.click(screen.getByRole('button', { name: /send code/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() => expect(screen.getByText(/no account found/i)).toBeInTheDocument());
    expect(screen.getByText(/step 1 of 3/i)).toBeInTheDocument();
  });
```

Also, at the top of the file, expand the existing imports to add `waitFor` and `flushPromises`:

```ts
import { render, screen, waitFor } from '@testing-library/vue';
import { flushPromises } from '@vue/test-utils';
```

- [ ] **Step 2: Run the spec — first test should pass already, second should pass**

Run: `pnpm test -- tests/unit/pages/ForgotPasswordPage.spec.ts`
Expected: 3 PASS (the original "renders step 1 by default" already covered, and both new tests pass since the implementation in Task 3 already calls the mutation and moves to step 2 on success / setErrors on failure).

If anything fails, fix the implementation before continuing.

- [ ] **Step 3: Commit**

```bash
git add frontend/tests/unit/pages/ForgotPasswordPage.spec.ts
git commit -m "test(fe): forgot-password step 1 success and error paths"
```

---

## Task 5: Step 2 — OTP verify + resend with cooldown

**Files:**
- Modify: `frontend/tests/unit/pages/ForgotPasswordPage.spec.ts`
- Modify: `frontend/src/pages/ForgotPasswordPage.vue`

- [ ] **Step 1: Add the failing tests**

Append inside the `describe` block:

```ts
  async function advanceToStep2(emailValue = 'son@example.com') {
    forgotMutateAsync.mockResolvedValueOnce(undefined);
    mount();
    await user.type(screen.getByLabelText(/email/i), emailValue);
    await user.click(screen.getByRole('button', { name: /send code/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() => expect(screen.getByText(/step 2 of 3/i)).toBeInTheDocument());
  }

  it('step 2: submitting a valid OTP calls verify mutation and moves to step 3', async () => {
    verifyMutateAsync.mockResolvedValueOnce({ reset_password_key: 'rpk-abc' });
    await advanceToStep2();
    await user.type(screen.getByLabelText(/code/i), '123456');
    await user.click(screen.getByRole('button', { name: /^verify$/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    expect(verifyMutateAsync).toHaveBeenCalledWith({
      email: 'son@example.com',
      otp: '123456',
    });
    await waitFor(() => expect(screen.getByText(/step 3 of 3/i)).toBeInTheDocument());
  });

  it('step 2: invalid OTP surfaces inline error and clears the input', async () => {
    verifyMutateAsync.mockRejectedValueOnce(
      Object.assign(new Error('Invalid or expired code'), { status: 400 }),
    );
    await advanceToStep2();
    await user.type(screen.getByLabelText(/code/i), '999999');
    await user.click(screen.getByRole('button', { name: /^verify$/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() =>
      expect(screen.getByText(/invalid or expired code/i)).toBeInTheDocument(),
    );
    expect((screen.getByLabelText(/code/i) as HTMLInputElement).value).toBe('');
    expect(screen.getByText(/step 2 of 3/i)).toBeInTheDocument();
  });

  it('step 2: resend triggers mutation and disables button for 30s', async () => {
    resendMutateAsync.mockResolvedValueOnce(undefined);
    await advanceToStep2();
    const btn = screen.getByRole('button', { name: /resend code/i });
    await user.click(btn);
    vi.advanceTimersByTime(10);
    await flushPromises();
    expect(resendMutateAsync).toHaveBeenCalledWith({
      type: 'forgot_password',
      email: 'son@example.com',
    });
    expect(btn).toBeDisabled();
    expect(btn.textContent ?? '').toMatch(/30/);
    vi.advanceTimersByTime(30_000);
    await flushPromises();
    expect(btn).not.toBeDisabled();
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test -- tests/unit/pages/ForgotPasswordPage.spec.ts`
Expected: 3 new tests FAIL (no Step 2 UI yet — `getByLabelText(/code/i)` and `getByRole('button', { name: /verify/i })` will throw "unable to find element").

- [ ] **Step 3: Implement step 2 in `ForgotPasswordPage.vue`**

In `<script setup>`, expand the imports and add the step 2 wiring. Replace the existing `<script setup>` block with this complete version:

```vue
<script setup lang="ts">
import { computed, onBeforeUnmount, ref } from 'vue';
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { useRouter } from 'vue-router';
import {
  forgotPasswordSchema,
  verifyForgotOtpSchema,
} from '@/lib/zod-schemas';
import {
  useForgotPasswordMutation,
  useVerifyForgotOtpMutation,
  useResendOtpMutation,
} from '@/api/queries/auth';
import { BButton, BInput } from '@/components/primitives';

const router = useRouter();
void router; // wired in step 3

const step = ref<1 | 2 | 3>(1);
const email = ref('');
const resetPasswordKey = ref('');
void resetPasswordKey; // populated below

const stepLabel = computed(() =>
  step.value === 1 ? 'ENTER EMAIL' : step.value === 2 ? 'ENTER CODE' : 'NEW PASSWORD',
);

// ── Step 1: email ────────────────────────────────────────────────────────
const forgot = useForgotPasswordMutation();
const step1 = useForm({
  validationSchema: toTypedSchema(forgotPasswordSchema),
  initialValues: { email: '' },
});
const [emailModel, emailAttrs] = step1.defineField('email');
const emailField = computed({
  get: () => emailModel.value ?? '',
  set: (v) => {
    emailModel.value = v;
  },
});
const onSubmitEmail = step1.handleSubmit(async (values) => {
  try {
    await forgot.mutateAsync({ email: values.email });
    email.value = values.email;
    step.value = 2;
  } catch (err) {
    const e = err as { message?: string };
    step1.setErrors({ email: e?.message ?? 'Could not send the code' });
  }
});
const pending1 = computed(() => forgot.isPending?.value === true);

// ── Step 2: OTP + resend ─────────────────────────────────────────────────
const verify = useVerifyForgotOtpMutation();
const resend = useResendOtpMutation();
const step2 = useForm({
  validationSchema: toTypedSchema(verifyForgotOtpSchema),
  initialValues: { email: '', otp: '' },
});
const [otpModel, otpAttrs] = step2.defineField('otp');
const otpField = computed({
  get: () => otpModel.value ?? '',
  set: (v) => {
    otpModel.value = v;
  },
});

const onSubmitOtp = step2.handleSubmit(async (values) => {
  try {
    const data = await verify.mutateAsync({ email: email.value, otp: values.otp });
    resetPasswordKey.value = data.reset_password_key;
    step.value = 3;
  } catch (err) {
    const e = err as { message?: string };
    step2.setErrors({ otp: e?.message ?? 'Invalid or expired code' });
    otpField.value = '';
  }
});
const pending2 = computed(() => verify.isPending?.value === true);

const resendCooldown = ref(0);
let resendTimer: ReturnType<typeof setInterval> | null = null;

function startCooldown() {
  resendCooldown.value = 30;
  if (resendTimer) clearInterval(resendTimer);
  resendTimer = setInterval(() => {
    resendCooldown.value -= 1;
    if (resendCooldown.value <= 0 && resendTimer) {
      clearInterval(resendTimer);
      resendTimer = null;
    }
  }, 1000);
}

onBeforeUnmount(() => {
  if (resendTimer) clearInterval(resendTimer);
});

async function onResend() {
  if (resendCooldown.value > 0) return;
  if (!email.value) return;
  try {
    await resend.mutateAsync({ type: 'forgot_password', email: email.value });
    startCooldown();
  } catch (err) {
    const e = err as { message?: string };
    step2.setErrors({ otp: e?.message ?? 'Resend failed' });
  }
}

// expose step1.errors / step2.errors to template
defineExpose({});
</script>
```

Then update the `<template>` to add the step 2 form. Replace the entire `<template>` block with:

```vue
<template>
  <main class="forgot">
    <h1>RESET PASSWORD</h1>
    <p class="forgot__progress">STEP {{ step }} OF 3 · {{ stepLabel }}</p>

    <form v-if="step === 1" novalidate class="forgot__form" @submit.prevent="onSubmitEmail">
      <BInput
        v-model="emailField"
        v-bind="emailAttrs"
        :error="step1.errors.value.email"
        label="Email"
        autocomplete="email"
      />
      <BButton type="submit" variant="spot" :disabled="pending1">
        {{ pending1 ? 'SENDING…' : 'SEND CODE' }}
      </BButton>
    </form>

    <form v-if="step === 2" novalidate class="forgot__form" @submit.prevent="onSubmitOtp">
      <p class="forgot__hint">We sent a code to <strong>{{ email }}</strong>.</p>
      <BInput
        v-model="otpField"
        v-bind="otpAttrs"
        :error="step2.errors.value.otp"
        label="Code"
        autocomplete="one-time-code"
        inputmode="numeric"
      />
      <BButton type="submit" variant="spot" :disabled="pending2">
        {{ pending2 ? 'VERIFYING…' : 'VERIFY' }}
      </BButton>
      <BButton type="button" variant="ghost" :disabled="resendCooldown > 0" @click="onResend">
        {{ resendCooldown > 0 ? `RESEND IN ${resendCooldown}s` : 'RESEND CODE' }}
      </BButton>
    </form>

    <p class="forgot__alt">
      Remember it? <RouterLink to="/login">BACK TO LOG IN</RouterLink>
    </p>
  </main>
</template>
```

And add this rule inside the existing `<style scoped>` block (anywhere before the media query):

```css
.forgot__hint {
  font-family: var(--font-body);
  font-size: 0.875rem;
  color: var(--muted-ink);
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `pnpm test -- tests/unit/pages/ForgotPasswordPage.spec.ts`
Expected: PASS — all 5 tests now green (1 from Task 3, 2 from Task 4, 3 from Task 5).

If `step1.errors.value.email` causes a TS or vee-validate complaint, fall back to `step1.errors.value['email']` or rename the bindings to avoid the `.value` chain. (vee-validate's `errors` is a reactive object — `step1.errors` exposes a reactive `Ref` on `useForm()`; in templates Vue auto-unwraps refs, so `step1.errors.email` may be sufficient. If so, adjust the template accordingly.)

- [ ] **Step 5: Commit**

```bash
git add frontend/src/pages/ForgotPasswordPage.vue \
        frontend/tests/unit/pages/ForgotPasswordPage.spec.ts
git commit -m "feat(fe): forgot-password step 2 (OTP verify + resend cooldown)"
```

---

## Task 6: Step 3 — new password + redirect to /login?reset=ok

**Files:**
- Modify: `frontend/tests/unit/pages/ForgotPasswordPage.spec.ts`
- Modify: `frontend/src/pages/ForgotPasswordPage.vue`

- [ ] **Step 1: Add the failing tests**

Append inside the `describe` block:

```ts
  async function advanceToStep3() {
    verifyMutateAsync.mockResolvedValueOnce({ reset_password_key: 'rpk-abc' });
    await advanceToStep2();
    await user.type(screen.getByLabelText(/code/i), '123456');
    await user.click(screen.getByRole('button', { name: /^verify$/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() => expect(screen.getByText(/step 3 of 3/i)).toBeInTheDocument());
  }

  it('step 3: submitting matching password calls reset and redirects to /login?reset=ok', async () => {
    resetMutateAsync.mockResolvedValueOnce(undefined);
    await advanceToStep3();
    await user.type(screen.getByLabelText(/^new password$/i), 'NewAa1!');
    await user.type(screen.getByLabelText(/confirm password/i), 'NewAa1!');
    await user.click(screen.getByRole('button', { name: /^update password$/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    expect(resetMutateAsync).toHaveBeenCalledWith({
      resetPasswordKey: 'rpk-abc',
      email: 'son@example.com',
      password: 'NewAa1!',
      confirmPassword: 'NewAa1!',
    });
    await waitFor(() => expect(router.currentRoute.value.path).toBe('/login'));
    expect(router.currentRoute.value.query.reset).toBe('ok');
  });

  it('step 3: mismatched passwords block submit (no mutation call)', async () => {
    await advanceToStep3();
    await user.type(screen.getByLabelText(/^new password$/i), 'NewAa1!');
    await user.type(screen.getByLabelText(/confirm password/i), 'OtherAa1!');
    await user.click(screen.getByRole('button', { name: /^update password$/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() => expect(screen.getByText(/passwords do not match/i)).toBeInTheDocument());
    expect(resetMutateAsync).not.toHaveBeenCalled();
  });

  it('step 3: expired reset key surfaces "Start over" affordance that returns to step 1', async () => {
    resetMutateAsync.mockRejectedValueOnce(
      Object.assign(new Error('Reset link expired. Start over.'), { status: 400 }),
    );
    await advanceToStep3();
    await user.type(screen.getByLabelText(/^new password$/i), 'NewAa1!');
    await user.type(screen.getByLabelText(/confirm password/i), 'NewAa1!');
    await user.click(screen.getByRole('button', { name: /^update password$/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() =>
      expect(screen.getByText(/reset link expired/i)).toBeInTheDocument(),
    );
    const startOver = screen.getByRole('button', { name: /start over/i });
    await user.click(startOver);
    await waitFor(() => expect(screen.getByText(/step 1 of 3/i)).toBeInTheDocument());
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test -- tests/unit/pages/ForgotPasswordPage.spec.ts`
Expected: 3 new tests FAIL (no step-3 form yet).

- [ ] **Step 3: Implement step 3**

In `ForgotPasswordPage.vue`'s `<script setup>` block, add the imports for the new schema and mutation:

```ts
import {
  forgotPasswordSchema,
  verifyForgotOtpSchema,
  resetPasswordSchema,
} from '@/lib/zod-schemas';
import {
  useForgotPasswordMutation,
  useVerifyForgotOtpMutation,
  useResendOtpMutation,
  useResetPasswordMutation,
} from '@/api/queries/auth';
```

Remove the `void router;` line (we now use it). Then append the step 3 wiring after the step 2 block (after `onResend`):

```ts
// ── Step 3: new password ─────────────────────────────────────────────────
const reset = useResetPasswordMutation();
const step3 = useForm({
  validationSchema: toTypedSchema(resetPasswordSchema),
  initialValues: { password: '', confirmPassword: '' },
});
const [pwModel, pwAttrs] = step3.defineField('password');
const [confirmModel, confirmAttrs] = step3.defineField('confirmPassword');
const passwordField = computed({
  get: () => pwModel.value ?? '',
  set: (v) => {
    pwModel.value = v;
  },
});
const confirmField = computed({
  get: () => confirmModel.value ?? '',
  set: (v) => {
    confirmModel.value = v;
  },
});

const onSubmitReset = step3.handleSubmit(async (values) => {
  try {
    await reset.mutateAsync({
      resetPasswordKey: resetPasswordKey.value,
      email: email.value,
      password: values.password,
      confirmPassword: values.confirmPassword,
    });
    await router.push({ path: '/login', query: { reset: 'ok' } });
  } catch (err) {
    const e = err as { message?: string };
    step3.setErrors({
      confirmPassword: e?.message ?? 'Reset failed. Try starting over.',
    });
  }
});
const pending3 = computed(() => reset.isPending?.value === true);

function startOver() {
  step3.resetForm();
  step2.resetForm();
  step1.resetForm();
  email.value = '';
  resetPasswordKey.value = '';
  step.value = 1;
}
```

Also remove the `void resetPasswordKey;` line since we now use it.

In the `<template>`, append the step 3 form after the step 2 form:

```vue
    <form v-if="step === 3" novalidate class="forgot__form" @submit.prevent="onSubmitReset">
      <BInput
        v-model="passwordField"
        v-bind="pwAttrs"
        :error="step3.errors.value.password"
        type="password"
        label="New password"
        autocomplete="new-password"
      />
      <BInput
        v-model="confirmField"
        v-bind="confirmAttrs"
        :error="step3.errors.value.confirmPassword"
        type="password"
        label="Confirm password"
        autocomplete="new-password"
      />
      <BButton type="submit" variant="spot" :disabled="pending3">
        {{ pending3 ? 'UPDATING…' : 'UPDATE PASSWORD' }}
      </BButton>
      <BButton type="button" variant="ghost" @click="startOver">START OVER</BButton>
    </form>
```

- [ ] **Step 4: Run tests, expect pass**

Run: `pnpm test -- tests/unit/pages/ForgotPasswordPage.spec.ts`
Expected: PASS — 8 tests total, all green.

If the `step3` "Start over" test conflicts with the always-visible "Start over" button (because the test uses `getByRole('button', { name: /start over/i })` which would match in step 3 even before the error), that's fine — the assertion is that clicking it returns to step 1. The test should still pass.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/pages/ForgotPasswordPage.vue \
        frontend/tests/unit/pages/ForgotPasswordPage.spec.ts
git commit -m "feat(fe): forgot-password step 3 (reset + redirect to /login)"
```

---

## Task 7: Login page — "Forgot password?" link + ?reset=ok banner

**Files:**
- Modify: `frontend/src/pages/LoginPage.vue`
- Modify: `frontend/tests/unit/pages/LoginPage.spec.ts`

- [ ] **Step 1: Write failing tests**

Append inside the `describe('LoginPage', () => { ... })` block in `tests/unit/pages/LoginPage.spec.ts`:

```ts
  it('shows "Forgot password?" link pointing to /forgot-password', () => {
    mount();
    const link = screen.getByRole('link', { name: /forgot password/i });
    expect(link.getAttribute('href')).toBe('/forgot-password');
  });

  it('shows reset banner when ?reset=ok is present, and hides it on first keystroke', async () => {
    await router.push('/login?reset=ok');
    await router.isReady();
    mount();
    expect(screen.getByText(/password updated/i)).toBeInTheDocument();
    await user.type(screen.getByLabelText(/username/i), 's');
    expect(screen.queryByText(/password updated/i)).toBeNull();
  });
```

- [ ] **Step 2: Run tests, expect failure**

Run: `pnpm test -- tests/unit/pages/LoginPage.spec.ts`
Expected: 2 new tests FAIL — link not found, banner text not found.

- [ ] **Step 3: Update `LoginPage.vue`**

In `frontend/src/pages/LoginPage.vue`, in `<script setup>` add a `showResetSuccess` ref and gate it on the route query. After the existing `notActivated` ref:

```ts
const showResetSuccess = ref(route.query.reset === 'ok');
```

Modify the existing `username` and `password` computed setters so that the first keystroke clears the banner. Replace the existing `username` and `password` computed blocks with:

```ts
const username = computed({
  get: () => usernameModel.value ?? '',
  set: (v) => {
    usernameModel.value = v;
    if (showResetSuccess.value) showResetSuccess.value = false;
  },
});
const password = computed({
  get: () => passwordModel.value ?? '',
  set: (v) => {
    passwordModel.value = v;
    if (showResetSuccess.value) showResetSuccess.value = false;
  },
});
```

In the `<template>`, add the banner above the form (right after the `<h1>LOG IN</h1>` line):

```vue
    <p v-if="showResetSuccess" class="login__alt login__alt--ok" role="status">
      Password updated. Sign in with your new password.
    </p>
```

And inside the existing `.login__alt` paragraph, append the forgot-password link (next to the existing register link):

```vue
    <p class="login__alt">No account? <RouterLink to="/register">REGISTER</RouterLink></p>
    <p class="login__alt"><RouterLink to="/forgot-password">FORGOT PASSWORD?</RouterLink></p>
```

Add the `--ok` modifier to the `<style scoped>` block (anywhere after the existing `.login__alt` rule):

```css
.login__alt--ok {
  color: var(--ink);
  background: var(--paper-tint, #efe);
  border: var(--border-thin);
  padding: var(--space-2) var(--space-3);
  margin-bottom: var(--space-4);
}
```

(`--paper-tint` may not exist in the token set; that's fine — the fallback `#efe` covers it. Adjust to `var(--success-bg, #efe)` if a closer token name exists in `src/styles/`.)

- [ ] **Step 4: Run tests, expect pass**

Run: `pnpm test -- tests/unit/pages/LoginPage.spec.ts`
Expected: PASS — all original LoginPage tests + 2 new ones.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/pages/LoginPage.vue \
        frontend/tests/unit/pages/LoginPage.spec.ts
git commit -m "feat(fe): forgot-password link + reset-success banner on login"
```

---

## Task 8: Final QA — typecheck, lint, full test suite

**Files:** none (verification only)

- [ ] **Step 1: Typecheck**

Run from `frontend/`: `pnpm typecheck`
Expected: clean exit.

If any errors: fix them inline (most likely candidates: a missing `.value` on a `Ref<>`, or an `errors.value.<field>` access pattern that vee-validate doesn't expose — see Task 5 Step 4 fallback).

- [ ] **Step 2: Lint**

Run: `pnpm lint`
Expected: clean exit.

If errors: fix them inline. Most likely: unused imports, the `void X;` placeholders that should now be removed.

- [ ] **Step 3: Run the full test suite**

Run: `pnpm test`
Expected: all tests pass — including the new `ForgotPasswordPage.spec.ts` (8 tests) and the augmented `LoginPage.spec.ts` (original 4 + 2 new).

If unrelated tests fail, investigate; do not silently skip.

- [ ] **Step 4: Manual smoke (optional but recommended)**

If the local stack is running (`make up`), spin up the frontend and walk the flow:

```bash
cd frontend && pnpm dev
```

Then in a browser:
1. Open `/login`, click "FORGOT PASSWORD?" → arrives at `/forgot-password` step 1.
2. Submit a registered email → step 2 renders, hint shows the email.
3. Trigger resend → button disables for 30s, network panel shows `auth:resend-otp` with `type=forgot_password`.
4. Enter the OTP from the inbox → step 3 renders.
5. Enter a valid password matching `@ValidPassword` (e.g. `NewAa1!`) and matching confirm → redirects to `/login?reset=ok`, banner appears.
6. Type any character into the username field → banner disappears.
7. Log in with the new password → succeeds.

Note in the PR description if any step deviated.

- [ ] **Step 5: Final commit (only if anything was fixed during QA)**

```bash
git add -p
git commit -m "chore(fe): typecheck/lint cleanup for forgot-password"
```

If nothing needed fixing, skip.

---

## Self-Review Checklist (run before declaring done)

- [ ] Spec coverage:
  - § 1 user flow → Tasks 3–6
  - § 2 file changes → all 8 tasks combined cover the file map exactly
  - § 3 zod schemas → Task 1
  - § 4 mutations → Task 2
  - § 5 page structure → Tasks 3 (scaffold), 5 (step 2), 6 (step 3)
  - § 6 error handling → step 1 server error (Task 4), wrong OTP (Task 5), expired key + Start over (Task 6), password mismatch (Task 6 client-side)
  - § 7 LoginPage banner → Task 7
  - § 8 tests — all 6 design cases mapped:
    - happy path → Task 6 reset+redirect test (full path covered by `advanceToStep3` chain)
    - step 1 error → Task 4
    - step 2 error → Task 5
    - resend → Task 5
    - password mismatch → Task 6
    - expired key → Task 6
- [ ] No placeholders. Every step has either complete code or an exact command + expected output. No "TBD", no "similar to above", no "add error handling".
- [ ] Type / name consistency: `resetPasswordKey` (camelCase in TS) ↔ `reset_password_key` (snake_case on the wire) — translated explicitly in `callResetPassword` and `callVerifyForgotOtp`. `forgot_password` (resend type) matches the existing `resendOtpSchema` enum and backend `OTPType.FORGOT_PASSWORD`. Hook names: `useForgotPasswordMutation` / `useVerifyForgotOtpMutation` / `useResetPasswordMutation` consistent across Tasks 2, 3, 5, 6.

If anything is missing, add a follow-up task before handoff.
