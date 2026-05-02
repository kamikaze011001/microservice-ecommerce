# ActivatePage — Phase 3 Addendum Design Spec

**Date:** 2026-05-02
**Goal:** Close the email-activation gap blocking Phase 3 live E2E. After register, the user lands on `/activate`, enters the OTP they received by email, and is routed to `/login` to sign in.

## Problem

Phase 3 wired register/login, but skipped activation. Backend gates login behind activation (`/v1/auth:activate`), so register → login fails today. Three endpoints already exist on the gateway and are typed in `frontend/src/api/schema.d.ts`:

- `POST /authorization-server/v1/auth:register` — empty response (no tokens).
- `POST /authorization-server/v1/auth:activate` — body `{ email, otp }`, empty response.
- `POST /authorization-server/v1/auth:resend-otp` — body `{ type, email }`, empty response. `type` must be `"REGISTER"` (resolved server-side via `OTPType.resolve`).

Login uses `username` (not email), so the activation flow has to carry email separately.

## Scope

**In scope:** New `/activate` route with OTP entry + resend; redirect Register → `/activate?email=…`; inline "not activated" hint on LoginPage; activate/resend mutations + Vue Query wiring; component tests; live E2E to close DoD.

**Out of scope:** Per-digit OTP boxes, paste-detection, auto-redirect from login on classifier hit (inline link instead), forgot-password (already has its own UI plan), auto-login after activation (would require holding plaintext password — rejected).

## Approach

Stateless, refresh-safe. No credentials stored in memory across screens. Email travels as a query param; the user re-enters it manually only if they cold-start at `/activate`.

### Flow

1. Register success → `router.push({ path: '/activate', query: { email } })`.
2. ActivatePage renders email (read-only if `?email=` present, editable if not) + OTP input + submit + resend.
3. Submit → activate mutation. Success → toast "Account activated, please sign in" → `router.push({ path: '/login', query: { username: <if known> } })`. We don't know the username at activation time (we only kept email in the query), so we route to `/login` with no prefill — user types username + password as normal.
4. Resend → resend mutation with `{ type: "REGISTER", email }`. Button disabled with a 30s countdown after each click.

### Activation-aware login (cold-start path iii)

LoginPage catches `ApiError`; if `kind === 'NOT_ACTIVATED'`, render an inline notice under the password field: "Account not activated. **Activate it →**" linking to `/activate` (no auto-redirect, no email prefill — we don't have the email from a username-based login form). The notice replaces the generic "invalid credentials" banner only when the classifier matches.

The classifier is added to `frontend/src/api/errors.ts` alongside existing kinds. The exact match rule (HTTP code, `BaseResponse.code`, or message substring) is decided during implementation by inspecting the auth-server response for an unactivated login — the codebase already has a small `ApiError` discriminator we extend.

## Components

| File | Change |
|---|---|
| `frontend/src/pages/ActivatePage.vue` | **Create.** Form: email (read-only if `?email=`), OTP (single text input), submit, "Resend code" with 30s countdown. |
| `frontend/src/router/index.ts` | **Modify.** Add `{ path: '/activate', component: ActivatePage, meta: { requiresGuest: true } }`. |
| `frontend/src/api/queries/auth.ts` | **Modify.** Add `useActivateMutation`, `useResendOtpMutation`. |
| `frontend/src/api/errors.ts` | **Modify.** Add `NOT_ACTIVATED` to the `ApiError` discriminator + classifier branch. |
| `frontend/src/pages/RegisterPage.vue` | **Modify.** Change post-register `router.push('/')` to `router.push({ path: '/activate', query: { email } })`. Add footer link "Already registered? Activate your account →" → `/activate`. |
| `frontend/src/pages/LoginPage.vue` | **Modify.** Catch `ApiError.kind === 'NOT_ACTIVATED'` → render inline "Account not activated. Activate it →" link to `/activate`. |
| `frontend/src/schemas/auth.ts` (or co-located) | **Modify.** Zod schemas for activate + resend payloads. |
| `frontend/tests/unit/pages/ActivatePage.spec.ts` | **Create.** Happy path, wrong OTP, resend countdown, prefilled email, cold-start (no `?email=`). |

## Error states

| Trigger | Behavior |
|---|---|
| Wrong OTP | Inline error under OTP field; form stays; OTP cleared. |
| Expired OTP | Inline error + "Code expired — resend?" highlight on resend button. |
| Network error | Generic toast. |
| Already activated (idempotent re-submit) | Toast "Account already active" → `router.push('/login')`. |
| Resend 429 / rate-limited | Inline message under resend button: "Please wait before requesting another code." |
| Cold-start activate (no `?email=`) | Email field editable; user types it before submitting. |

## OTP UX choices

- **Single text input**, not per-digit boxes. Simpler, paste works natively, accessible by default.
- **No autofocus heuristics**, no auto-submit on 6 chars. Submit is explicit.
- **Resend countdown**: 30s, client-side only. Backend rate-limits independently; we surface 429s as inline errors.

## Testing

**Component (`ActivatePage.spec.ts`):**
- Renders with prefilled read-only email when `?email=` provided.
- Renders editable email when no query param.
- Submit triggers activate mutation with correct payload.
- Wrong-OTP error shown inline.
- Resend triggers resend mutation; button disabled and countdown ticks down.
- Already-activated response routes to `/login` with toast.

**RegisterPage / LoginPage tests:** add cases for the new redirect target and the activation-not-required inline link.

**Live E2E (DoD):** Register a fresh user → redirected to `/activate?email=…` → fetch OTP from MailHog (local SMTP catcher) → submit → redirected to `/login` → login succeeds → land on `/`.

## Definition of Done

- [ ] `/activate` route reachable; ActivatePage rendering with email prefill works.
- [ ] Activate happy path passes locally end-to-end (register → MailHog OTP → activate → login → `/`).
- [ ] LoginPage shows the activation hint for unactivated accounts.
- [ ] Component tests pass.
- [ ] Phase 3 verification doc updated; Task 14 (live E2E) green; Phase 3 PR open.
