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
