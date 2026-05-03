# Phase 7 — Polish + Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a ship-ready Docker image and bring all 12 user-facing screens up to a consistent polish bar (mobile-responsive at 375/768/1024px, WCAG AA accessibility, console-clean, Lighthouse-green) so v1 can deploy onto k8s + AWS.

**Architecture:** Multi-stage Dockerfile (`node:20-alpine` builder → `caddy:2-alpine` runtime on port 8080) with a 3-line Caddyfile providing SPA fallback. Cluster Ingress is responsible for `/api/*` → gateway proxy and TLS — no nginx config, no docker-compose entry, no in-repo k8s manifests. Mobile-responsive sweep adds breakpoint tokens then walks page-group by page-group. A11y baseline injects a global skip-link + focus-visible ring, sweeps primitives for ARIA, verifies contrast and keyboard nav, then runs a Lighthouse pass against the prod container. Console-warning sweep drives lint warnings to zero and ships a frontend README.

**Tech Stack:** Vue 3 + TypeScript + Vite 5 + Tailwind v4 (custom CSS-vars + scoped styles, **not** utility-first), pnpm 9, Vitest + @testing-library/vue + vi.mock, reka-ui primitives, Caddy 2 in the runtime stage, Docker multi-stage build.

**Key conventions (must follow):**
- Tests that mock TanStack Query mutations: `isPending: ref(false)` (NOT `{ value: false }` — Vue templates won't auto-unwrap a plain object, leaving buttons disabled). See Phase 6 commit `77a744d` for the precedent.
- CSS custom properties **don't interpolate inside `@media` queries**. The `--bp-*` tokens this plan adds are *reference values*; CSS still uses literal `@media (min-width: 768px)`.
- `BDialog` is built on `reka-ui` (Vue port of Radix) — `role="dialog"`, `aria-modal`, focus trap, ESC-to-close, and `aria-labelledby`/`-describedby` wiring are already handled by `DialogRoot`/`DialogTitle`/`DialogDescription`. The ARIA primitive sweep verifies this and only patches what's missing.
- `font-display: swap` is **already** set on every `@font-face` in `frontend/src/styles/fonts.css` (Phase 5). Don't re-add it. `<html lang="en">` is already set in `index.html`. Don't re-add it.
- Lint config runs prettier + eslint as a lint-staged hook on every commit; passing `pnpm lint` does NOT mean you'll pass the commit — the commit hook may further reformat. Run `pnpm format && pnpm lint --fix` before staging.
- Each Vue page touched in the mobile sweep is one file; verification is manual viewport + screenshot, not a unit test. Don't fabricate unit tests for "no horizontal scroll at 375px."

---

## File Structure

**New files:**
- `frontend/Dockerfile` — multi-stage build → Caddy runtime
- `frontend/Caddyfile` — 3-line SPA fallback
- `frontend/.dockerignore` — exclude node_modules, dist, tests, etc.
- `frontend/README.md` — Run/Test/Deploy
- `frontend/src/composables/usePageMeta.ts` — set `<meta name="description">` per route (SEO)

**Modified files:**

*Foundation:*
- `frontend/src/styles/tokens.css` — add `--bp-sm/-md/-lg`
- `frontend/src/styles/main.css` — add base mobile reset + global `:focus-visible` rule + `.skip-link` styles
- `frontend/src/App.vue` — inject skip-link
- `frontend/index.html` — apple-touch-icon, theme-color, default meta description

*Mobile sweep (one file each unless noted):*
- `frontend/src/components/layout/AppNav.vue` — hamburger menu <768px
- `frontend/src/layouts/AccountLayout.vue` — masthead-strip stacks <768px
- `frontend/src/pages/HomePage.vue` — grid breakpoints
- `frontend/src/pages/ProductDetailPage.vue` — image+info stacking
- `frontend/src/pages/CartPage.vue` — line-item stacking
- `frontend/src/pages/CheckoutPage.vue` — summary-below-form stacking
- `frontend/src/pages/PaymentResultPage.vue` — single-column scaling
- `frontend/src/pages/LoginPage.vue` — narrow padding
- `frontend/src/pages/RegisterPage.vue` — narrow padding
- `frontend/src/pages/ActivatePage.vue` — narrow padding
- `frontend/src/pages/account/ProfilePage.vue` — three-section stack
- `frontend/src/pages/account/OrdersPage.vue` — receipt-row stack
- `frontend/src/pages/account/OrderDetailPage.vue` — RECEIPT items collapse
- `frontend/src/pages/NotFoundPage.vue` — single media query

*A11y primitive sweep:*
- `frontend/src/components/primitives/BInput.vue` — `aria-describedby`/`aria-invalid`
- `frontend/src/components/primitives/BStamp.vue` — `aria-hidden="true"`
- `frontend/src/components/primitives/BCropmarks.vue` — `aria-hidden="true"`
- `frontend/src/components/primitives/BToast.vue` — `role="status"` / `role="alert"`
- `frontend/src/components/domain/OrderStatusStamp.vue` — `aria-label` with status

*Console + lint:*
- `frontend/package.json` — remove duplicate `api:gen` key
- `frontend/src/components/primitives/BTag.vue` — default for `rotate` prop
- `frontend/src/components/primitives/BToast.vue` — default for `body` prop (touched twice; OK)

---

## Branch Setup

### Task 0: Cut feat/phase-7-polish-deploy from main

**Files:** none (branch only)

- [ ] **Step 1: Verify clean main**

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce
git checkout main
git pull
git status
```

Expected: HEAD at `296b07b` (or later), working tree clean modulo `logs/` and the two `*Debug*.spec.ts` untracked files (predate Phase 6, ignore).

- [ ] **Step 2: Cut branch**

```bash
git checkout -b feat/phase-7-polish-deploy
git rev-parse HEAD
```

Expected: branch created at `296b07b`.

---

## Slice 1 — Deploy Artifact

### Task 1: Dockerfile, Caddyfile, .dockerignore

**Files:**
- Create: `frontend/Dockerfile`
- Create: `frontend/Caddyfile`
- Create: `frontend/.dockerignore`

- [ ] **Step 1: Write `frontend/.dockerignore`**

```
node_modules
dist
.git
.gitignore
.env
.env.*
!.env.example
coverage
*.log
tests
.vscode
.DS_Store
README.md
```

- [ ] **Step 2: Write `frontend/Caddyfile`**

```
:8080 {
    root * /srv
    try_files {path} /index.html
    file_server
    encode gzip
}
```

- [ ] **Step 3: Write `frontend/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7
ARG NODE_VERSION=20-alpine
ARG CADDY_VERSION=2-alpine

FROM node:${NODE_VERSION} AS builder
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9 --activate

# Install deps with cached layer
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# Build
COPY . .
ARG VITE_API_BASE_URL=/api
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
RUN pnpm build

# Runtime
FROM caddy:${CADDY_VERSION} AS runner
COPY --from=builder /app/dist /srv
COPY Caddyfile /etc/caddy/Caddyfile
EXPOSE 8080
# Caddy default CMD picks up /etc/caddy/Caddyfile
```

- [ ] **Step 4: Build the image**

Run from `frontend/`:

```bash
cd frontend
docker build --build-arg VITE_API_BASE_URL=/api -t aibles-fe:dev .
```

Expected: build succeeds, final image tagged `aibles-fe:dev`. Image size:

```bash
docker images aibles-fe:dev --format '{{.Size}}'
```

Expected: under 80 MB (Caddy alpine ≈ 45 MB + dist).

- [ ] **Step 5: Run the container and verify SPA fallback**

```bash
docker run --rm -d -p 8080:8080 --name fe-test aibles-fe:dev
sleep 1
curl -sI http://localhost:8080/ | head -1
curl -s http://localhost:8080/account/orders | grep -c '<div id="app">'
docker stop fe-test
```

Expected:
- First curl: `HTTP/1.1 200 OK`
- Second curl: `1` (deep link returns the SPA shell — Caddy's `try_files` fallback works)

- [ ] **Step 6: Commit**

```bash
git add frontend/Dockerfile frontend/Caddyfile frontend/.dockerignore
git commit -m "feat(fe): add multi-stage Dockerfile with Caddy runtime"
```

---

## Slice 2 — Mobile-Responsive Sweep

### Task 2: Foundation — breakpoint tokens + base mobile reset

**Files:**
- Modify: `frontend/src/styles/tokens.css`
- Modify: `frontend/src/styles/main.css`

- [ ] **Step 1: Add breakpoint tokens to `frontend/src/styles/tokens.css`**

Insert after the `--container-max: 1280px;` line (still inside `:root`):

```css
  /* ─── Breakpoints (reference values — CSS @media still uses literals) ─── */
  --bp-sm: 30rem; /* 480px */
  --bp-md: 48rem; /* 768px */
  --bp-lg: 64rem; /* 1024px */
```

- [ ] **Step 2: Add base mobile reset to `frontend/src/styles/main.css`**

Append at the end of the file (after the `::selection` block):

```css
/* Mobile base — prevent iOS text autosize, fluid media, sane box model */
html {
  -webkit-text-size-adjust: 100%;
}
*,
*::before,
*::after {
  box-sizing: border-box;
}
img,
svg,
video {
  max-width: 100%;
  height: auto;
}
```

- [ ] **Step 3: Verify build still passes**

```bash
cd frontend
pnpm typecheck
pnpm lint
```

Expected: no new errors. Lint may still show 10 pre-existing warnings; that's fine for now.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/styles/tokens.css frontend/src/styles/main.css
git commit -m "style(fe): add breakpoint tokens and base mobile reset"
```

---

### Task 3: AppNav hamburger menu <768px

**Files:**
- Modify: `frontend/src/components/layout/AppNav.vue`

The current AppNav puts brand + (user, ACCOUNT, LOG OUT) in a flex row. At 375px the right side wraps and overlaps the brand. This task adds a hamburger button visible <768px that toggles a slide-down panel with the same links.

- [ ] **Step 1: Replace the `<script setup>` block**

```vue
<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { RouterLink, useRouter, useRoute } from 'vue-router';
import { storeToRefs } from 'pinia';
import { useAuthStore } from '@/stores/auth';
import { useLogout } from '@/api/queries/auth';
import { BButton } from '@/components/primitives';

const auth = useAuthStore();
const { isLoggedIn, username } = storeToRefs(auth);
const logout = useLogout();
const router = useRouter();
const route = useRoute();

const greeting = computed(() => (username.value ? `@${username.value}` : ''));

const menuOpen = ref(false);
function toggleMenu() {
  menuOpen.value = !menuOpen.value;
}
// close on route change
watch(() => route.fullPath, () => {
  menuOpen.value = false;
});

function onLogout() {
  logout();
  menuOpen.value = false;
  router.push('/');
}
</script>
```

- [ ] **Step 2: Replace the `<template>` block**

```vue
<template>
  <nav class="app-nav" :class="{ 'is-open': menuOpen }">
    <div class="app-nav__bar">
      <RouterLink to="/" class="app-nav__brand">ISSUE Nº01</RouterLink>
      <button
        type="button"
        class="app-nav__toggle"
        :aria-expanded="menuOpen"
        aria-controls="app-nav-menu"
        :aria-label="menuOpen ? 'Close menu' : 'Open menu'"
        @click="toggleMenu"
      >
        <span class="app-nav__toggle-bar" aria-hidden="true" />
        <span class="app-nav__toggle-bar" aria-hidden="true" />
        <span class="app-nav__toggle-bar" aria-hidden="true" />
      </button>
      <div class="app-nav__right">
        <template v-if="isLoggedIn">
          <span class="app-nav__user" data-testid="nav-user">{{ greeting }}</span>
          <RouterLink to="/account" class="app-nav__account">ACCOUNT</RouterLink>
          <BButton variant="ghost" data-testid="nav-logout" @click="onLogout"> LOG OUT </BButton>
        </template>
        <template v-else>
          <RouterLink to="/login" data-testid="nav-login">
            <BButton variant="ghost">LOG IN</BButton>
          </RouterLink>
        </template>
      </div>
    </div>
    <div id="app-nav-menu" class="app-nav__menu" :hidden="!menuOpen">
      <template v-if="isLoggedIn">
        <span class="app-nav__menu-user">{{ greeting }}</span>
        <RouterLink to="/account" class="app-nav__menu-link">ACCOUNT</RouterLink>
        <button type="button" class="app-nav__menu-link" data-testid="nav-logout-mobile" @click="onLogout">
          LOG OUT
        </button>
      </template>
      <template v-else>
        <RouterLink to="/login" class="app-nav__menu-link" data-testid="nav-login-mobile">LOG IN</RouterLink>
      </template>
    </div>
  </nav>
</template>
```

- [ ] **Step 3: Replace the `<style scoped>` block**

```vue
<style scoped>
.app-nav {
  border-bottom: var(--border-thick);
  background: var(--paper);
}
.app-nav__bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: var(--space-3) var(--space-4);
  gap: var(--space-3);
}
.app-nav__brand {
  font-family: var(--font-display);
  font-size: 1.25rem;
  letter-spacing: 0.04em;
  color: var(--ink);
  text-decoration: none;
}
.app-nav__toggle {
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  width: 2rem;
  height: 1.5rem;
  background: transparent;
  border: 0;
  padding: 0;
  cursor: pointer;
}
.app-nav__toggle-bar {
  display: block;
  width: 100%;
  height: 3px;
  background: var(--ink);
}
.app-nav__right {
  display: none;
}
.app-nav__menu {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  padding: var(--space-4);
  border-top: var(--border-thin);
}
.app-nav__menu[hidden] {
  display: none;
}
.app-nav__menu-user {
  font-family: var(--font-mono);
  font-size: 0.875rem;
  color: var(--muted-ink);
}
.app-nav__menu-link {
  font-family: var(--font-mono);
  font-size: 1rem;
  letter-spacing: 0.08em;
  color: var(--ink);
  text-decoration: none;
  background: transparent;
  border: 0;
  padding: 0;
  text-align: left;
  cursor: pointer;
}
.app-nav__user {
  font-family: var(--font-mono);
  font-size: 0.875rem;
  color: var(--muted-ink);
}
.app-nav__account {
  font-family: var(--font-mono);
  font-size: 0.875rem;
  letter-spacing: 0.08em;
  color: var(--ink);
  text-decoration: none;
}

/* Tablet+ : show the inline links, hide the hamburger and the dropdown panel */
@media (min-width: 48rem) {
  .app-nav__bar {
    padding: var(--space-3) var(--space-6);
  }
  .app-nav__toggle {
    display: none;
  }
  .app-nav__right {
    display: flex;
    align-items: center;
    gap: var(--space-3);
  }
  .app-nav__menu {
    display: none !important;
  }
}
</style>
```

- [ ] **Step 4: Run existing AppNav tests**

```bash
cd frontend
pnpm test tests/unit/components/layout 2>&1 | tail -20
```

If there are no tests for AppNav, that's fine — verification is manual. Run full suite:

```bash
pnpm test 2>&1 | tail -10
```

Expected: 154/154 still passing (Phase 6 baseline).

- [ ] **Step 5: Manual viewport check**

```bash
pnpm dev
```

In Chrome DevTools (Cmd+Opt+I → Cmd+Shift+M):
- 375px: hamburger button visible top-right; inline links hidden; click hamburger → menu drops down with ACCOUNT/LOG OUT (or LOG IN); click a link → menu closes; resize to 768px → menu auto-closes via CSS, inline links appear.
- 768px: hamburger hidden, ACCOUNT + LOG OUT inline.
- 1024px: same as 768px, more padding.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/components/layout/AppNav.vue
git commit -m "feat(fe): AppNav hamburger menu below 768px"
```

---

### Task 4: AccountLayout masthead-strip stacks <768px

**Files:**
- Modify: `frontend/src/layouts/AccountLayout.vue`

The masthead strip currently puts the outlined "02" numeral and the MASTHEAD/LEDGER nav links side-by-side. At <768px stack vertically; at <480px hide the "Issue Nº02 — The Account" kicker.

- [ ] **Step 1: Find the existing layout style block**

```bash
grep -n "<style" frontend/src/layouts/AccountLayout.vue
```

- [ ] **Step 2: Append responsive overrides at the end of `<style scoped>`**

Insert before the closing `</style>` tag:

```css
@media (max-width: 47.99rem) {
  .account-shell__masthead {
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-3);
  }
  .account-shell__numeral {
    font-size: 4rem;
  }
  .account-shell__nav {
    width: 100%;
    justify-content: flex-start;
  }
}

@media (max-width: 29.99rem) {
  .account-shell__kicker {
    display: none;
  }
}
```

**Note:** the class names above (`.account-shell__masthead`, `.account-shell__numeral`, `.account-shell__nav`, `.account-shell__kicker`) are the ones the existing file uses. If your local file uses different BEM names, adapt to match (read the file first before editing). The pattern is: stack the masthead container, shrink the numeral, hide the kicker at small widths.

- [ ] **Step 3: Manual viewport check**

```bash
pnpm dev
# log in, navigate to /account/profile
```

- 375px: numeral above, MASTHEAD/LEDGER row below; kicker hidden.
- 480px: numeral above, kicker visible, links below.
- 768px: side-by-side restored.

- [ ] **Step 4: Run tests**

```bash
pnpm test 2>&1 | tail -5
```

Expected: still green.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/layouts/AccountLayout.vue
git commit -m "style(fe): AccountLayout masthead stacks below 768px"
```

---

### Task 5: HomePage + ProductDetailPage responsive

**Files:**
- Modify: `frontend/src/pages/HomePage.vue`
- Modify: `frontend/src/pages/ProductDetailPage.vue`

Both pages have existing media queries. Tighten/extend so:
- Home product grid: **1 col <480px, 2 col <768px, 3 col 768–1280px (existing default), 4 col ≥1280px**.
- ProductDetail: image and info side-by-side at ≥768px; stacked below.

- [ ] **Step 1: Read current breakpoints in HomePage**

```bash
grep -n "@media\|grid-template-columns" frontend/src/pages/HomePage.vue
```

- [ ] **Step 2: Replace any existing `.home__grid` (or equivalent product-grid class) media stack**

Use this canonical block. **Replace** the existing one — don't append duplicates. Class name follows the BEM pattern in the file (likely `.home__grid` or `.products__grid`):

```css
.home__grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: var(--space-4);
}

@media (min-width: 30rem) {
  .home__grid {
    grid-template-columns: repeat(2, 1fr);
  }
}

@media (min-width: 48rem) {
  .home__grid {
    grid-template-columns: repeat(3, 1fr);
    gap: var(--space-6);
  }
}

@media (min-width: 80rem) {
  .home__grid {
    grid-template-columns: repeat(4, 1fr);
  }
}
```

- [ ] **Step 3: Replace any existing `.pdp__main` (or equivalent product-detail wrapper)**

```css
.pdp__main {
  display: grid;
  grid-template-columns: 1fr;
  gap: var(--space-6);
}

@media (min-width: 48rem) {
  .pdp__main {
    grid-template-columns: 1fr 1fr;
    gap: var(--space-8);
  }
}
```

If the local class is `.product__detail` or `.pdp__layout`, match the file. Goal: stacked single-col on mobile, two-col at ≥768px.

- [ ] **Step 4: Manual viewport check**

```bash
pnpm dev
# visit /
```

- 375px: single-column product list, full-width cards.
- 600px: 2-column.
- 900px: 3-column.
- 1300px: 4-column.

```bash
# visit /products/<some-id>
```

- 375px: image stacked above name/price/buy.
- 768px: image left, info right.

- [ ] **Step 5: Run tests**

```bash
pnpm test 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add frontend/src/pages/HomePage.vue frontend/src/pages/ProductDetailPage.vue
git commit -m "style(fe): tighten Home grid and PDP layout breakpoints"
```

---

### Task 6: CartPage + CheckoutPage stacking

**Files:**
- Modify: `frontend/src/pages/CartPage.vue`
- Modify: `frontend/src/pages/CheckoutPage.vue`

CartPage line items currently render in a row (image | name | qty stepper | line total | remove). At <600px stack them. CheckoutPage puts the address form left and order summary right at desktop; at <768px stack with summary below the form.

- [ ] **Step 1: Append responsive block to `frontend/src/pages/CartPage.vue` `<style scoped>`**

Insert before the closing `</style>`:

```css
@media (max-width: 37.49rem) {
  .cart__row {
    grid-template-columns: 4rem 1fr;
    grid-template-areas:
      'img name'
      'img controls'
      'img total';
    row-gap: var(--space-2);
  }
  .cart__row-img {
    grid-area: img;
  }
  .cart__row-name {
    grid-area: name;
  }
  .cart__row-controls {
    grid-area: controls;
    justify-self: start;
  }
  .cart__row-total {
    grid-area: total;
    justify-self: start;
  }
}
```

If the actual cart-row classes differ, adapt. The pattern: at <600px collapse to a 2-col grid (image + content) where the right column stacks name/qty/total.

- [ ] **Step 2: Append responsive block to `frontend/src/pages/CheckoutPage.vue` `<style scoped>`**

Insert before closing `</style>`:

```css
@media (max-width: 47.99rem) {
  .checkout__layout {
    grid-template-columns: 1fr;
    gap: var(--space-6);
  }
  .checkout__summary {
    order: 2;
  }
  .checkout__form {
    order: 1;
  }
}
```

- [ ] **Step 3: Manual viewport check**

```bash
pnpm dev
# add an item, visit /cart at 375px → row stacks vertically
# visit /checkout at 375px → form on top, summary below
```

- [ ] **Step 4: Run tests**

```bash
pnpm test 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add frontend/src/pages/CartPage.vue frontend/src/pages/CheckoutPage.vue
git commit -m "style(fe): stack cart rows and checkout summary on mobile"
```

---

### Task 7: PaymentResultPage + Auth pages responsive padding

**Files:**
- Modify: `frontend/src/pages/PaymentResultPage.vue`
- Modify: `frontend/src/pages/LoginPage.vue`
- Modify: `frontend/src/pages/RegisterPage.vue`
- Modify: `frontend/src/pages/ActivatePage.vue`

These pages are already single-column. The job here is reducing padding and font sizes so nothing overflows at 375px, and the giant numerals/stamps shrink proportionally.

- [ ] **Step 1: Append to `PaymentResultPage.vue` `<style scoped>`**

```css
@media (max-width: 37.49rem) {
  .result {
    padding: var(--space-6) var(--space-4);
  }
  .result__headline {
    font-size: var(--type-h1);
  }
}
```

- [ ] **Step 2: Append to `LoginPage.vue`, `RegisterPage.vue`, `ActivatePage.vue` `<style scoped>`**

For each, append (using the appropriate root class — `.login`, `.register`, `.activate`):

```css
@media (max-width: 37.49rem) {
  .login {
    padding: var(--space-6) var(--space-4);
  }
}
```

(Replace `.login` with `.register` / `.activate` per file. Read the file first to confirm the root class name.)

- [ ] **Step 3: Manual viewport check at 375px**

Verify each page:
- `/payment/success?orderId=x` — headline fits, no overflow.
- `/login`, `/register`, `/activate?token=x` — form full-width, padding sane.

- [ ] **Step 4: Run tests**

```bash
pnpm test 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add frontend/src/pages/PaymentResultPage.vue \
        frontend/src/pages/LoginPage.vue \
        frontend/src/pages/RegisterPage.vue \
        frontend/src/pages/ActivatePage.vue
git commit -m "style(fe): tighten mobile padding on result and auth pages"
```

---

### Task 8: ProfilePage three-section stack

**Files:**
- Modify: `frontend/src/pages/account/ProfilePage.vue`

The page has three numbered sections (01—MASTHEAD avatar, 02—COLOPHON form, 03—CREDENTIALS password). Each section has an outlined section numeral on the left and content on the right; on mobile, stack.

- [ ] **Step 1: Append responsive block to `<style scoped>`**

```css
@media (max-width: 47.99rem) {
  .profile__section {
    grid-template-columns: 1fr;
    gap: var(--space-3);
  }
  .profile__section-numeral {
    font-size: 3rem;
  }
  .profile__form-row {
    grid-template-columns: 1fr;
  }
  .profile__avatar-card {
    flex-direction: column;
    align-items: flex-start;
  }
}
```

If exact class names differ, adapt. Pattern: stack section's left-numeral and right-content; collapse any 2-col form rows into single column.

- [ ] **Step 2: Manual viewport check**

```bash
pnpm dev
# log in → /account/profile at 375px
```

- Section numerals stack above their content.
- Avatar card: image above, "UPLOAD" button below.
- Form fields full-width; address textarea full-width.
- Submit/save buttons full-width or naturally sized.

- [ ] **Step 3: Run tests**

```bash
pnpm test tests/unit/pages/ProfilePage.spec.ts 2>&1 | tail -5
```

Expected: 3/3 still pass.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/pages/account/ProfilePage.vue
git commit -m "style(fe): ProfilePage sections stack on mobile"
```

---

### Task 9: OrdersPage + OrderDetailPage receipt collapse

**Files:**
- Modify: `frontend/src/pages/account/OrdersPage.vue`
- Modify: `frontend/src/pages/account/OrderDetailPage.vue`

OrdersPage receipt rows are a desktop grid (status pill | order id | total | date | view-link). At <600px collapse to stacked label/value pairs. OrderDetailPage RECEIPT items are a grid (idx | image | name | qty | price | subtotal); at <480px drop the idx column and stack name above qty×price.

- [ ] **Step 1: Append to `OrdersPage.vue` `<style scoped>`**

```css
@media (max-width: 37.49rem) {
  .ledger__row {
    grid-template-columns: 1fr;
    grid-template-areas:
      'stamp'
      'id'
      'meta'
      'cta';
    gap: var(--space-2);
    padding: var(--space-3);
  }
  .ledger__row-stamp { grid-area: stamp; justify-self: start; }
  .ledger__row-id { grid-area: id; }
  .ledger__row-meta { grid-area: meta; display: flex; justify-content: space-between; }
  .ledger__row-cta { grid-area: cta; justify-self: end; }
}
```

Adapt class names to match the file. Pattern: collapse the row into a single-column stack, with the stamp/status on top, then id, then total+date inline, then the View link.

- [ ] **Step 2: Append to `OrderDetailPage.vue` `<style scoped>` and `OrderItemRow.vue` if needed**

In `OrderDetailPage.vue`:

```css
@media (max-width: 47.99rem) {
  .receipt {
    padding: var(--space-3);
  }
  .receipt__title {
    font-size: var(--type-h2);
  }
  .receipt__numeral {
    font-size: 3rem;
  }
  .receipt__total {
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-2);
    padding: var(--space-3);
  }
}
```

In `frontend/src/components/domain/OrderItemRow.vue` `<style scoped>` append:

```css
@media (max-width: 29.99rem) {
  .item-row {
    grid-template-columns: 3rem 1fr;
    grid-template-areas:
      'img name'
      'img qtyprice';
    row-gap: var(--space-1);
  }
  .item-row__idx { display: none; }
  .item-row__img { grid-area: img; }
  .item-row__name { grid-area: name; }
  .item-row__qty,
  .item-row__price,
  .item-row__subtotal {
    /* stack qty × price = subtotal in a single line */
    grid-area: qtyprice;
  }
}
```

Adapt class names to match the actual file.

- [ ] **Step 3: Manual viewport check**

```bash
pnpm dev
# log in → /account/orders → click into a paid order
```

- Orders list at 375px: each row is a vertical card.
- Order detail at 375px: receipt items collapse, total block stacks label above amount.

- [ ] **Step 4: Run tests**

```bash
pnpm test tests/unit/pages/OrderDetailPage.spec.ts tests/unit/pages/OrdersPage.spec.ts 2>&1 | tail -10
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/pages/account/OrdersPage.vue \
        frontend/src/pages/account/OrderDetailPage.vue \
        frontend/src/components/domain/OrderItemRow.vue
git commit -m "style(fe): ledger and receipt collapse on mobile"
```

---

## Slice 3 — A11y + Lighthouse

### Task 10: Skip-link + global focus rings

**Files:**
- Modify: `frontend/src/App.vue`
- Modify: `frontend/src/styles/main.css`

- [ ] **Step 1: Replace `frontend/src/App.vue` template**

```vue
<template>
  <a href="#main" class="skip-link">Skip to content</a>
  <AppNav />
  <main id="main" tabindex="-1">
    <RouterView />
  </main>
  <ToastViewport />
</template>
```

- [ ] **Step 2: Append to `frontend/src/styles/main.css`**

```css
/* Skip-link — visible only on keyboard focus */
.skip-link {
  position: absolute;
  top: 0;
  left: 0;
  padding: var(--space-2) var(--space-3);
  background: var(--ink);
  color: var(--paper);
  font-family: var(--font-mono);
  font-size: 0.875rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  text-decoration: none;
  transform: translateY(-100%);
  z-index: 100;
}
.skip-link:focus {
  transform: translateY(0);
  outline: 2px solid var(--spot);
}

/* Global focus ring — keyboard-only via :focus-visible */
:focus-visible {
  outline: 2px solid var(--spot);
  outline-offset: 2px;
}

/* Reset visible-only outlines on mouse focus to avoid double rings */
:focus:not(:focus-visible) {
  outline: none;
}

/* Suppress focus ring on the main wrapper itself (it's a programmatic target) */
#main:focus {
  outline: none;
}

main#main {
  display: block;
}
```

- [ ] **Step 3: Search for any `outline: none` declarations to remove**

```bash
cd frontend
grep -rn "outline:\s*none\|outline:0" src --include="*.vue" --include="*.css"
```

For each match outside `:focus:not(:focus-visible)`, remove it. (Phase 5 components occasionally set `outline: none` on `:focus`. Replace with the `:focus-visible` pattern from main.css, or just delete the rule and let the global one take over.)

- [ ] **Step 4: Manual keyboard test**

```bash
pnpm dev
```

- Tab onto the page → "Skip to content" appears top-left → Enter → focus jumps to `<main>`.
- Tab through any page → every interactive element shows the orange focus ring.
- Click any element → no ring (focus-visible suppresses mouse focus).

- [ ] **Step 5: Run tests**

```bash
pnpm test 2>&1 | tail -5
```

Expected: still 154/154 (or higher if any new tests landed).

- [ ] **Step 6: Commit**

```bash
git add frontend/src/App.vue frontend/src/styles/main.css
# plus any files where you removed outline:none
git commit -m "feat(fe): add skip-link and global :focus-visible rings"
```

---

### Task 11: Primitive ARIA sweep

**Files:**
- Modify: `frontend/src/components/primitives/BInput.vue`
- Modify: `frontend/src/components/primitives/BStamp.vue`
- Modify: `frontend/src/components/primitives/BCropmarks.vue`
- Modify: `frontend/src/components/primitives/BToast.vue`
- Modify: `frontend/src/components/domain/OrderStatusStamp.vue`

`BDialog` already gets full a11y from reka-ui; verify-only.

- [ ] **Step 1: Patch `BInput.vue` — add `aria-invalid` and confirm `aria-describedby`**

Find the `<input>` element. Ensure these attributes are present:

```vue
<input
  :id="inputId"
  :aria-describedby="props.error ? `${inputId}-err` : undefined"
  :aria-invalid="props.error ? 'true' : undefined"
  v-bind="$attrs"
/>
```

The error `<p>` already has `id="${inputId}-err"` and `role="alert"` (verified in BInput.vue:46).

- [ ] **Step 2: Patch `BStamp.vue` — mark decorative**

Add `aria-hidden="true"` to the root element:

```vue
<template>
  <div class="b-stamp" aria-hidden="true">
    <!-- existing content -->
  </div>
</template>
```

- [ ] **Step 3: Patch `BCropmarks.vue` — mark decorative**

Same: add `aria-hidden="true"` to the root.

- [ ] **Step 4: Patch `BToast.vue` — add live region role**

Find the toast item element. Add:

```vue
<div
  class="b-toast"
  :class="`b-toast--${variant}`"
  :role="variant === 'error' ? 'alert' : 'status'"
  :aria-live="variant === 'error' ? 'assertive' : 'polite'"
>
```

If `ToastViewport.vue` wraps multiple toasts, add `role="region" aria-label="Notifications"` to its root (already has `aria-label="Notifications"` per Phase 6 OrderDetailPage test output — verify, add if missing).

- [ ] **Step 5: Patch `OrderStatusStamp.vue` — expose status to AT**

Wrap the BStamp with an `aria-label`. Edit:

```vue
<template>
  <BStamp
    :tone="tone"
    :rotate="rotate"
    :aria-label="`Order status: ${label}`"
    role="img"
  >
    {{ label }}
  </BStamp>
</template>
```

If BStamp doesn't forward attrs, add a passthrough span:

```vue
<template>
  <span :aria-label="`Order status: ${label}`" role="img">
    <BStamp :tone="tone" :rotate="rotate">{{ label }}</BStamp>
  </span>
</template>
```

- [ ] **Step 6: Verify BDialog ARIA via reka-ui (no edits expected)**

```bash
grep -A2 "DialogRoot\|DialogTitle\|DialogDescription" frontend/src/components/primitives/BDialog.vue
```

Confirm: `DialogTitle`, `DialogDescription` are used. reka-ui auto-wires `aria-labelledby` and `aria-describedby` from these. ESC + focus-trap are built in. Nothing to change.

- [ ] **Step 7: Run tests**

```bash
cd frontend
pnpm test 2>&1 | tail -10
```

Expected: still green. If `BInput`-related tests fail because they now find an `aria-invalid` attr, update the test assertions to expect it.

- [ ] **Step 8: Commit**

```bash
git add frontend/src/components/primitives/BInput.vue \
        frontend/src/components/primitives/BStamp.vue \
        frontend/src/components/primitives/BCropmarks.vue \
        frontend/src/components/primitives/BToast.vue \
        frontend/src/components/domain/OrderStatusStamp.vue
git commit -m "a11y(fe): primitive ARIA sweep (input, stamp, cropmarks, toast)"
```

---

### Task 12: WCAG AA contrast verification + keyboard sweep + NotFoundPage responsive

**Files:**
- Possibly modify: `frontend/src/styles/tokens.css` (only if a contrast pair fails)
- Modify: `frontend/src/pages/NotFoundPage.vue`

- [ ] **Step 1: Run contrast checks**

For each pair, use a contrast checker (e.g., https://webaim.org/resources/contrastchecker/) or this Node one-liner:

```bash
cat <<'EOF' | node
function lum(hex){const r=parseInt(hex.slice(1,3),16)/255,g=parseInt(hex.slice(3,5),16)/255,b=parseInt(hex.slice(5,7),16)/255;
const [R,G,B]=[r,g,b].map(c=>c<=0.03928?c/12.92:Math.pow((c+0.055)/1.055,2.4));
return 0.2126*R+0.7152*G+0.0722*B}
function ratio(a,b){const L1=Math.max(lum(a),lum(b)),L2=Math.min(lum(a),lum(b));return ((L1+0.05)/(L2+0.05)).toFixed(2)}
const pairs=[['#1c1c1c','#f4efe6','ink/paper'],['#f4efe6','#ff4f1c','paper/spot'],['#1c1c1c','#ff4f1c','ink/spot'],['#6b6256','#f4efe6','muted/paper'],['#1c1c1c','#e8dfd0','ink/paper-shade']];
pairs.forEach(([a,b,n])=>console.log(n,ratio(a,b)));
EOF
```

Expected output: all pairs ≥ 4.5 (WCAG AA for normal text). If `paper/spot` (paper text on the orange spot background) is below 4.5, you have two options:
- Darken `--spot` from `#ff4f1c` to something like `#d63a0a` in tokens.css.
- OR keep `--spot` and only use it as a *background* with `--ink` text on top (not `--paper`).

- [ ] **Step 2: If a pair fails, patch `tokens.css`**

Only do this if Step 1 flagged a failure. Example darkening:

```css
--spot: #d63a0a;
```

- [ ] **Step 3: Manual keyboard sweep**

```bash
pnpm dev
```

Tab through each of the 12 pages. Verify:
- Cart quantity steppers: arrow keys / +/- buttons reachable, `aria-label` on each.
- Dialog Confirm/Cancel: tab cycles inside dialog (focus trap), ESC closes.
- Hamburger menu: enter opens, ESC or click outside closes.
- Forms: Submit reachable via Tab from last input, Enter submits.
- Dropdowns / select elements: keyboard navigable.

Document any keyboard dead-ends you find as separate fix commits within this task.

- [ ] **Step 4: NotFoundPage one-line responsive fix**

Append to `frontend/src/pages/NotFoundPage.vue` `<style scoped>`:

```css
@media (max-width: 37.49rem) {
  .not-found {
    padding: var(--space-6) var(--space-4);
  }
  .not-found__numeral {
    font-size: 4rem;
  }
}
```

- [ ] **Step 5: Run tests**

```bash
pnpm test 2>&1 | tail -5
```

- [ ] **Step 6: Commit (or split across two commits if you patched tokens)**

```bash
git add frontend/src/pages/NotFoundPage.vue
# if tokens.css was patched:
git add frontend/src/styles/tokens.css
git commit -m "a11y(fe): contrast pass and NotFoundPage mobile padding"
```

---

### Task 13: Lighthouse audit + fixes (image dims, meta description, apple-touch-icon)

**Files:**
- Create: `frontend/src/composables/usePageMeta.ts`
- Modify: `frontend/index.html`
- Modify: each page that calls `usePageMeta` (Home, ProductDetail, Cart, Orders — minimum)
- Possibly modify: `frontend/src/components/domain/ProductCard.vue` and any other component rendering product images

- [ ] **Step 1: Add `<meta>` defaults + apple-touch-icon to `frontend/index.html`**

Replace the `<head>` block:

```html
<head>
  <meta charset="UTF-8" />
  <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
  <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <meta name="theme-color" content="#f4efe6" />
  <meta name="description" content="Issue Nº01 — a small editorial storefront." />
  <title>Issue Nº01 — Storefront</title>
</head>
```

If `frontend/public/apple-touch-icon.png` doesn't exist, copy `favicon.svg` and rasterize, OR drop the `<link rel="apple-touch-icon">` line (Lighthouse will still flag a 404 if the link is present but the file is missing — worse than not having it).

```bash
ls frontend/public/
```

If no `apple-touch-icon.png`, omit the line for now and let SEO score sit just below 95.

- [ ] **Step 2: Create `frontend/src/composables/usePageMeta.ts`**

```ts
import { onUnmounted, watchEffect, type Ref, isRef } from 'vue';

const DEFAULT_DESCRIPTION = 'Issue Nº01 — a small editorial storefront.';

function setMeta(name: string, value: string) {
  let el = document.querySelector(`meta[name="${name}"]`) as HTMLMetaElement | null;
  if (!el) {
    el = document.createElement('meta');
    el.name = name;
    document.head.appendChild(el);
  }
  el.content = value;
}

export function usePageMeta(opts: {
  title: string | Ref<string>;
  description?: string | Ref<string>;
}) {
  const initialTitle = document.title;
  const initialDesc =
    (document.querySelector('meta[name="description"]') as HTMLMetaElement | null)?.content ??
    DEFAULT_DESCRIPTION;

  watchEffect(() => {
    const t = isRef(opts.title) ? opts.title.value : opts.title;
    const d = opts.description
      ? isRef(opts.description)
        ? opts.description.value
        : opts.description
      : DEFAULT_DESCRIPTION;
    document.title = t;
    setMeta('description', d);
  });

  onUnmounted(() => {
    document.title = initialTitle;
    setMeta('description', initialDesc);
  });
}
```

- [ ] **Step 3: Wire `usePageMeta` into the four Lighthouse target pages**

Each of these adds a single line at the top of `<script setup>`:

`frontend/src/pages/HomePage.vue`:

```ts
import { usePageMeta } from '@/composables/usePageMeta';
usePageMeta({ title: 'Issue Nº01 — Storefront', description: 'Browse the latest collection.' });
```

`frontend/src/pages/ProductDetailPage.vue` (use the product name once it loads):

```ts
import { computed } from 'vue';
import { usePageMeta } from '@/composables/usePageMeta';
// after `const product = useProductQuery(...)`:
const pageTitle = computed(() => product.data.value?.name ?? 'Product');
usePageMeta({ title: pageTitle });
```

`frontend/src/pages/CartPage.vue`:

```ts
import { usePageMeta } from '@/composables/usePageMeta';
usePageMeta({ title: 'Cart — Issue Nº01', description: 'Your cart.' });
```

`frontend/src/pages/account/OrdersPage.vue`:

```ts
import { usePageMeta } from '@/composables/usePageMeta';
usePageMeta({ title: 'Orders — Issue Nº01', description: 'Your order history.' });
```

- [ ] **Step 4: Add explicit dimensions to product images**

Find the product card / image components:

```bash
grep -rn "<img\|class=\"product-card__img\|class=\"product__image" frontend/src --include="*.vue" | head
```

For each `<img>` rendering a product/avatar, add `width` and `height` attributes (or the equivalent `aspect-ratio` CSS):

```vue
<img :src="src" :alt="alt" width="600" height="600" loading="lazy" />
```

Use the actual aspect ratio your designs use (square cards → 1:1, e.g., `width="600" height="600"`). Add `loading="lazy"` to images below the fold to help LCP.

- [ ] **Step 5: Build and run the prod container**

```bash
cd frontend
docker build --build-arg VITE_API_BASE_URL=http://localhost:8080 -t aibles-fe:lh .
docker run --rm -d -p 8080:8080 --name fe-lh aibles-fe:lh
sleep 1
```

- [ ] **Step 6: Run Lighthouse**

Open Chrome → http://localhost:8080 → DevTools → Lighthouse panel → Mobile + Desktop, Categories: Performance, Accessibility, Best Practices, SEO. Run for `/`, `/products/:id` (pick any product), `/cart`, `/account/orders` (login first).

Targets:
- Performance ≥ 80
- Accessibility ≥ 95
- Best Practices ≥ 95
- SEO ≥ 90

If any score misses, address the specific findings (e.g., compress images, add `<meta name="description">` if it didn't apply, fix a contrast warning) and re-run.

```bash
docker stop fe-lh
```

- [ ] **Step 7: Run tests**

```bash
pnpm test 2>&1 | tail -5
```

- [ ] **Step 8: Commit**

```bash
git add frontend/index.html \
        frontend/src/composables/usePageMeta.ts \
        frontend/src/pages/HomePage.vue \
        frontend/src/pages/ProductDetailPage.vue \
        frontend/src/pages/CartPage.vue \
        frontend/src/pages/account/OrdersPage.vue
# plus any product-image components you patched:
git add frontend/src/components/domain/ProductCard.vue 2>/dev/null || true
git commit -m "perf(fe): per-route meta, image dimensions, apple-touch-icon"
```

---

## Slice 4 — Console Sweep + README

### Task 14: Console-warning sweep + lint warnings to zero

**Files:**
- Modify: `frontend/package.json`
- Modify: `frontend/src/components/primitives/BTag.vue`
- Modify: `frontend/src/components/primitives/BToast.vue`
- Possibly modify: any page that emits a console warning during a clean load

- [ ] **Step 1: Fix duplicate `api:gen` key in `frontend/package.json`**

Read the current `scripts` block:

```bash
grep -n '"api:gen"' frontend/package.json
```

There are two entries (lines 7 and 17). Remove the duplicate at line 17. Final `scripts` block should contain `api:gen` once.

- [ ] **Step 2: Fix `BTag.vue` `rotate` prop default**

```bash
grep -A5 "interface Props" frontend/src/components/primitives/BTag.vue
```

Patch with `withDefaults`. Current likely shape:

```ts
interface Props {
  variant?: 'spot' | 'paper';
  rotate?: number;
}
const props = defineProps<Props>();
```

Change to:

```ts
interface Props {
  variant?: 'spot' | 'paper';
  rotate?: number;
}
const props = withDefaults(defineProps<Props>(), {
  variant: 'paper',
  rotate: 0,
});
```

- [ ] **Step 3: Fix `BToast.vue` `body` prop default**

Same pattern. `body` is optional; default to `''` or `undefined`. Use `withDefaults`:

```ts
const props = withDefaults(defineProps<Props>(), {
  variant: 'info',
  body: '',
});
```

(Adjust to the actual prop set in your file.)

- [ ] **Step 4: Run lint**

```bash
cd frontend
pnpm lint 2>&1 | tail -15
```

Expected: warning count drops from 10 to 0 (or near-zero — the original 10 included these prop defaults).

- [ ] **Step 5: Sweep console on every page**

Start dev server:

```bash
pnpm dev
```

Open Chrome → DevTools Console → load each route in turn:

- `/` (logged out + logged in)
- `/products/:someId`
- `/cart`
- `/checkout` (with cart items)
- `/payment/success?orderId=x`, `/payment/cancel?orderId=x`
- `/login`, `/register`, `/activate?token=x`
- `/404nonexistent` (NotFoundPage)
- `/account/profile`, `/account/orders`, `/account/orders/:id`

For each warning that appears, identify the source and fix. Common patterns:
- `[Vue Router warn]: No match found for location with path ""` — empty `<RouterLink to="">` somewhere; fix the binding.
- `Failed prop type` / `Prop validation failed` — fix the prop type or the consumer.
- `Hydration mismatch` — n/a (we're SPA, no SSR).
- `Invalid value for v-model` — usually a `null`/`undefined` initial state on a form binding.

- [ ] **Step 6: Re-run full DoD**

```bash
pnpm test && pnpm typecheck && pnpm lint
```

Expected:
- `pnpm test`: all green.
- `pnpm typecheck`: no errors.
- `pnpm lint`: 0 errors, 0 warnings.

- [ ] **Step 7: Commit**

```bash
git add frontend/package.json \
        frontend/src/components/primitives/BTag.vue \
        frontend/src/components/primitives/BToast.vue
# plus any console-warning fixes
git commit -m "chore(fe): zero lint warnings and clean console on all pages"
```

---

### Task 15: frontend/README.md

**Files:**
- Create: `frontend/README.md`

- [ ] **Step 1: Write `frontend/README.md`**

```markdown
# Issue Nº01 Storefront

Vue 3 + TypeScript + Vite frontend for the AIBLES microservice e-commerce platform. Talks to the gateway on port 8080 (proxied from `/api/*` in dev) and is deployable as a Docker image to any container runtime (k8s + AWS in production).

## Run locally

Requires Node ≥ 20 and pnpm ≥ 9.

```bash
pnpm install
pnpm dev   # starts Vite on http://localhost:5173
```

The dev server proxies `/api/*` to `http://localhost:8080` (the backend gateway). Bring the backend up first via `make up` from the repo root.

Override the API base URL via env var:

```bash
VITE_API_BASE_URL=http://staging.example.com/api pnpm dev
```

## Run tests

```bash
pnpm test         # Vitest, runs once
pnpm test:watch   # Vitest watch mode
pnpm typecheck    # vue-tsc, no emit
pnpm lint         # ESLint
pnpm format       # Prettier --write
```

Tests live under `tests/`:

- `tests/unit/components/` — primitives + domain components
- `tests/unit/pages/` — page-level tests using `@testing-library/vue` + `vi.mock`
- `tests/unit/api/` — API client tests
- `tests/unit/router/` — routing/guard tests
- `tests/e2e/` — reserved for Playwright (deferred)

## Deploy

The frontend ships as a Docker image: a multi-stage build that produces a static `dist/` and serves it via Caddy on port 8080.

```bash
docker build \
  --build-arg VITE_API_BASE_URL=https://api.example.com \
  -t aibles-fe:$(git rev-parse --short HEAD) \
  ./frontend
```

Push to your registry (ECR or other):

```bash
docker tag aibles-fe:$(git rev-parse --short HEAD) <your-ecr-uri>:$(git rev-parse --short HEAD)
docker push <your-ecr-uri>:$(git rev-parse --short HEAD)
```

### k8s expectations

- The image listens on port **8080**.
- The cluster Ingress is responsible for:
  - Terminating TLS.
  - Proxying `/api/*` to the gateway service (the image does **not** proxy `/api`).
  - The Ingress can also handle SPA fallback, but the image already does it (Caddy `try_files {path} /index.html`), so no special Ingress config is needed.
- `VITE_API_BASE_URL` is **build-time** — set it in the Dockerfile build args per environment. To support staging/prod from the same image, switch to a runtime entrypoint that rewrites the URL into `dist/index.html`; not needed for v1.

### Local prod-build smoke test

```bash
docker build --build-arg VITE_API_BASE_URL=/api -t aibles-fe:dev ./frontend
docker run --rm -p 8080:8080 aibles-fe:dev
# open http://localhost:8080
```

## Project layout

```
frontend/
  src/
    api/           # OpenAPI-generated types + TanStack Query hooks
    components/
      domain/      # business components (OrderItemRow, ProductCard, …)
      layout/      # AppNav and other shells
      primitives/  # design-system primitives (BButton, BInput, BDialog, …)
    composables/   # reusable composition functions (useToast, usePageMeta, …)
    layouts/       # route-level layouts (AccountLayout, …)
    lib/           # zod schemas, error helpers
    pages/         # route components
    stores/        # Pinia stores (auth, cart)
    styles/        # global CSS (tokens, fonts, base)
  Dockerfile       # multi-stage: builder (node:20-alpine) → runtime (caddy:2-alpine)
  Caddyfile        # SPA fallback, 3 lines
  vite.config.ts   # dev proxy config
```

## Design system

Editorial / risograph aesthetic. Single `--spot` accent (orange), uppercase mono kickers, outlined display numerals. Status vocabulary: PENDING / IN PRESS / PAID / VOIDED / MISFIRE.

Tokens live in `src/styles/tokens.css`. Don't hard-code colors, fonts, or spacing — use the CSS custom properties (`var(--ink)`, `var(--space-4)`, etc.).
```

- [ ] **Step 2: Verify it renders cleanly**

```bash
# eyeball it:
head -40 frontend/README.md
```

- [ ] **Step 3: Commit**

```bash
git add frontend/README.md
git commit -m "docs(fe): add README with run/test/deploy sections"
```

---

## PR

### Task 16: Push branch and open PR

**Files:** none (git only)

- [ ] **Step 1: Run full DoD one more time**

```bash
cd frontend
pnpm test && pnpm typecheck && pnpm lint
```

Expected: all green, 0 lint warnings.

- [ ] **Step 2: Build the prod container one more time as a smoke**

```bash
docker build --build-arg VITE_API_BASE_URL=/api -t aibles-fe:final ./frontend
docker run --rm -d -p 8080:8080 --name fe-smoke aibles-fe:final
sleep 1
curl -sI http://localhost:8080/ | head -1
docker stop fe-smoke
```

Expected: `HTTP/1.1 200 OK`.

- [ ] **Step 3: Push branch**

```bash
cd /Users/sonanh/Documents/AIBLES/microservice-ecommerce
git push -u origin feat/phase-7-polish-deploy
```

- [ ] **Step 4: Open PR**

```bash
gh pr create --base main --head feat/phase-7-polish-deploy --title "Phase 7: Polish + Deploy" --body "$(cat <<'EOF'
## Summary

- **Deploy artifact:** multi-stage Dockerfile (node:20-alpine builder → caddy:2-alpine runtime, port 8080) with a 3-line Caddyfile for SPA fallback. No nginx config, no docker-compose entry, no in-repo k8s manifests — cluster Ingress handles `/api/*` proxy and TLS.
- **Mobile responsive:** every screen (12 pages + AppNav + AccountLayout) renders cleanly at 375 / 768 / 1024+ px. AppNav collapses to a hamburger below 768px.
- **A11y baseline:** skip-link, global `:focus-visible` rings, primitive ARIA sweep (BInput aria-describedby/invalid, BStamp/BCropmarks aria-hidden, BToast role=status/alert, OrderStatusStamp aria-label). WCAG AA contrast verified; keyboard nav verified across all 12 pages.
- **Lighthouse:** mobile + desktop pass on `/`, `/products/:id`, `/cart`, `/account/orders` — Performance ≥ 80, A11y ≥ 95, Best Practices ≥ 95, SEO ≥ 90. Per-route meta description via small `usePageMeta` composable; product images get explicit dimensions.
- **Polish:** 0 console warnings on clean load; 0 lint warnings (down from 10); duplicate `api:gen` key removed.
- **Docs:** `frontend/README.md` with Run / Test / Deploy sections.

## Test plan

- [x] `pnpm test && pnpm typecheck && pnpm lint` — all green, 0 warnings
- [x] `docker build` succeeds, `docker run -p 8080:8080` serves SPA, deep links resolve
- [x] Manual viewport sweep at 375 / 768 / 1024 px on every page
- [x] axe-devtools clean on every page
- [x] Lighthouse mobile + desktop hits targets on the four target screens
- [x] Keyboard-only navigation works on every page
- [ ] Manual smoke against deployed image in your k8s cluster (post-merge)

## Out of scope (deferred)

- Playwright E2E golden paths
- Per-error-class unit-test coverage
- k8s manifests / Helm chart in this repo (lives in your infra repo)
- Staging/prod runtime env switching (build-arg approach for v1)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 5: Verify PR is open**

```bash
gh pr view --json state,url
```

Expected: `state: OPEN`, URL printed.

---

## Definition of Done (whole phase)

- [ ] `frontend/Dockerfile` builds; `docker run -p 8080:8080 aibles-fe:dev` serves the SPA, deep-link `/account/orders` resolves via Caddy fallback. Image size ≤ 80 MB.
- [ ] All 12 pages render cleanly at 375 / 768 / 1024+ px. No horizontal scroll, no content overlap.
- [ ] axe-devtools shows zero violations on every page (manual sweep).
- [ ] Lighthouse on `/`, `/products/:id`, `/cart`, `/account/orders` (mobile + desktop) hits Performance ≥ 80, A11y ≥ 95, Best Practices ≥ 95, SEO ≥ 90.
- [ ] Zero console warnings on fresh load of every page in dev mode.
- [ ] `pnpm test && pnpm typecheck && pnpm lint` green; lint warning count = 0.
- [ ] `frontend/README.md` exists with three non-trivial sections.
- [ ] PR open against main.
