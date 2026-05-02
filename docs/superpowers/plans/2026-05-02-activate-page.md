# ActivatePage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `/activate` page with OTP entry + resend; rewire register/login so the post-register → activate → login loop works end-to-end.

**Architecture:** Stateless flow — RegisterPage navigates to `/activate?email=…`. ActivatePage submits `{ email, otp }` to `/v1/auth:activate`, then routes to `/login`. Resend posts `{ type: "REGISTER", email }` with a 30s client-side countdown. LoginPage shows an inline "Activate it →" link when the API error classifier returns `'not-activated'`.

**Tech Stack:** Vue 3 + vee-validate + zod, Pinia, Vue Query, openapi-fetch, vitest + @testing-library/vue.

**Branch:** Continue on `frontend/phase-3-api-auth` (or whatever branch Phase 3 is open on). All changes are frontend-only.

**Backend constraints (already implemented, do not modify):**
- `POST /authorization-server/v1/auth:activate` body `{ email, otp }`, empty `BaseResponse` data on 200.
- `POST /authorization-server/v1/auth:resend-otp` body `{ type, email }` — `type` must be `"REGISTER"`.
- Login on an unactivated account returns HTTP **400** with `BaseResponse.message === "Your account is not activated"`. (Source: `AccountNotActivatedException` extends `BadRequestException`, set in `AuthFacadeServiceImpl#login`.)

---

## File Structure

| File | Responsibility |
|---|---|
| `frontend/src/lib/zod-schemas.ts` (modify) | Add `activateSchema`, `resendOtpSchema` (UI-only — payload typing). |
| `frontend/src/api/error.ts` (modify) | Add `'not-activated'` to `ApiErrorClass`; classifier returns it for HTTP 400 with "not activated" message. |
| `frontend/src/api/queries/auth.ts` (modify) | Add `useActivateMutation`, `useResendOtpMutation`. **Remove** auto-login from `useRegisterMutation`. |
| `frontend/src/pages/ActivatePage.vue` (create) | Form: email (read-only if `?email=`, editable otherwise), OTP, submit, resend with countdown. |
| `frontend/src/router/index.ts` (modify) | Register `{ path: '/activate', component: ActivatePage, meta: { guestOnly: true } }`. |
| `frontend/src/pages/RegisterPage.vue` (modify) | Post-register `router.push('/activate?email=…')`. Add footer link to `/activate`. |
| `frontend/src/pages/LoginPage.vue` (modify) | On `'not-activated'` classification, show inline "Activate it →" link. |
| `frontend/tests/unit/api/error.spec.ts` (modify) | Add classifier case for not-activated. |
| `frontend/tests/unit/pages/ActivatePage.spec.ts` (create) | Happy path, wrong OTP, resend countdown, prefilled email, cold-start. |
| `frontend/tests/unit/pages/RegisterPage.spec.ts` (modify) | Update happy path expectation: navigates to `/activate?email=…`, no auto-login. |
| `frontend/tests/unit/pages/LoginPage.spec.ts` (modify) | Add case: not-activated error renders activate link. |

---

### Task 1: Zod schemas for activate + resend payloads

**Files:**
- Modify: `frontend/src/lib/zod-schemas.ts`

- [ ] **Step 1: Append the schemas**

```ts
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
```

- [ ] **Step 2: Typecheck**

Run: `cd frontend && pnpm exec vue-tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/lib/zod-schemas.ts
git commit -m "feat(frontend): add zod schemas for activate + resend OTP"
```

---

### Task 2: ApiError classifier — `'not-activated'` kind

**Files:**
- Modify: `frontend/src/api/error.ts`
- Modify: `frontend/tests/unit/api/error.spec.ts`

- [ ] **Step 1: Add the failing test**

Append to `frontend/tests/unit/api/error.spec.ts`:

```ts
it('classifies HTTP 400 with "not activated" message as not-activated', () => {
  const err = new ApiError(400, 'Bad Request', 'Your account is not activated');
  expect(classify(err)).toBe('not-activated');
});

it('still classifies other HTTP 400s as validation', () => {
  const err = new ApiError(400, 'Bad Request', 'Email is required');
  expect(classify(err)).toBe('validation');
});
```

- [ ] **Step 2: Run the test — it fails**

Run: `cd frontend && pnpm exec vitest run tests/unit/api/error.spec.ts`
Expected: FAIL — `expected "validation" to be "not-activated"`.

- [ ] **Step 3: Update `error.ts`**

Replace the file contents:

```ts
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
```

- [ ] **Step 4: Run tests — pass**

Run: `cd frontend && pnpm exec vitest run tests/unit/api/error.spec.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/api/error.ts frontend/tests/unit/api/error.spec.ts
git commit -m "feat(frontend): classify backend 'not activated' as not-activated"
```

---

### Task 3: Activate + resend mutations; strip auto-login from register

**Files:**
- Modify: `frontend/src/api/queries/auth.ts`

This is the hinge: `useRegisterMutation` currently calls `callLogin` after `callRegister` (lines 41–61), which now fails because the backend gates login on activation. Strip the auto-login. RegisterPage will navigate to `/activate` instead.

- [ ] **Step 1: Replace `frontend/src/api/queries/auth.ts`**

```ts
import { useMutation, useQueryClient } from '@tanstack/vue-query';
import { apiFetch } from '@/api/client';
import { useAuthStore } from '@/stores/auth';
import type { LoginInput, RegisterInput, ActivateInput, ResendOtpInput } from '@/lib/zod-schemas';

interface LoginResponseData {
  access_token: string;
  refresh_token: string;
}

async function callLogin(input: LoginInput): Promise<LoginResponseData> {
  return apiFetch<LoginResponseData>('/authorization-server/v1/auth:login', {
    method: 'POST',
    body: JSON.stringify({ username: input.username, password: input.password }),
  });
}

async function callRegister(input: Omit<RegisterInput, 'confirmPassword'>): Promise<void> {
  await apiFetch<unknown>('/authorization-server/v1/auth:register', {
    method: 'POST',
    body: JSON.stringify({
      username: input.username,
      email: input.email,
      password: input.password,
    }),
  });
}

async function callActivate(input: ActivateInput): Promise<void> {
  await apiFetch<unknown>('/authorization-server/v1/auth:activate', {
    method: 'POST',
    body: JSON.stringify({ email: input.email, otp: input.otp }),
  });
}

async function callResendOtp(input: ResendOtpInput): Promise<void> {
  await apiFetch<unknown>('/authorization-server/v1/auth:resend-otp', {
    method: 'POST',
    body: JSON.stringify({ type: input.type, email: input.email }),
  });
}

export function useLoginMutation() {
  const auth = useAuthStore();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: callLogin,
    onSuccess(data) {
      auth.login({ accessToken: data.access_token, refreshToken: data.refresh_token });
      qc.invalidateQueries({ queryKey: ['currentUser'] });
    },
  });
}

export function useRegisterMutation() {
  return useMutation({
    mutationFn: async (input: RegisterInput) => {
      await callRegister(input);
    },
  });
}

export function useActivateMutation() {
  return useMutation({ mutationFn: callActivate });
}

export function useResendOtpMutation() {
  return useMutation({ mutationFn: callResendOtp });
}

export function useLogout() {
  const auth = useAuthStore();
  const qc = useQueryClient();
  return () => {
    auth.clear();
    qc.clear();
  };
}
```

- [ ] **Step 2: Typecheck**

Run: `cd frontend && pnpm exec vue-tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Run existing test suite (pre-commit signal)**

Run: `cd frontend && pnpm exec vitest run tests/unit`
Expected: RegisterPage happy-path test will FAIL because it asserts an auto-login token shape — that's expected. We fix it in Task 8. All other tests should pass.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/api/queries/auth.ts
git commit -m "feat(frontend): add activate/resend mutations; remove auto-login from register"
```

---

### Task 4: ActivatePage skeleton + happy-path test

**Files:**
- Create: `frontend/src/pages/ActivatePage.vue`
- Create: `frontend/tests/unit/pages/ActivatePage.spec.ts`

This task lays down the page with email-prefilled + OTP submit. Resend and cold-start come in later tasks.

- [ ] **Step 1: Write the failing happy-path test**

Create `frontend/tests/unit/pages/ActivatePage.spec.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/vue';
import { flushPromises } from '@vue/test-utils';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import ActivatePage from '@/pages/ActivatePage.vue';

const activateMutateAsync = vi.fn();
const resendMutateAsync = vi.fn();

vi.mock('@/api/queries/auth', () => ({
  useActivateMutation: () => ({ mutateAsync: activateMutateAsync, isPending: { value: false } }),
  useResendOtpMutation: () => ({ mutateAsync: resendMutateAsync, isPending: { value: false } }),
}));

beforeEach(async () => {
  vi.useFakeTimers();
  setActivePinia(createPinia());
  activateMutateAsync.mockReset();
  resendMutateAsync.mockReset();
  await router.push({ path: '/activate', query: { email: 'son@example.com' } });
  await router.isReady();
});

afterEach(() => {
  vi.useRealTimers();
});

const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });

function mount() {
  return render(ActivatePage, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]],
    },
  });
}

describe('ActivatePage', () => {
  it('happy path: submits email + otp and navigates to /login', async () => {
    activateMutateAsync.mockResolvedValueOnce(undefined);
    mount();
    expect((screen.getByLabelText(/email/i) as HTMLInputElement).value).toBe('son@example.com');
    await user.type(screen.getByLabelText(/code/i), '123456');
    await user.click(screen.getByRole('button', { name: /activate/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() =>
      expect(activateMutateAsync).toHaveBeenCalledWith({ email: 'son@example.com', otp: '123456' }),
    );
    await waitFor(() => expect(router.currentRoute.value.path).toBe('/login'));
  });
});
```

- [ ] **Step 2: Run the test — it fails**

Run: `cd frontend && pnpm exec vitest run tests/unit/pages/ActivatePage.spec.ts`
Expected: FAIL — `Cannot find module '@/pages/ActivatePage.vue'`.

- [ ] **Step 3: Create `frontend/src/pages/ActivatePage.vue`**

```vue
<script setup lang="ts">
import { computed, ref } from 'vue';
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { useRoute, useRouter } from 'vue-router';
import { activateSchema } from '@/lib/zod-schemas';
import { useActivateMutation, useResendOtpMutation } from '@/api/queries/auth';
import { BButton, BInput } from '@/components/primitives';

const route = useRoute();
const router = useRouter();
const activate = useActivateMutation();
const resend = useResendOtpMutation();

const queryEmail = typeof route.query.email === 'string' ? route.query.email : '';
const emailLocked = ref(queryEmail.length > 0);

const { handleSubmit, errors, defineField, setErrors } = useForm({
  validationSchema: toTypedSchema(activateSchema),
  initialValues: { email: queryEmail, otp: '' },
});

const [emailModel, emailAttrs] = defineField('email');
const [otpModel, otpAttrs] = defineField('otp');
const email = computed({
  get: () => emailModel.value ?? '',
  set: (v) => {
    emailModel.value = v;
  },
});
const otp = computed({
  get: () => otpModel.value ?? '',
  set: (v) => {
    otpModel.value = v;
  },
});

const pending = computed(() => activate.isPending?.value === true);

const onSubmit = handleSubmit(async (values) => {
  try {
    await activate.mutateAsync(values);
    await router.push('/login');
  } catch (err) {
    const e = err as { status?: number; message?: string };
    if (e?.message && /already (active|activated)/i.test(e.message)) {
      await router.push('/login');
      return;
    }
    setErrors({ otp: e?.message ?? 'Activation failed' });
    otp.value = '';
  }
});

async function onResend() {
  if (!email.value) {
    setErrors({ email: 'Enter your email first' });
    return;
  }
  try {
    await resend.mutateAsync({ type: 'REGISTER', email: email.value });
  } catch (err) {
    const e = err as { message?: string };
    setErrors({ otp: e?.message ?? 'Resend failed' });
  }
}
</script>

<template>
  <main class="activate">
    <h1>ACTIVATE</h1>
    <form novalidate class="activate__form" @submit.prevent="onSubmit">
      <BInput
        v-model="email"
        v-bind="emailAttrs"
        :error="errors.email"
        :readonly="emailLocked"
        label="Email"
        autocomplete="email"
      />
      <BInput
        v-model="otp"
        v-bind="otpAttrs"
        :error="errors.otp"
        label="Code"
        autocomplete="one-time-code"
        inputmode="numeric"
      />
      <BButton type="submit" variant="spot" :disabled="pending">
        {{ pending ? 'ACTIVATING…' : 'ACTIVATE' }}
      </BButton>
      <BButton type="button" variant="ghost" @click="onResend">RESEND CODE</BButton>
    </form>
  </main>
</template>

<style scoped>
.activate {
  max-width: 28rem;
  margin: 0 auto;
  padding: var(--space-6);
  font-family: var(--font-display);
}
.activate h1 {
  font-size: 2rem;
  margin-bottom: var(--space-6);
}
.activate__form {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
}
</style>
```

- [ ] **Step 4: Run the test — pass**

Run: `cd frontend && pnpm exec vitest run tests/unit/pages/ActivatePage.spec.ts`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/pages/ActivatePage.vue frontend/tests/unit/pages/ActivatePage.spec.ts
git commit -m "feat(frontend): ActivatePage with email-prefilled OTP entry"
```

---

### Task 5: Resend with 30s countdown

**Files:**
- Modify: `frontend/src/pages/ActivatePage.vue`
- Modify: `frontend/tests/unit/pages/ActivatePage.spec.ts`

- [ ] **Step 1: Add the failing test**

Append to `ActivatePage.spec.ts`:

```ts
it('resend triggers mutation, disables button for 30s', async () => {
  resendMutateAsync.mockResolvedValueOnce(undefined);
  mount();
  const btn = screen.getByRole('button', { name: /resend code/i });
  await user.click(btn);
  vi.advanceTimersByTime(10);
  await flushPromises();
  expect(resendMutateAsync).toHaveBeenCalledWith({ type: 'REGISTER', email: 'son@example.com' });
  expect(btn).toBeDisabled();
  expect(btn.textContent ?? '').toMatch(/30/);
  vi.advanceTimersByTime(30_000);
  await flushPromises();
  expect(btn).not.toBeDisabled();
});
```

- [ ] **Step 2: Run — fails**

Run: `cd frontend && pnpm exec vitest run tests/unit/pages/ActivatePage.spec.ts`
Expected: FAIL — button is not disabled.

- [ ] **Step 3: Add countdown logic to `ActivatePage.vue`**

Add inside `<script setup>` near the resend code:

```ts
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
```

Replace `onResend`:

```ts
async function onResend() {
  if (resendCooldown.value > 0) return;
  if (!email.value) {
    setErrors({ email: 'Enter your email first' });
    return;
  }
  try {
    await resend.mutateAsync({ type: 'REGISTER', email: email.value });
    startCooldown();
  } catch (err) {
    const e = err as { message?: string };
    setErrors({ otp: e?.message ?? 'Resend failed' });
  }
}
```

Replace the resend button in the template:

```vue
<BButton type="button" variant="ghost" :disabled="resendCooldown > 0" @click="onResend">
  {{ resendCooldown > 0 ? `RESEND IN ${resendCooldown}s` : 'RESEND CODE' }}
</BButton>
```

Add cleanup at end of `<script setup>`:

```ts
import { onBeforeUnmount } from 'vue';
onBeforeUnmount(() => {
  if (resendTimer) clearInterval(resendTimer);
});
```

- [ ] **Step 4: Run tests — pass**

Run: `cd frontend && pnpm exec vitest run tests/unit/pages/ActivatePage.spec.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/pages/ActivatePage.vue frontend/tests/unit/pages/ActivatePage.spec.ts
git commit -m "feat(frontend): ActivatePage resend with 30s countdown"
```

---

### Task 6: Wrong-OTP error + cold-start (no `?email=`)

**Files:**
- Modify: `frontend/src/pages/ActivatePage.vue`
- Modify: `frontend/tests/unit/pages/ActivatePage.spec.ts`

- [ ] **Step 1: Add the failing tests**

Append:

```ts
it('shows inline error and clears OTP on wrong code', async () => {
  activateMutateAsync.mockRejectedValueOnce(Object.assign(new Error('Invalid OTP'), { status: 400 }));
  mount();
  await user.type(screen.getByLabelText(/code/i), '999999');
  await user.click(screen.getByRole('button', { name: /^activate$/i }));
  vi.advanceTimersByTime(10);
  await flushPromises();
  await waitFor(() => expect(screen.getByText(/invalid otp/i)).toBeInTheDocument());
  expect((screen.getByLabelText(/code/i) as HTMLInputElement).value).toBe('');
});

it('cold-start: no ?email=, email field is editable', async () => {
  await router.push('/activate');
  await router.isReady();
  mount();
  const emailInput = screen.getByLabelText(/email/i) as HTMLInputElement;
  expect(emailInput.readOnly).toBe(false);
  expect(emailInput.value).toBe('');
});
```

- [ ] **Step 2: Run — wrong-OTP test should already pass (logic in Task 4). Cold-start should pass too if `emailLocked` ref logic is correct.**

Run: `cd frontend && pnpm exec vitest run tests/unit/pages/ActivatePage.spec.ts`
Expected: PASS (4 tests). If either fails, fix the logic in `ActivatePage.vue` (the wrong-OTP test verifies the `setErrors` branch and OTP clear; the cold-start test verifies `emailLocked` reads `queryEmail.length > 0`).

- [ ] **Step 3: Commit**

```bash
git add frontend/tests/unit/pages/ActivatePage.spec.ts
# also commit any ActivatePage.vue tweaks if needed
git add -u frontend/src/pages/ActivatePage.vue 2>/dev/null || true
git commit -m "test(frontend): ActivatePage wrong-OTP and cold-start cases"
```

---

### Task 7: Register `/activate` route

**Files:**
- Modify: `frontend/src/router/index.ts`

- [ ] **Step 1: Add the import + route**

Replace the file contents:

```ts
import { createRouter, createWebHistory } from 'vue-router';
import HomePlaceholder from '@/pages/HomePlaceholder.vue';
import DesignShowcase from '@/pages/DesignShowcase.vue';
import LoginPage from '@/pages/LoginPage.vue';
import RegisterPage from '@/pages/RegisterPage.vue';
import ActivatePage from '@/pages/ActivatePage.vue';
import CartPlaceholder from '@/pages/CartPlaceholder.vue';
import { useAuthStore } from '@/stores/auth';

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', component: HomePlaceholder },
    { path: '/_design', component: DesignShowcase },
    { path: '/login', component: LoginPage, meta: { guestOnly: true } },
    { path: '/register', component: RegisterPage, meta: { guestOnly: true } },
    { path: '/activate', component: ActivatePage, meta: { guestOnly: true } },
    { path: '/cart', component: CartPlaceholder, meta: { requiresAuth: true } },
  ],
});

router.beforeEach((to) => {
  const auth = useAuthStore();
  if (to.meta.requiresAuth && !auth.isLoggedIn) {
    return { path: '/login', query: { next: to.fullPath } };
  }
  if (to.meta.guestOnly && auth.isLoggedIn) {
    return { path: '/' };
  }
});
```

- [ ] **Step 2: Run all unit tests**

Run: `cd frontend && pnpm exec vitest run tests/unit`
Expected: all PASS except the still-stale `RegisterPage.spec.ts` happy-path (fixed in Task 8).

- [ ] **Step 3: Commit**

```bash
git add frontend/src/router/index.ts
git commit -m "feat(frontend): register /activate route as guest-only"
```

---

### Task 8: RegisterPage → /activate redirect + footer link

**Files:**
- Modify: `frontend/src/pages/RegisterPage.vue`
- Modify: `frontend/tests/unit/pages/RegisterPage.spec.ts`

- [ ] **Step 1: Update the existing happy-path test + add footer-link case**

Replace the happy-path test in `RegisterPage.spec.ts`:

```ts
it('happy path: submits and navigates to /activate with email query', async () => {
  registerMutateAsync.mockResolvedValueOnce(undefined);
  mount();
  await user.type(screen.getByLabelText(/username/i), 'son');
  await user.type(screen.getByLabelText(/email/i), 'son@example.com');
  await user.type(screen.getByLabelText(/^password$/i), 'Aa1!aa');
  await user.type(screen.getByLabelText(/confirm password/i), 'Aa1!aa');
  await user.click(screen.getByRole('button', { name: /register/i }));
  vi.advanceTimersByTime(10);
  await flushPromises();
  await waitFor(() => expect(registerMutateAsync).toHaveBeenCalled());
  await waitFor(() => {
    expect(router.currentRoute.value.path).toBe('/activate');
    expect(router.currentRoute.value.query.email).toBe('son@example.com');
  });
});

it('renders "Activate your account" footer link', () => {
  mount();
  const link = screen.getByRole('link', { name: /activate your account/i });
  expect(link.getAttribute('href')).toBe('/activate');
});
```

- [ ] **Step 2: Run — fails**

Run: `cd frontend && pnpm exec vitest run tests/unit/pages/RegisterPage.spec.ts`
Expected: FAIL — `expected '/' to be '/activate'`, and link not found.

- [ ] **Step 3: Update `RegisterPage.vue`**

Replace the `onSubmit` body:

```ts
const onSubmit = handleSubmit(async (values) => {
  try {
    await doRegister(values);
    await router.push({ path: '/activate', query: { email: values.email } });
  } catch (err) {
    const e = err as { code?: string; message?: string };
    if (e?.code === 'EMAIL_TAKEN') {
      setErrors({ email: 'Email already in use' });
    } else if (e?.message) {
      setErrors({ email: e.message });
    }
  }
});
```

Add a footer line in the template, after the existing "Already have an account?" line:

```vue
<p class="register__alt">
  Already registered?
  <RouterLink to="/activate">Activate your account →</RouterLink>
</p>
```

- [ ] **Step 4: Run — pass**

Run: `cd frontend && pnpm exec vitest run tests/unit/pages/RegisterPage.spec.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/pages/RegisterPage.vue frontend/tests/unit/pages/RegisterPage.spec.ts
git commit -m "feat(frontend): redirect RegisterPage to /activate with email"
```

---

### Task 9: LoginPage — inline activate hint on `'not-activated'`

**Files:**
- Modify: `frontend/src/pages/LoginPage.vue`
- Modify: `frontend/tests/unit/pages/LoginPage.spec.ts`

- [ ] **Step 1: Add the failing test**

Append to `LoginPage.spec.ts`:

```ts
it('shows inline activate link when login fails with "not activated"', async () => {
  loginMutateAsync.mockRejectedValueOnce(
    Object.assign(new Error('Your account is not activated'), { status: 400 }),
  );
  mount();
  await user.type(screen.getByLabelText(/username/i), 'son');
  await user.type(screen.getByLabelText(/password/i), 'Aa1!aa');
  await user.click(screen.getByRole('button', { name: /log in/i }));
  vi.advanceTimersByTime(10);
  await flushPromises();
  await waitFor(() => {
    const link = screen.getByRole('link', { name: /activate it/i });
    expect(link.getAttribute('href')).toBe('/activate');
  });
});
```

(If `loginMutateAsync` isn't already declared in the file, mirror the `registerMutateAsync` pattern from `RegisterPage.spec.ts`.)

- [ ] **Step 2: Run — fails**

Run: `cd frontend && pnpm exec vitest run tests/unit/pages/LoginPage.spec.ts`
Expected: FAIL — link not found.

- [ ] **Step 3: Update `LoginPage.vue`**

Add `import { ApiError, classify } from '@/api/error';` at the top of `<script setup>`, plus a `notActivated` ref:

```ts
import { ref } from 'vue';
import { ApiError, classify } from '@/api/error';

const notActivated = ref(false);
```

Replace the catch branch in `onSubmit`:

```ts
const onSubmit = handleSubmit(async (values) => {
  notActivated.value = false;
  try {
    await login(values);
    await router.push(safeNext(route.query.next));
  } catch (err) {
    if (err instanceof ApiError && classify(err) === 'not-activated') {
      notActivated.value = true;
      return;
    }
    const e = err as { code?: string; message?: string };
    if (e?.code === 'INVALID_CREDENTIALS') {
      setErrors({ password: 'Wrong email or password' });
    } else if (e?.message) {
      setErrors({ password: e.message });
    }
  }
});
```

Add to the template, just before the `<p class="login__alt">` line:

```vue
<p v-if="notActivated" class="login__alt">
  Account not activated.
  <RouterLink to="/activate">Activate it →</RouterLink>
</p>
```

**Note on the test:** The classifier branch matches via `instanceof ApiError`. In the test we throw a plain `Error` with `status: 400` — adjust the test to throw a real `ApiError` instead:

```ts
import { ApiError } from '@/api/error';
loginMutateAsync.mockRejectedValueOnce(new ApiError(400, 'Bad Request', 'Your account is not activated'));
```

- [ ] **Step 4: Run — pass**

Run: `cd frontend && pnpm exec vitest run tests/unit/pages/LoginPage.spec.ts`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `cd frontend && pnpm exec vitest run`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/pages/LoginPage.vue frontend/tests/unit/pages/LoginPage.spec.ts
git commit -m "feat(frontend): show activate hint on not-activated login error"
```

---

### Task 10: Live E2E + Phase 3 DoD closure

**Files:**
- Modify: `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md`
- Modify: `frontend/docs/phase-3-verification.md`
- (Run live verification — no source changes unless a bug surfaces.)

- [ ] **Step 1: Confirm MailHog (or equivalent SMTP catcher) is reachable**

Run: `docker ps --format '{{.Names}} {{.Ports}}' | grep -i mail || echo "no mailhog"`
Expected: a mailhog container with `1025/tcp` and `8025/tcp` mapped. If absent, register's email-send will silently fail and OTP can't be observed — escalate before continuing. (Backend uses `core-email`; check `docker/docker-compose-*.yml` for a mailhog service or a configured SMTP host in Vault `secret/ecommerce`.)

- [ ] **Step 2: Run frontend dev server**

Run: `cd frontend && pnpm dev`
Expected: server up at `http://localhost:5173`.

- [ ] **Step 3: Manual E2E**

Using Chrome (or the Chrome DevTools MCP):

1. Visit `http://localhost:5173/register`.
2. Submit a fresh user (e.g. `e2e-<timestamp>`, `e2e-<timestamp>@example.com`, password `Aa1!aa`).
3. Verify URL is `/activate?email=e2e-<timestamp>@example.com` and the email field is read-only and prefilled.
4. Open MailHog UI (`http://localhost:8025`), grab the OTP from the latest email.
5. Enter the OTP, click ACTIVATE.
6. Verify URL is `/login`.
7. Log in with the registered username + password → land on `/`.

Also verify the cold-start path:
1. In a fresh tab, visit `http://localhost:5173/login` and log in with a user that exists but is not yet activated → confirm the inline "Activate it →" link renders, click it, end up at `/activate` with editable email.

- [ ] **Step 4: Update DoD docs**

In `docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md` flip the Phase 3 DoD checkboxes for "register flow live" / "force-401 redirect" / "multi-tab logout" from `[ ]` to `[x]` (only those that are now actually verified).

In `frontend/docs/phase-3-verification.md` remove the "deferred — backend instability" note in the live-verification section, and add a fresh entry:

```md
### 2026-05-02 — Live E2E with activation

- Registered fresh user via `/register`
- Redirected to `/activate?email=…`
- Pulled OTP from MailHog, submitted → redirected to `/login`
- Logged in successfully → `/`
- Cold-start: login with unactivated user → inline "Activate it →" link → `/activate` (editable email)
```

- [ ] **Step 5: Commit + push**

```bash
git add docs/superpowers/specs/2026-05-01-storefront-frontend-rollout.md frontend/docs/phase-3-verification.md
git commit -m "docs(phase-3): close live E2E DoD with activation flow"
git push -u origin HEAD
```

- [ ] **Step 6: Open the Phase 3 PR (or update the existing one)**

Run:

```bash
gh pr create --title "Phase 3: API + auth + activation flow" --body "$(cat <<'EOF'
## Summary
- ActivatePage with OTP entry + 30s resend
- RegisterPage now redirects to /activate?email=
- LoginPage shows inline "Activate it →" on not-activated error
- Removed auto-login from useRegisterMutation (login is now gated on activation)

## Test plan
- [x] Unit: ActivatePage (happy, wrong OTP, resend countdown, cold-start)
- [x] Unit: RegisterPage redirect + footer link
- [x] Unit: LoginPage activate hint
- [x] Live E2E: register → MailHog OTP → activate → login → /
- [x] Live E2E: cold-start activation hint via login

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

(If a PR is already open on this branch, append the activation summary as a new comment instead.)

---

## Self-review notes

- **Spec coverage:** ✓ all spec sections mapped to tasks (Tasks 1–9 implement; Task 10 closes DoD).
- **Type consistency:** `ActivateInput`, `ResendOtpInput` defined in Task 1, used in Tasks 3–6. `'not-activated'` defined in Task 2, used in Task 9. `useActivateMutation`/`useResendOtpMutation` defined in Task 3, used in Task 4.
- **Critical hinge** documented: removing auto-login from `useRegisterMutation` (Task 3) is what unblocks the new flow — without it, the existing happy path silently re-fails.
- **Brittle classifier** (matching on message text "not activated") is intentionally narrow and tested. Backend has no error code for this; if it gains one later, swap the regex for the code check in Task 2 — the classifier is the only place to update.
