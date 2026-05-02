# Storefront Frontend Rollout — Phased Plan

**Date:** 2026-05-01
**Status:** Approved
**Companion spec:** [`2026-05-01-storefront-frontend-design.md`](./2026-05-01-storefront-frontend-design.md)

## Principles

- **Docs-first.** Phase 1 produces all conventions before any feature code. Later phases follow them.
- **Each phase is independently shippable** and reviewable end-to-end.
- **Definition of Done is measurable** — no fuzzy "feels done" gates.
- **No phase starts** until the prior phase's DoD is fully green.
- **Each phase gets its own implementation plan** (via `superpowers:writing-plans`) when it begins. No upfront plan for phases not yet started.

## Phase summary

| # | Phase | Goal | Size |
|---|---|---|---|
| 1 | Foundation + Documentation | Project scaffolded, all conventions written down, no UI features yet | ~2 days |
| 2 | Design System Primitives | All 10 primitives implemented + showcased + tested | ~2 days |
| 3 | API Plumbing + Auth | User can register, log in, see authenticated calls flowing | ~2.5 days |
| 4 | Browse (Public Storefront) | Anonymous user can browse and view products against live backend | ~1.5 days |
| 5 | Buy (Cart → Checkout → Payment) | Logged-in user can complete a purchase end-to-end | ~2.5 days |
| 6 | Manage (Orders + Cancel) | User can view orders + optimistic cancel | ~1 day |
| 7 | Polish + Hardening | Playwright golden paths, error coverage, Lighthouse pass | ~1.5 days |
|   | **Total** | | **~13 days** |

---

## Phase 1 — Foundation & Documentation

**Goal:** Project is scaffolded, all conventions are written down, but no UI features built yet.

### Scope

- Vite + Vue 3 + TS + Tailwind v4 scaffold under `frontend/`
- ESLint + Prettier + TypeScript strict + Vitest config
- Pre-commit hook (lint + typecheck on staged files)
- CI workflow `.github/workflows/frontend.yml` runs typecheck + lint + test on PR
- Folder skeleton (empty dirs with `.gitkeep`)
- `tokens.css` with all design tokens (palette, type, shadows, borders, motion)
- Self-hosted fonts (Bricolage Grotesque, Cabinet Grotesk, Departure Mono) wired
- A single placeholder index page proving tokens render correctly
- Documentation in `frontend/docs/`:
  - `00-readme.md` — project overview, onboarding, commands
  - `01-architecture.md` — folder structure, layer boundaries, data flow
  - `02-design-tokens.md` — palette, type, spacing — hex values + intent
  - `03-component-conventions.md` — primitives vs domain, naming, props/slots/emits patterns
  - `04-api-conventions.md` — queries/mutations layer, cache keys, error taxonomy
  - `05-form-conventions.md` — Zod sharing, server-error mapping
  - `06-routing-auth.md` — guards, login-gated patterns, 401 handling
  - `07-testing-conventions.md` — what to test where, fixtures, MSW, no-coverage-gate philosophy
  - `08-copy-and-voice.md` — Issue Nº01 voice guide, status/error/empty-state copy bank
  - `09-a11y-checklist.md` — keyboard, focus, contrast, screen reader
  - `adr/` — Architecture Decision Records, ≥ 7 (one per major stack pick)

### Definition of Done (measurable)

- [x] `pnpm install && pnpm typecheck && pnpm lint && pnpm test` all exit 0 on a clean clone
- [x] `pnpm dev` starts Vite, browser shows the "Issue Nº01" placeholder page using `--paper`, `--ink`, `--spot` tokens and the Bricolage display font
- [x] All 10 documentation files exist and are non-empty (each section filled, not stubs)
- [x] ≥ 7 ADRs committed under `frontend/docs/adr/` (framework, server-state, client-state, API client, forms, styling, routing)
- [ ] CI workflow runs and is green on the foundation PR
- [x] Pre-commit hook blocks a deliberate lint error in a staged file
- [x] Lighthouse run on placeholder page shows no console errors and no 404s

---

## Phase 2 — Design System Primitives

**Goal:** Every primitive component exists, is documented, and is testable in isolation.

### Scope

- Implement `BButton`, `BCard`, `BInput`, `BStamp`, `BTag`, `BCropmarks`, `BMarginNumeral`, `BDialog`, `BSelect`, `BToast`
- Reka UI wired for `BDialog` / `BSelect` headless behavior
- An in-repo design-system showcase route `/_design` listing every primitive with all variants
- Component tests for each primitive

### Definition of Done

- [x] All 10 primitives exist in `src/components/primitives/`
- [x] `/_design` renders every primitive + variant; no console errors
- [x] ≥ 2 component tests per primitive (happy + variant/state) — ≥ 20 tests total, all green
- [x] Misregistration-on-hover demoed and verified visually on `/_design`
- [x] `BButton :active` translate animation verified
- [x] Keyboard navigation verified on `BDialog` (Esc closes, focus trap) and `BSelect` (arrow keys)
- [x] Color contrast verified for `BButton variant="spot"` ink-on-orange text (target: AA, ≥ 4.5:1)

---

## Phase 3 — API Plumbing + Auth

**Goal:** A real user can register, log in, and see authenticated calls flowing.

### Scope

- `openapi-typescript` regen script (`pnpm api:gen` pulls from gateway `/v3/api-docs`)
- `openapi-fetch` client with auth interceptor + error classifier
- Pinia `useAuthStore` + localStorage persistence + multi-tab sync
- TanStack Vue Query setup + DevTools in dev
- Route guards (`requiresAuth`, `guestOnly`)
- `LoginPage` + `RegisterPage` with VeeValidate + Zod
- 401 → `useAuthStore.logoutAndRedirect()` wired through interceptor

### Definition of Done

- [ ] `pnpm api:gen` produces a non-empty `src/api/schema.d.ts` with no TS errors
- [ ] End-to-end: register a fresh user → auto-login → land on `/` → user shown in nav
- [ ] End-to-end: log out → nav reflects guest state → `/cart` redirects to `/login?next=/cart`
- [ ] Multi-tab logout: open 2 tabs, logout in tab A, tab B's next API call kicks to `/login`
- [ ] Force a 401 (mess with token in DevTools) → auto-redirect to `/login?next=…`
- [ ] Form validation: invalid email shows inline error in `--stamp-red`; password rules match backend `@ValidPassword`
- [ ] Server error (e.g., wrong password) maps to inline form error, not a toast
- [ ] ≥ 5 page tests (login happy, login wrong-pass, register happy, register password-rules, route guard redirect)

---

## Phase 4 — Browse (Public Storefront)

**Goal:** Anonymous user can browse and view products against live backend.

### Scope

- `HomePage` with product grid, search, empty / loading / error states
- `ProductDetailPage` with image, info, inventory stamp, login-gated CTA
- URL sync for search (`?q=…`)
- Image-error fallback to brutalist placeholder

### Definition of Done

- [ ] `make up` running → `pnpm dev` → home shows real products from `/bff-service/v1/products`
- [ ] Search debounces — 5 fast keystrokes produce 1 network request
- [ ] Empty catalog state shows the "Issue Nº01 coming soon" stamp
- [ ] PDP for valid id shows full product; invalid id shows 404 page with cropmark divider
- [ ] Guest CTA on PDP says "LOGIN TO BUY"; redirects to `/login?next=/products/{id}`; after login lands back on the same PDP
- [ ] ≥ 4 page tests (home renders products, home empty, home search debounce, PDP 404)
- [ ] Sticker-rotation visible on cards; misregistration on hover visible

---

## Phase 5 — Buy (Cart → Checkout → Payment)

**Goal:** Logged-in user can complete a purchase end-to-end against live backend.

### Scope

- `CartPage` with line items, qty stepper (debounced), remove, subtotal
- `CheckoutPage` with VeeValidate + Zod address form + cart summary
- Sequential mutations: create order → create payment → redirect to PayPal
- `PaymentResultPage` for `/payment/success` (poll for PAID) and `/payment/cancel` (retry/cancel CTAs)
- "STAMPING…" animation on Place Order
- Browser-back-from-PayPal banner

### Definition of Done

- [ ] Add to cart → cart shows item with correct qty + price
- [ ] Qty stepper debounced 400 ms — 5 fast clicks produce 1 PUT
- [ ] Place Order → redirect to PayPal sandbox → approve → land on `/payment/success?orderId=…` → see "PAID" stamp within 10 s
- [ ] PayPal cancel → land on `/payment/cancel?orderId=…` → "RETRY PAYMENT" re-inits payment for same order
- [ ] Browser back from PayPal page → `/checkout` shows pending-order banner
- [ ] Form validation: empty address fields show inline errors; submit blocked
- [ ] ≥ 4 page tests (cart render, cart qty debounce, checkout form validation, payment-result poll)

**Backend coordination:** Phase 5 depends on backend follow-up #1 from the design spec (PayPal redirect URL config).

---

## Phase 6 — Manage (Orders + Cancel)

**Goal:** User can view order history and cancel a PROCESSING order with optimistic feedback.

### Scope

- `OrdersPage` master-detail with deep-link `?selected=ORD123`
- Status stamps per order
- Optimistic cancel mutation with rollback on 409
- Empty state

### Definition of Done

- [ ] Place + complete an order → see it in `/orders` with PAID stamp
- [ ] Place an order in PROCESSING → "CANCEL ORDER" visible → click → stamp flips to CANCELED in < 100 ms perceived latency
- [ ] Cancel an already-canceled order → optimistic flip rolls back; toast says "Already canceled — refreshed"
- [ ] Deep-link `/orders?selected=ORD123` opens that order's detail panel
- [ ] Empty state shows marginalia "00" + "NO ORDERS YET" + CTA to `/`
- [ ] ≥ 3 page tests (orders list, optimistic cancel happy, optimistic cancel 409 rollback)

---

## Phase 7 — Polish + Hardening

**Goal:** End-to-end golden paths covered, all error classes verified, ready for v1 ship.

### Scope

- Playwright golden path 1: public browse (home → search → PDP)
- Playwright golden path 2: register → cart → checkout (PayPal stubbed) → orders → cancel
- Verify every error-taxonomy class has at least one test
- Lighthouse pass on `/` and `/products/:id`
- README updated with deployment notes
- Final pass on copy bank consistency (errors, empty states, stamps)

### Definition of Done

- [ ] 2 Playwright golden paths green in CI (mocked-mode) and locally (real-backend mode)
- [ ] Each error class (`auth-required`, `forbidden`, `not-found`, `validation`, `server`, `network`) has ≥ 1 test
- [ ] Lighthouse on `/`: Performance ≥ 80, Accessibility ≥ 95, Best Practices ≥ 95
- [ ] Zero console errors / warnings on any of the 7 screens (manual sweep)
- [ ] Total test count ≥ 50 unit + page tests, all green
- [ ] README has "Run locally", "Run tests", "Deploy" sections

---

## How phases get planned & executed

Each phase, when it begins:

1. Re-read the design spec and this rollout doc.
2. Run `superpowers:writing-plans` for **only that phase** to produce a granular task-by-task implementation plan in `docs/superpowers/plans/`.
3. Execute the plan via `superpowers:subagent-driven-development` (fresh subagent per task, two-stage review).
4. Verify the phase's DoD bullets one by one. **No moving on until every bullet is checked.**
5. Open a PR titled `frontend: phase N — <goal>` with the DoD bullets in the description.

Phase 1's plan is the next artifact to produce.
