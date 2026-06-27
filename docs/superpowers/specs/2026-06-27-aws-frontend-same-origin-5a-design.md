# Phase 5a — Storefront SPA on the raw ALB (same-origin, HTTP) — Design

**Status:** approved 2026-06-27
**Branch:** `feat/aws-deploy` (continuation of the AWS deployment workstream)
**Predecessor:** Phase 4d (Redis TLS + AUTH)
**Successor:** Phase 5b (domain + DNS + ACM-TLS — out of scope here)

## Goal

After `make aws-all`, an operator opens `http://<alb-host>/` in a browser and can
run the full storefront funnel — browse → login → cart → checkout (mock PayPal) →
payment result — with no domain and no TLS. The fix closes the "no browser
storefront" gap found in the IaC review.

This phase is **entirely Claude-owned**: k8s manifests, build/seed scripts, and one
config flip. **No Terraform.** All of the AWS-networking Terraform (Route 53, ACM,
external-dns IRSA, S3 CORS) is deferred to Phase 5b, which is the coworking-learning
phase where the user writes the HCL.

## Background — what the review found

`make aws-all` currently yields an **API** endpoint (the gateway ALB), not a browser
storefront. Four blockers were flagged; ground-truth exploration corrected two of
them:

- **C-1 frontend absent from the aws overlay** — real. `k8s/apps/overlays/aws/kustomization.yaml`
  lists 9 backend services + the gateway ingress, no frontend.
- **C-2 frontend base Ingress uses `ingressClassName: nginx`** — real for local, but
  the aws overlay supplies its own ALB ingress; 5a never pulls the base nginx ingress.
- **C-3 the SPA "bakes a localhost API URL"** — *partially wrong.* The SPA already
  supports a relative base: `frontend/Dockerfile:15` defaults `VITE_API_BASE_URL=/api`
  and `frontend/src/api/client.ts:9` reads `import.meta.env.VITE_API_BASE_URL ?? '…'`.
  The real issue is `k8s/images/build.sh:85` *overriding* that with
  `http://api.microecom.local`. An **empty** build-arg makes every call relative.
- **C-4 gateway CORS lacks an AWS origin** — *dissolved.* Serving the SPA same-origin
  with the API means browser XHR is never cross-origin, so the gateway needs no CORS
  change at all.
- **Frontend ECR repo** — already exists (`aws/bootstrap/ecr.tf:60` lists `"frontend"`).

## Architecture — one ALB, one origin

The existing gateway ALB (`k8s/apps/overlays/aws/ingress-gateway.yaml`) gains a second
backend. The Vue SPA is served at `/`; everything under a known `/<service>` prefix
routes to the gateway:

```
http://<alb-host>/                          → frontend Service :80   (Caddy SPA)
http://<alb-host>/assets/*, /favicon, …     → frontend (catch-all "/")
http://<alb-host>/authorization-server/**   → gateway Service :6868
http://<alb-host>/bff-service/**            → gateway
http://<alb-host>/product-service/**        → gateway
http://<alb-host>/order-service/**          → gateway
http://<alb-host>/payment-service/**        → gateway
http://<alb-host>/inventory-service/**      → gateway
http://<alb-host>/orchestrator-service/**   → gateway
http://<alb-host>/mock-paypal-service/**    → gateway
```

The SPA is built with `VITE_API_BASE_URL=""`, so `client.ts` issues **relative** calls
(`fetch('/bff-service/v1/...')`). Browser-side that is same-origin → **no CORS, no
build-time API base, no PayPal-host knowledge needed.**

### Why no SPA route collides with a service prefix

Vue Router runs in `createWebHistory` (`frontend/src/router/index.ts:20`), so deep
links like `/checkout`, `/login`, `/products/123`, `/payment/success` hit the `/`
catch-all → Caddy `try_files {path} /index.html` → the SPA boots and its router takes
over. None of those paths match a `/<service>` prefix:
`/products/:id` ≠ `/product-service`, `/payment/success` ≠ `/payment-service`.

## The one careful bit — ALB listener-rule precedence

The 8 service prefixes must out-rank the `/` catch-all. The AWS Load Balancer
Controller assigns listener-rule priorities by **path specificity**: a `Prefix` path
`/authorization-server` becomes ALB conditions `/authorization-server` +
`/authorization-server/*`, while `/` becomes `/*` (matches everything) and sorts to
the lowest priority. So the service prefixes win regardless of list order. The
implementation plan pins the exact controller behavior with a doc reference and
verifies the rendered ingress offline.

## Components (6, all Claude)

### 1. `k8s/images/build.sh` — honor an empty build-arg
Line 85: change `${VITE_API_BASE_URL:-http://api.microecom.local}` to
`${VITE_API_BASE_URL-http://api.microecom.local}` (drop the colon). With the colon,
an **empty** value still falls back to the local host; without it, only an *unset*
var falls back. This lets AWS pass an intentional empty value while local builds
(var unset) keep the `api.microecom.local` default.

### 2. `scripts/aws/push-images.sh` — relative base for AWS
Export `VITE_API_BASE_URL=""` before invoking `k8s/images/build.sh`, so the AWS
frontend image is built same-origin/relative. Local `k8s/images/build.sh` callers do
not set the var, so their default is preserved.

### 3. `scripts/aws/seed-secrets.sh` — relative browser-facing URLs
- `application.frontend.base-url` (currently `http://microecom.local`, line ~173) → `""`.
  `IPNPaypalController:37,49` does `URI.create(frontendBaseUrl + "/payment/success" + suffix)`,
  so `""` yields a valid **relative** redirect `/payment/success?…` the browser
  resolves against the shop origin. No payment code change, no payment rebuild.
- mock-paypal `public-base-url` (currently `http://api.microecom.local/mock-paypal-service`,
  line ~190) → `""` so the approve/cancel URLs the mock hands back are relative
  (`/mock-paypal-service/...`) and the SPA navigates the browser to them same-origin.
- The local Vault seed in this same script is **not** touched.

**Planning must verify** mock-paypal builds its public URLs by concatenation (not
`new URL`/absolute-required parsing) and that the SPA assigns the approve URL directly
to `window.location` (relative navigation works). If either requires an absolute URL,
fall back to pinning the raw ALB host at seed time instead of `""` for that one value.

### 4. `k8s/apps/overlays/aws/frontend/` (new, hand-written overlay dir)
- `kustomization.yaml` references the base workload only —
  `../../base/frontend/deployment.yaml` and `../../base/frontend/service.yaml` — **not**
  the base nginx `ingress.yaml`.
- `images:` swaps `localhost:5001/frontend` → the ECR repo (mirror how a backend aws
  overlay dir swaps its image).
- Frontend-specific ALB healthcheck via annotations on the **frontend Service**
  (`alb.ingress.kubernetes.io/healthcheck-path: /`, traffic-port), because the SPA has
  no actuator endpoint — the gateway's `/actuator/health/readiness:19093` check must
  not apply to it.
- Add `frontend` to `scripts/aws/gen-aws-overlay.sh`'s never-overwrite allowlist
  (line ~18) so the generator cannot clobber this hand-written dir.
- Fix the stale `VITE_API_BASE_URL=http://api.microecom.local` comment in
  `k8s/apps/base/frontend/deployment.yaml`.

### 5. `k8s/apps/overlays/aws/ingress-gateway.yaml` — reshape to two backends
- Replace the single `/` → gateway rule with the 9-path table above: the 8 service
  prefixes → gateway (`port.name: http`), `/` → frontend (`port.number: 80`).
- Move the gateway's `alb.ingress.kubernetes.io/healthcheck-port: "19093"` +
  `healthcheck-path: /actuator/health/readiness` annotations onto the gateway
  **Service** (per-target-group), so they apply to the gateway target group only and
  the frontend uses its own health check (Component 4).
- Keep the ingress **host-less** (raw `*.elb.amazonaws.com`) and **HTTP only** — TLS
  and the host rule are Phase 5b.
- Add `frontend` to `k8s/apps/overlays/aws/kustomization.yaml` resources.

### 6. `scripts/aws/up-all.sh` — surface the storefront link
The final banner currently prints only the gateway ALB hostname + an API verify hint.
Add a line: `Storefront: http://<alb-host>/` so the operator gets a clickable browser
link, not just an API endpoint.

## Data flow (request routing)

```
browser  ─GET /──────────────────────────► ALB (/* lowest priority) ─► frontend (Caddy) ─► index.html (SPA boot)
         ─GET /assets/app.js──────────────► ALB (/*) ─────────────────► frontend
         ─fetch /product-service/v1/…─────► ALB (/product-service/*) ─► gateway ─► product-service
         ─fetch /bff-service/v1/cart…─────► ALB (/bff-service/*) ─────► gateway ─► bff-service
checkout ─POST /payment-service/…─────────► ALB ─► gateway ─► payment-service
         ◄─302 Location:/payment/success── (relative; browser resolves against http://<alb-host>)
         ─GET /mock-paypal-service/…/checkout (browser, same origin) ─► gateway ─► mock-paypal-service
```

## Verification

### Offline gates (Claude, pre-handoff)
- `kubectl kustomize k8s/apps/overlays/aws` renders successfully and includes the
  frontend Deployment/Service and the reshaped 9-path ingress.
- `bash -n scripts/aws/push-images.sh` and `bash -n scripts/aws/seed-secrets.sh`.
- `bash -n k8s/images/build.sh`.
- grep cross-checks: `VITE_API_BASE_URL=""` in push-images.sh; `frontend.base-url`
  set to `""` in seed-secrets.sh; every service prefix present in the ingress; the `:-`
  → `-` change in build.sh.

### Billed (USER)
- `PUSH=all make aws-all`. Only the **frontend** image actually needs a rebuild (empty
  `VITE_API_BASE_URL`); the payment-service pod must restart to re-read the empty
  `frontend.base-url` from Secrets Manager.
- Open `http://<alb-host>/` and run the funnel: storefront browse (images load from
  S3), register/login, add to cart (stock shows), checkout, choose `approve` at the
  mock-paypal page, land on `/payment/success`, confirm the order reaches COMPLETED.

## Out of scope (YAGNI) — Phase 5b

- Route 53 hosted zone + the `shop.microecom.click` record.
- ACM certificate + DNS validation; ALB HTTPS:443 listener + HTTP→HTTPS redirect.
- external-dns controller + its IRSA role.
- S3 CORS allowed-origin for the domain.
- The pretty `https://shop.microecom.click` link.

The relative redirects set in Component 3 keep working unchanged under the domain
(they resolve against whatever origin the browser is on), so 5b layers TLS on top
without re-wiring payment or the SPA.

## Interview-prep talking points

- Why same-origin (SPA served behind the gateway ALB) **eliminates** CORS and the
  build-time API-base problem instead of fighting them — and how that is the intended
  way to consume a Backend-for-Frontend.
- `${VAR:-default}` vs `${VAR-default}` — why the colon matters when an empty value is
  a legitimate intentional input.
- Relative HTTP redirects (`Location: /payment/success`) — host-agnostic, survive the
  later domain migration with no change.
- ALB listener-rule precedence by path specificity, and why a `/` Prefix is the
  catch-all.
- Per-target-group health checks on one ALB via Service-level annotations (a static
  SPA has no actuator endpoint to probe).
