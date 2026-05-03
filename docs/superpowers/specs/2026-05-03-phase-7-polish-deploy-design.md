# Phase 7 — Polish + Deploy Design Spec

**Date:** 2026-05-03
**Status:** Approved
**Predecessor:** Phase 6 (Account & Order History) merged via PR #6.

---

## Goal

Deliver a ship-ready frontend artifact and bring all 12 user-facing screens up to a consistent polish bar (mobile-responsive, accessible, console-clean) so v1 can deploy onto the user's k8s + AWS infrastructure.

## In Scope

- Production-shaped Docker image (multi-stage build, Caddy runtime, port 8080) suitable for ECR + k8s deploy.
- Mobile-responsive sweep at 375 / 768 / 1024 px breakpoints across all 12 pages.
- WCAG AA accessibility baseline: skip-link, focus rings, primitive ARIA, color contrast, keyboard nav.
- Lighthouse audit on `/`, `/products/:id`, `/cart`, `/account/orders` (mobile + desktop).
- Console-warning sweep (zero on clean load of every page).
- `frontend/README.md` with Run / Test / Deploy sections.

## Out of Scope (deferred)

- Playwright E2E golden paths.
- Error-taxonomy test coverage (unit-test pass per error class).
- k8s manifests / Helm chart in this repo (lives in user's infra repo).
- docker-compose entry for the frontend (dev workflow stays `pnpm dev` outside Docker).
- Staging/prod deployment beyond producing the image.
- I18n, dark-mode toggle, broader Lighthouse coverage beyond the four target screens.

---

## Sequencing

Approach: **Deploy-first, then Polish.** Lighthouse audits should run against the prod-built artifact, not Vite dev — so the image is a prerequisite for the perf work. Once the artifact is in place, every Polish iteration measures against the thing that will actually ship.

Slices in execution order:

1. **Slice 1 — Deploy artifact** (1 task)
2. **Slice 2 — Mobile-responsive sweep** (8 tasks)
3. **Slice 3 — A11y + Lighthouse** (4 tasks)
4. **Slice 4 — Console sweep + README** (2 tasks)

Total: ~15 tasks.

---

## Slice 1 — Deploy Artifact

### Components

- **`frontend/Dockerfile`** — multi-stage:
  - Stage 1 (`builder`, `node:20-alpine`): copies `package.json` + `pnpm-lock.yaml`, runs `pnpm install --frozen-lockfile`, copies source, runs `pnpm build` → `/app/dist`.
  - Stage 2 (`runner`, `caddy:2-alpine`): copies `dist` to `/srv`, copies `Caddyfile` to `/etc/caddy/Caddyfile`. Exposes 8080.
- **`frontend/Caddyfile`** — three lines:
  ```
  :8080 {
      root * /srv
      try_files {path} /index.html
      file_server
  }
  ```
  No proxy block — the cluster Ingress is responsible for `/api/*` → gateway and TLS.
- **`frontend/.dockerignore`** — excludes `node_modules`, `dist`, `tests`, `.git`, `.env*`, `coverage`, `*.log`.
- **Build-arg `VITE_API_BASE_URL`** — wired through the builder stage so the API URL is baked in per environment. Default value `/api` for dev compatibility; production builds pass the cluster's API URL.

### Out of this slice

- No nginx config, no docker-compose entry, no k8s manifest.

### Verification

- `docker build --build-arg VITE_API_BASE_URL=http://localhost:8080 -t aibles-fe:dev ./frontend` succeeds.
- `docker run --rm -p 8080:8080 aibles-fe:dev` serves the SPA at `localhost:8080`; deep-link `/account/orders` falls back to `index.html`.
- Image size ≤ 50 MB (Caddy + dist).

---

## Slice 2 — Mobile-Responsive Sweep

### Bar

Every page renders without horizontal scroll and without overlapping content at **375 px** (iPhone SE-class), **768 px** (tablet), and **1024 px+** (desktop). Bespoke mobile UX only where the editorial layout fundamentally breaks; otherwise desktop layout collapses cleanly.

### Foundation (Task 1)

- **`frontend/src/styles/tokens.css`**: add breakpoint custom properties — `--bp-sm: 480px`, `--bp-md: 768px`, `--bp-lg: 1024px` — for documentation. CSS uses literal `@media (min-width: 768px)` (custom properties don't work inside `@media` queries; the tokens are reference values, not interpolated).
- **`frontend/src/styles/base.css`**: global mobile-base reset — `html { -webkit-text-size-adjust: 100%; }`, `img, svg { max-width: 100%; height: auto; }`, `*, *::before, *::after { box-sizing: border-box; }` (already there but verify).

### Per-screen tasks

Each task ends in manual viewport checks at 375 / 768 / 1024 px and a commit.

2. **Header / AppNav** — hamburger menu at <768 px. The Account + Cart links + Logout don't fit on the masthead at narrow widths. `AppNav.vue` becomes a slide-in panel triggered by a button; menu state managed locally; closes on route change. Highest-impact change in the codebase.
3. **AccountLayout masthead-strip** — MASTHEAD/LEDGER row stacks vertically at <768 px. Outlined "02" numeral shrinks; "Issue Nº02 — The Account" kicker hides at <480 px.
4. **HomePage + ProductDetailPage** — tighten existing media queries. Product grid: 1 column at <480 px, 2 at <768 px, 3 at ≥768 px (existing default), 4 at ≥1280 px.
5. **CartPage + CheckoutPage** — line items stack on mobile (image above name above qty stepper). Order summary sticks below the cart/form, not beside it.
6. **PaymentResultPage + Auth pages (LoginPage / RegisterPage / ActivatePage)** — single-column padding/font scaling. The risograph stamp shrinks proportionally.
7. **Account: ProfilePage** — three sections (MASTHEAD avatar / COLOPHON form / CREDENTIALS password) all stack; outlined section numerals shrink; form inputs widen to fill row.
8. **Account: OrdersPage + OrderDetailPage** — OrdersPage receipt rows go from grid-row layout (status / id / total / date) to stacked label-value pairs at <600 px. OrderDetailPage RECEIPT items collapse the SKU column at <480 px; total block stays full-width.

NotFoundPage handled in the next slice (one media-query line, lumped with Slice 3 contrast pass).

---

## Slice 3 — A11y + Lighthouse

### A11y baseline (WCAG AA)

**Task 1 — skip-link + focus rings**
- Inject `<a href="#main" class="skip-link">Skip to content</a>` at the top of `App.vue`, visible only on focus.
- Every page (or its layout wrapper) wraps `<main>` with `id="main" tabindex="-1"`.
- Global `:focus-visible` rule in `base.css`: `outline: 2px solid var(--spot); outline-offset: 2px;`. Remove any existing `outline: none` declarations.
- Verify on `BButton`, `BInput`, `BTag`, `RouterLink`, hamburger toggle.

**Task 2 — primitive ARIA sweep**
- `BDialog`: `role="dialog" aria-modal="true" aria-labelledby={titleId}`; focus moves to first focusable element on open; ESC closes; body scroll-lock on open.
- `BToast`: `role="status" aria-live="polite"`; error-variant uses `role="alert" aria-live="assertive"`.
- `BInput`: error message linked via `aria-describedby={inputId}-err`; `aria-invalid={!!error}`.
- `BStamp`: decorative → `aria-hidden="true"`.
- `BCropmarks`: decorative → `aria-hidden="true"` (likely already).
- `OrderStatusStamp`: status label exposed via `aria-label="Order status: PAID"` (or equivalent).

**Task 3 — contrast + keyboard sweep**
- Verify color contrast pairs against WCAG AA 4.5:1: `--ink` on `--paper`, `--paper` on `--spot`, `--muted-ink` on `--paper`. Highest risk: `--spot` (riso accent). If `--paper` on `--spot` fails, darken `--spot` token.
- Manual keyboard sweep of all 12 pages: tab through every interactive element; verify cart quantity steppers, dialog Confirm/Cancel, hamburger menu, dropdowns work without mouse.
- NotFoundPage gets its single mobile media-query while we're touching it.

**Task 4 — Lighthouse audit + fixes**
- Run Lighthouse mobile + desktop against the prod container from Slice 1 on `/`, `/products/:id`, `/cart`, `/account/orders`.
- Targets: Performance ≥ 80, Accessibility ≥ 95, Best Practices ≥ 95, SEO ≥ 90.
- Likely findings to pre-empt:
  - Missing `width`/`height` on product images (CLS) — set explicit dims or `aspect-ratio`.
  - Font-display strategy — add `font-display: swap` to all `@font-face` declarations.
  - Missing `<html lang="en">` — add to `index.html`.
  - Missing `<meta name="description">` per page — add a default in `index.html` and per-page via Vue Router meta + a small composable.
  - Missing apple-touch-icon, theme-color — add to `index.html`.
- Re-run audit after each fix cluster; commit when thresholds hit.

---

## Slice 4 — Console Sweep + README

**Task 1 — console sweep**
- Load each of the 12 pages in dev with DevTools open; fix every warning.
- Known suspects:
  - Duplicate `api:gen` key in `frontend/package.json` (lines 7 + 17).
  - Vue Router warnings about empty paths in tests (already noted from Phase 6 OrderDetailPage tests).
  - Vue prop-default warnings flagged by lint: `BTag.rotate`, `BToast.body`.
  - Any `Failed prop type` from Phase 6 components when rendered with edge-case data.
- Goal: zero warnings on clean page load on every screen.
- Lint warning count drops from current 10 to 0.

**Task 2 — `frontend/README.md`**
- **Run locally**: `pnpm install`, `pnpm dev` (port 5173), env vars (`VITE_API_BASE_URL` default `/api` via Vite proxy to gateway), gateway expectations (must be running on `localhost:8080`).
- **Run tests**: `pnpm test` (Vitest), `pnpm typecheck` (vue-tsc), `pnpm lint`, test layout conventions (`tests/unit/{components,pages,api}/`).
- **Deploy**: `docker build --build-arg VITE_API_BASE_URL=https://api.example.com -t aibles-fe:tag ./frontend`, push to ECR, k8s expectations (image listens on 8080, Ingress handles `/api/*` proxy to gateway and TLS, no SPA fallback config needed at Ingress — Caddy handles it inside the pod).

---

## Definition of Done

- [ ] `frontend/Dockerfile` builds; `docker run -p 8080:8080 aibles-fe:dev` serves the SPA, deep-link `/account/orders` resolves via Caddy fallback. Image size ≤ 50 MB.
- [ ] All 12 pages render cleanly at 375 / 768 / 1024+ px. No horizontal scroll, no content overlap, no unintended wraps.
- [ ] axe-devtools shows zero violations on every page (manual sweep, sampled at desktop + mobile viewports).
- [ ] Lighthouse on `/`, `/products/:id`, `/cart`, `/account/orders` (mobile + desktop) hits Performance ≥ 80, Accessibility ≥ 95, Best Practices ≥ 95, SEO ≥ 90.
- [ ] Zero console warnings on fresh load of every page in dev mode.
- [ ] `pnpm test && pnpm typecheck && pnpm lint` green; lint warnings count = 0 (down from 10).
- [ ] `frontend/README.md` exists with three sections (Run locally / Run tests / Deploy), each non-trivial.

---

## Risks & Notes

- **Caddy choice is reversible.** If the user's k8s setup later mandates nginx (e.g., for a sidecar pattern, exec into the pod expectations, or company-standard images), swap stage 2 for `nginx:alpine` + a 5-line `default.conf`. No other code changes needed.
- **Mobile sweep is the largest slice (8 tasks).** If schedule pressure appears, defer NotFoundPage and PaymentResultPage to a follow-up — they're low-traffic.
- **Lighthouse SEO ≥ 90** depends on per-page `<meta name="description">`. If the small Vue Router composable is fiddly, accept SEO ≥ 80 with a single index.html description and revisit later.
- **`<meta name="description">` per route** intentionally not implemented as a full `vue-meta` library install — a small composable (~20 lines) is enough for v1.
