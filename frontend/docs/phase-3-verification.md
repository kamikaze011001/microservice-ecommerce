# Phase 3 — DoD Verification

Date: 2026-05-02
Branch: `frontend/phase-3-api-auth`
Verifier: Chrome DevTools MCP against `http://localhost:5174` (Vite dev) +
Vitest unit suite.

## Verified ✓

| DoD bullet                                                              | Evidence                                                                                                                                                                   |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Route guard: `/cart` (requiresAuth) redirects to `/login?next=/cart`    | Navigated to `/cart` while unauthenticated → URL became `/login?next=/cart`.                                                                                               |
| Route guard: guestOnly redirects authenticated users away from `/login` | Injected auth payload via `StorageEvent`; navigation to `/login` redirected to `/`.                                                                                        |
| Multi-tab logout via `storage` event                                    | Dispatched `StorageEvent('storage', { key: 'aibles.auth', newValue: null })`; store cleared and subsequent `/cart` request redirected to `/login`.                         |
| Multi-tab login via `storage` event                                     | Dispatched a populated `StorageEvent`; auth store hydrated and guestOnly guard activated.                                                                                  |
| Form validation in `--stamp-red` (`rgb(196, 48, 43)`)                   | Submitted `/register` with `notanemail` + `weak` password; inline errors rendered in `rgb(196, 48, 43)` (matches `--stamp-red` token).                                     |
| Password rules match backend `@ValidPassword`                           | Inline message: `Min 6 chars with upper, lower, number, and special (!@#$%^&*())` — mirrors backend regex (regex literal in `src/lib/zod-schemas.ts`).                     |
| Server error → inline form error (no toast)                             | `LoginPage.spec.ts` "wrong password" case asserts `INVALID_CREDENTIALS` maps to `setErrors({ password: 'Wrong email or password' })`; no `useToast` import in either page. |
| Console clean on key flows                                              | `list_console_messages` returned no warnings or errors after navigation through `/cart`, `/login`, `/register`.                                                            |
| ≥ 5 page tests                                                          | `LoginPage.spec.ts` (3) + `RegisterPage.spec.ts` (3) = 6 page tests; full suite 21 files / 70 tests green.                                                                 |
| Typecheck / lint clean                                                  | `pnpm typecheck` 0 errors; `pnpm lint` 0 errors (10 pre-existing Phase 2 warnings, untouched).                                                                             |

## Deferred — backend dependent

The local Spring stack is sealed: `authorization-server` failed to come up
(Atomikos MySQL pool exhausted) and `gateway` is consequently unreachable.
The bullets below need a live backend and will be re-verified once the stack
recovers. Code paths for each are implemented and unit-tested.

| DoD bullet                                                                          | Why deferred                                                                                                                                       | Code location                                                 |
| ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `pnpm api:gen` produces non-empty `src/api/schema.d.ts` from gateway `/v3/api-docs` | Gateway down. Plan's documented fallback used: placeholder `paths = Record<string, never>`.                                                        | `frontend/scripts/api-gen.sh`, `frontend/src/api/schema.d.ts` |
| E2E: register fresh user → auto-login → land on `/` → user shown in nav             | Auth endpoints not reachable. Auto-login chain implemented in `useRegisterMutation`; nav binding via `data-testid="nav-user"` covered by `AppNav`. | `src/api/queries/auth.ts`, `src/components/layout/AppNav.vue` |
| E2E: log out → guest nav → `/cart` redirects to `/login?next=/cart`                 | Guest-side already verified above; the "log out from authenticated session" leg requires real login.                                               | `src/stores/auth.ts:logout()`, router guard                   |
| Force 401 → auto-redirect to `/login?next=…`                                        | No real 401 source. Interceptor implemented in middleware: clears auth store + `router.replace({ path: '/login', query: { next } })`.              | `src/api/client.ts`                                           |
| Server-side wrong-password → inline error (live)                                    | Unit test covers the mapping; live request blocked.                                                                                                | `src/pages/LoginPage.vue` `onSubmit` catch block              |

## Reproduction

```bash
# Frontend dev server (already running on 5174)
cd frontend && pnpm dev

# Unit suite
pnpm test --run

# Re-run live verification once backend is up
make up        # bring authorization-server + gateway back
pnpm api:gen   # regenerate schema.d.ts from /v3/api-docs
```
