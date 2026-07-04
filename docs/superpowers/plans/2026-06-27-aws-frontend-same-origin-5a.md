# Phase 5a — Storefront SPA same-origin on the raw ALB (HTTP) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After `make aws-all`, an operator opens `http://<alb-host>/` and can run the full storefront funnel (browse → login → cart → checkout → mock-PayPal → result) over one ALB, one origin, HTTP, no domain.

**Architecture:** The existing gateway ALB gains a second backend. The Vue SPA is served at `/` by Caddy; everything under a known `/<service>` prefix routes to the gateway. The SPA is built with an empty `VITE_API_BASE_URL` so every API call is **relative** → same-origin → no CORS, no build-time API base. Browser-facing server URLs (payment redirect, mock-paypal approve link) are seeded as relative paths so they resolve against whatever origin the browser is on (and survive the Phase 5b domain migration unchanged).

**Tech Stack:** Kustomize overlays (AWS Load Balancer Controller / ALB Ingress), Bash build+seed scripts, Vue 3 SPA (Caddy static serve), AWS Secrets Manager (via ESO).

**Source spec:** `docs/superpowers/specs/2026-06-27-aws-frontend-same-origin-5a-design.md`

**Branch:** `feat/aws-deploy` (continuation — do NOT branch off main).

**Ownership:** Entirely Claude-owned. **No Terraform, no HUMAN checkpoints.** All AWS-networking Terraform (Route 53, ACM, external-dns, S3 CORS) is Phase 5b.

---

## ⚠️ Spec deviation captured during planning (read before Task 3)

The spec's Component 3 says set the mock-paypal `public-base-url` to `""`. **That is wrong** — ground-truth verification found a route collision:

- mock-paypal runs with `context-path: /mock-paypal-service` and `@GetMapping("/checkout")` → it is served at `/mock-paypal-service/checkout`.
- `OrdersController` builds `approveHref = publicBaseUrl + "/checkout?token=…"`.
- With `publicBaseUrl=""` the approve link becomes `/checkout?token=…`, which **collides with the SPA's own `/checkout` route** (`CheckoutPage`). The ALB `/` catch-all would send it to the SPA, not the mock.

**Correct value: `/mock-paypal-service`** (relative, prefix preserved) → approve link `/mock-paypal-service/checkout?token=…` → ALB `/mock-paypal-service/*` → gateway → mock-paypal. The `self` link (`/mock-paypal-service/v2/checkout/orders/…`) and the checkout-page decision links also need the prefix, so `/mock-paypal-service` is right for every use.

The payment redirect base (`application.frontend.base-url`) stays `""` — its target (`/payment/success`, `/payment/cancel`) **is** a real SPA route, so the empty base + `/` catch-all is exactly what we want. The asymmetry is intentional and is the heart of this phase: relative URLs route to the SPA unless they carry a `/<service>` prefix.

> **Note on "tests":** this plan changes Kustomize YAML and Bash scripts — there is no unit-test harness to go red→green. The TDD analogue here is the **offline verification gate**: `bash -n` (syntax), `kubectl kustomize` (render), and `grep` assertions on the rendered/edited output. Each task's "verify" step is the gate; run it and confirm the stated expected output before committing.

---

## File map

| File | Change |
|---|---|
| `k8s/images/build.sh` | `:-` → `-` on the frontend build-arg; fix stale comment |
| `scripts/aws/push-images.sh` | export `VITE_API_BASE_URL=""` (AWS frontend builds relative) |
| `scripts/aws/seed-secrets.sh` | `frontend.base-url` → `""`; mock `public-base-url` → `/mock-paypal-service` |
| `k8s/apps/overlays/aws/frontend/` | **new** hand-written overlay (base workload + ECR image swap + Service health check) |
| `scripts/aws/gen-aws-overlay.sh` | add `frontend` to the never-overwrite allowlist |
| `k8s/apps/overlays/aws/ingress-gateway.yaml` | reshape to 8 service-prefix paths → gateway + `/` → frontend; drop Ingress-level health check |
| `k8s/apps/overlays/aws/gateway/kustomization.yaml` | add gateway-Service health-check patch (per-target-group) |
| `k8s/apps/overlays/aws/kustomization.yaml` | add `frontend` to resources |
| `scripts/aws/up-all.sh` | print the storefront link in the final banner |

---

## Task 1: `build.sh` — honor an empty `VITE_API_BASE_URL`

**Files:**
- Modify: `k8s/images/build.sh:78-89` (the `build_frontend` function)

- [ ] **Step 1: Make the change**

Replace the `build_frontend` body so the build-arg uses `${VITE_API_BASE_URL-…}` (no colon) and the comment is accurate. Old:

```bash
build_frontend() {
  reuse_or_build "frontend" && return 0
  echo "==> building frontend"
  # VITE_API_BASE_URL is inlined at build time. Browser calls hit the
  # api.* Ingress; the SPA itself is served from microecom.local.
  docker build \
    -f frontend/Dockerfile \
    --build-arg "VITE_API_BASE_URL=${VITE_API_BASE_URL:-http://api.microecom.local}" \
    -t "${REGISTRY}/frontend:${TAG}" \
    frontend
  docker push "${REGISTRY}/frontend:${TAG}"
}
```

New:

```bash
build_frontend() {
  reuse_or_build "frontend" && return 0
  echo "==> building frontend"
  # VITE_API_BASE_URL is inlined at build time (Vite compiles env vars in).
  #   - local/kind (var UNSET): defaults to http://api.microecom.local (nginx host).
  #   - AWS (var set to ""): kept empty → the SPA issues RELATIVE calls
  #     (fetch('/bff-service/v1/…')) and is served same-origin behind the ALB.
  # The dash (no colon) is load-bearing: ${VAR-default} only falls back when the
  # var is UNSET, so an intentional empty value from AWS survives. ${VAR:-default}
  # would clobber the empty string back to the local host.
  docker build \
    -f frontend/Dockerfile \
    --build-arg "VITE_API_BASE_URL=${VITE_API_BASE_URL-http://api.microecom.local}" \
    -t "${REGISTRY}/frontend:${TAG}" \
    frontend
  docker push "${REGISTRY}/frontend:${TAG}"
}
```

- [ ] **Step 2: Verify syntax + the substitution change**

Run: `bash -n k8s/images/build.sh && grep -n 'VITE_API_BASE_URL-http' k8s/images/build.sh`
Expected: no syntax error; grep prints the line with `${VITE_API_BASE_URL-http://api.microecom.local}` (dash, no colon). A `grep -n 'VITE_API_BASE_URL:-' k8s/images/build.sh` should print nothing.

- [ ] **Step 3: Commit**

```bash
git add k8s/images/build.sh
git commit -m "fix(build): honor empty VITE_API_BASE_URL so AWS builds the SPA relative

\${VAR:-default} clobbered an intentional empty value back to the local host;
\${VAR-default} only falls back when unset. Lets the AWS frontend image issue
same-origin relative API calls.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `push-images.sh` — relative API base for every AWS frontend build

**Files:**
- Modify: `scripts/aws/push-images.sh:18-23` (after `set -euo pipefail`, with the other exports)

- [ ] **Step 1: Make the change**

`push-images.sh` only ever pushes to ECR (AWS), so the frontend image should always be same-origin/relative. Add an exported empty `VITE_API_BASE_URL` next to the existing env setup. Old (lines 18-23):

```bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
REGION="${AWS_REGION:-ap-southeast-1}"
TAG="${TAG:-dev}"
```

New:

```bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-microecom}"
REGION="${AWS_REGION:-ap-southeast-1}"
TAG="${TAG:-dev}"

# AWS serves the SPA same-origin behind the gateway ALB, so the frontend image
# must be built with an EMPTY API base → the SPA issues relative calls
# (fetch('/bff-service/v1/…')). build.sh uses ${VITE_API_BASE_URL-default}
# (no colon), so this empty value is preserved rather than falling back.
export VITE_API_BASE_URL=""
```

- [ ] **Step 2: Verify syntax + the export**

Run: `bash -n scripts/aws/push-images.sh && grep -n 'export VITE_API_BASE_URL=""' scripts/aws/push-images.sh`
Expected: no syntax error; grep prints the `export VITE_API_BASE_URL=""` line.

- [ ] **Step 3: Commit**

```bash
git add scripts/aws/push-images.sh
git commit -m "feat(aws): build the frontend image with empty VITE_API_BASE_URL

AWS serves the SPA same-origin behind the gateway ALB; an empty base makes the
SPA issue relative API calls, dissolving CORS and the build-time API URL.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `seed-secrets.sh` — relative browser-facing URLs

**Files:**
- Modify: `scripts/aws/seed-secrets.sh:173` (payment `frontend.base-url`)
- Modify: `scripts/aws/seed-secrets.sh:188-191` (mock `public-base-url`)

- [ ] **Step 1: Payment redirect base → empty (target is a real SPA route)**

In the `put payment-service` block, change line 173. Old:

```bash
  "application.frontend.base-url":"http://microecom.local",
```

New:

```bash
  "application.frontend.base-url":"",
```

`IPNPaypalController` does `URI.create(frontendBaseUrl + "/payment/success" + suffix)` → with `""` it yields a **relative** `Location: /payment/success?orderId=…`. The browser resolves that against the shop origin; the ALB `/` catch-all serves the SPA, whose router renders `PaymentResultPage`. No payment code change; the payment pod must restart to re-read the value (it does on `make aws-all`).

- [ ] **Step 2: Mock approve base → `/mock-paypal-service` (prefix preserved — NOT empty)**

In the `put mock-paypal-service` block, change line 190. Old:

```bash
put mock-paypal-service "$(jq -n '{
  "server.port":"8585",
  "mock.public-base-url":"http://api.microecom.local/mock-paypal-service"
}')"
```

New:

```bash
put mock-paypal-service "$(jq -n '{
  "server.port":"8585",
  "mock.public-base-url":"/mock-paypal-service"
}')"
```

**Why `/mock-paypal-service` and not `""`:** `OrdersController` builds `publicBaseUrl + "/checkout?token=…"`. An empty base would produce `/checkout?token=…`, which collides with the SPA's own `/checkout` route and would be served by the SPA instead of the mock. Keeping the `/mock-paypal-service` prefix makes the approve link `/mock-paypal-service/checkout?token=…` → ALB `/mock-paypal-service/*` → gateway → mock-paypal, and the SPA navigates to it same-origin via `window.location.href`.

- [ ] **Step 3: Verify syntax + both values + that local seed is untouched**

Run:
```bash
bash -n scripts/aws/seed-secrets.sh
grep -n '"application.frontend.base-url":""' scripts/aws/seed-secrets.sh
grep -n '"mock.public-base-url":"/mock-paypal-service"' scripts/aws/seed-secrets.sh
grep -n 'microecom.local' scripts/aws/seed-secrets.sh
```
Expected: no syntax error; the first two greps each print exactly one line; the third grep prints **nothing** (both `microecom.local` references are gone — there is no separate local-Vault seed in this file to worry about).

- [ ] **Step 4: Commit**

```bash
git add scripts/aws/seed-secrets.sh
git commit -m "feat(aws): seed relative browser-facing URLs for same-origin storefront

payment frontend.base-url='' → relative /payment/success redirect (a real SPA
route). mock public-base-url='/mock-paypal-service' (NOT '') → relative approve
link that keeps the routing prefix and avoids colliding with the SPA /checkout
route. Both resolve against whatever origin the browser is on.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: new `k8s/apps/overlays/aws/frontend/` overlay dir

**Files:**
- Create: `k8s/apps/overlays/aws/frontend/kustomization.yaml`

- [ ] **Step 1: Create the overlay**

References the base **directory** (not individual files — kustomize's `LoadRestrictionsRootOnly`, documented in `k8s/CLAUDE.md`, forbids out-of-tree file references) and deletes the local nginx `ingress.yaml` via `$patch:delete`, exactly mirroring the `gateway/` overlay. Swaps the image to ECR. Adds a frontend-specific ALB health check on the **Service** (per-target-group), because the static SPA has no actuator endpoint — it must not inherit the gateway's `/actuator/health/readiness:19093` check.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Hand-written AWS overlay for the storefront SPA. Mirrors the gateway/ overlay:
# pull the base workload, swap the image to ECR. Unlike a backend service there is
# NO ExternalSecret / spring-secrets — the SPA is static (the API base is baked at
# build time as an empty string → relative calls), so it needs no runtime secrets.
#
# We reference the base kustomization directory (not individual files) so that
# kustomize's LoadRestrictionsRootOnly policy is satisfied. The base bundles the
# local nginx ingress.yaml which we must not deploy on AWS — it is deleted via the
# $patch:delete below. The ALB Ingress is ingress-gateway.yaml.
resources:
  - ../../../base/frontend

# Per-target-group ALB health check for the SPA: the AWS Load Balancer Controller
# reads alb.ingress.kubernetes.io/healthcheck-* annotations from the backing
# Service and applies them to that Service's target group only. Caddy answers 200
# on "/" the moment it starts, so probe "/" on the traffic port. This overrides the
# gateway's 19093/actuator check (which would fail against a static file server).
patches:
  - target: { kind: Ingress, name: frontend, namespace: apps }
    patch: |-
      $patch: delete
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata: { name: frontend, namespace: apps }
  - target: { kind: Service, name: frontend, namespace: apps }
    patch: |-
      apiVersion: v1
      kind: Service
      metadata:
        name: frontend
        namespace: apps
        annotations:
          alb.ingress.kubernetes.io/healthcheck-port: traffic-port
          alb.ingress.kubernetes.io/healthcheck-path: /

images:
  - name: localhost:5001/frontend
    newName: 583178372344.dkr.ecr.ap-southeast-1.amazonaws.com/frontend
    newTag: dev
```

- [ ] **Step 2: Verify the overlay renders in isolation**

Run: `kubectl kustomize k8s/apps/overlays/aws/frontend`
Expected: prints a `Deployment` and a `Service` named `frontend`; the Deployment `image:` is `583178372344.dkr.ecr.ap-southeast-1.amazonaws.com/frontend:dev`; the Service carries the two `alb.ingress.kubernetes.io/healthcheck-*` annotations; **no** `Ingress` object appears.

- [ ] **Step 3: Fix the stale comment in the base deployment**

The base `deployment.yaml` comment still claims the API URL is baked in. Modify `k8s/apps/base/frontend/deployment.yaml:17-19`. Old:

```yaml
          # Caddy serving the Vite build output. Image built from
          # frontend/Dockerfile with VITE_API_BASE_URL=http://api.microecom.local
          # baked in at build time (Vite inlines env vars at compile).
```

New:

```yaml
          # Caddy serving the Vite build output. The API base URL is baked in at
          # build time (Vite inlines env vars). Local/kind bakes
          # http://api.microecom.local; the AWS overlay builds it empty so the SPA
          # issues relative, same-origin calls behind the gateway ALB.
```

- [ ] **Step 4: Verify the comment edit didn't break the base render**

Run: `kubectl kustomize k8s/apps/base/frontend >/dev/null && echo OK`
Expected: prints `OK` (base still renders; the local overlay path is unaffected).

- [ ] **Step 5: Commit**

```bash
git add k8s/apps/overlays/aws/frontend/kustomization.yaml k8s/apps/base/frontend/deployment.yaml
git commit -m "feat(aws): hand-written frontend overlay (ECR image + SPA health check)

Pulls the base deployment+service (not the base nginx ingress), swaps to the ECR
image, and probes '/' on the traffic port so the static SPA target group passes
its own ALB health check instead of inheriting the gateway's 19093/actuator one.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: protect the new overlay from the generator

**Files:**
- Modify: `scripts/aws/gen-aws-overlay.sh:19` (the `HANDWRITTEN` allowlist)

- [ ] **Step 1: Add `frontend` to the never-overwrite allowlist**

`gen-aws-overlay.sh` regenerates per-service overlays for any service with a base dir not in `HANDWRITTEN`. `frontend` has a base dir, so without this guard a regen would clobber the hand-written overlay from Task 4. Old:

```bash
HANDWRITTEN=" gateway authorization-server "
```

New:

```bash
HANDWRITTEN=" gateway authorization-server frontend "
```

- [ ] **Step 2: Verify syntax + the allowlist + the word-match logic**

Run:
```bash
bash -n scripts/aws/gen-aws-overlay.sh
grep -n 'HANDWRITTEN=" gateway authorization-server frontend "' scripts/aws/gen-aws-overlay.sh
```
Expected: no syntax error; grep prints the updated line. (The skip test is `[[ "$HANDWRITTEN" == *" $svc "* ]]`; with the surrounding spaces, `" frontend "` now matches and `frontend` is skipped.)

- [ ] **Step 3: Commit**

```bash
git add scripts/aws/gen-aws-overlay.sh
git commit -m "chore(aws): allowlist frontend in gen-aws-overlay so it never clobbers it

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: reshape the ALB Ingress to two backends + per-target-group health checks

**Files:**
- Modify: `k8s/apps/overlays/aws/ingress-gateway.yaml` (whole file)
- Modify: `k8s/apps/overlays/aws/gateway/kustomization.yaml` (add gateway-Service health-check patch)
- Modify: `k8s/apps/overlays/aws/kustomization.yaml:7-18` (add `frontend` to resources)

- [ ] **Step 1: Reshape `ingress-gateway.yaml`**

Replace the single `/` → gateway rule with the 8 service prefixes → gateway and `/` → frontend. Drop the Ingress-level health-check annotations (they move per-Service: gateway's onto the gateway Service in Step 2, frontend's already on the frontend Service from Task 4). Keep host-less + HTTP-only (TLS + host are Phase 5b). Full new file:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gateway-alb
  namespace: apps
  labels: { app: gateway }
  annotations:
    # Public-facing ALB (lives in the public subnets tagged kubernetes.io/role/elb).
    alb.ingress.kubernetes.io/scheme: internet-facing
    # target-type: ip → the ALB registers pod IPs directly as targets. Works
    # because the pods sit in the private subnets tagged
    # kubernetes.io/role/internal-elb (Phase 1). instance mode would instead
    # need a NodePort Service.
    alb.ingress.kubernetes.io/target-type: ip
    # NOTE: health checks are NOT set here. With two backends (gateway + frontend)
    # an Ingress-level check would apply to BOTH target groups, and the gateway's
    # 19093/actuator probe would fail the static SPA. Each Service carries its own
    # alb.ingress.kubernetes.io/healthcheck-* annotations instead (per-target-group).
spec:
  ingressClassName: alb
  # No host: match every Host header. On EKS we hit the raw *.elb.amazonaws.com
  # DNS, so a host rule would 404. Phase 5b adds shop.microecom.click once
  # Route 53 + ACM are in place.
  #
  # Listener-rule precedence is by path specificity: the AWS Load Balancer
  # Controller expands a Prefix path "/foo" into ALB conditions "/foo" + "/foo/*"
  # and "/" into "/*" (the catch-all, lowest priority). So the 8 service prefixes
  # out-rank "/" regardless of the order they appear here, and only genuine
  # /<service>/** traffic reaches the gateway — everything else boots the SPA.
  # Docs: https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/spec/
  rules:
    - http:
        paths:
          - path: /authorization-server
            pathType: Prefix
            backend: { service: { name: gateway, port: { name: http } } }
          - path: /bff-service
            pathType: Prefix
            backend: { service: { name: gateway, port: { name: http } } }
          - path: /product-service
            pathType: Prefix
            backend: { service: { name: gateway, port: { name: http } } }
          - path: /order-service
            pathType: Prefix
            backend: { service: { name: gateway, port: { name: http } } }
          - path: /payment-service
            pathType: Prefix
            backend: { service: { name: gateway, port: { name: http } } }
          - path: /inventory-service
            pathType: Prefix
            backend: { service: { name: gateway, port: { name: http } } }
          - path: /orchestrator-service
            pathType: Prefix
            backend: { service: { name: gateway, port: { name: http } } }
          - path: /mock-paypal-service
            pathType: Prefix
            backend: { service: { name: gateway, port: { name: http } } }
          # Catch-all: the SPA. Boots Caddy, which serves index.html for any path
          # not matched above (try_files {path} /index.html), then Vue Router takes
          # over for deep links like /checkout, /products/123, /payment/success.
          - path: /
            pathType: Prefix
            backend: { service: { name: frontend, port: { number: 80 } } }
```

- [ ] **Step 2: Add the gateway-Service health-check patch**

The gateway target group still needs the 19093/actuator probe (the gateway 404s on `/`). Add it to the gateway Service in the gateway overlay. Modify `k8s/apps/overlays/aws/gateway/kustomization.yaml`. Old:

```yaml
patches:
  - path: patch-volume.yaml
  - target: { kind: Ingress, name: gateway, namespace: apps }
    patch: |-
      $patch: delete
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata: { name: gateway, namespace: apps }
```

New:

```yaml
patches:
  - path: patch-volume.yaml
  - target: { kind: Ingress, name: gateway, namespace: apps }
    patch: |-
      $patch: delete
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata: { name: gateway, namespace: apps }
  # Per-target-group ALB health check for the gateway: probe the MANAGEMENT port
  # (19093) /actuator/health/readiness, not the traffic port (6868) which 404s on
  # "/". The AWS Load Balancer Controller reads these from the backing Service.
  - target: { kind: Service, name: gateway, namespace: apps }
    patch: |-
      apiVersion: v1
      kind: Service
      metadata:
        name: gateway
        namespace: apps
        annotations:
          alb.ingress.kubernetes.io/healthcheck-port: "19093"
          alb.ingress.kubernetes.io/healthcheck-path: /actuator/health/readiness
```

- [ ] **Step 3: Register the frontend overlay**

Modify `k8s/apps/overlays/aws/kustomization.yaml` resources. Old:

```yaml
  - mock-paypal-service
  - ingress-gateway.yaml    # the ALB Ingress replacement (unchanged)
```

New:

```yaml
  - mock-paypal-service
  - frontend                # storefront SPA (same-origin, Phase 5a)
  - ingress-gateway.yaml    # the ALB Ingress: 8 service prefixes → gateway, / → frontend
```

- [ ] **Step 4: Verify the full AWS overlay renders with both backends + correct health checks**

Run: `kubectl kustomize k8s/apps/overlays/aws > /tmp/aws-render.yaml && echo "rendered $(wc -l < /tmp/aws-render.yaml) lines"`
Expected: renders without error.

Then assert the routing + health-check shape:
```bash
grep -c 'name: gateway' /tmp/aws-render.yaml                                  # gateway referenced (Service + 8 ingress backends)
grep -E 'path: /(authorization-server|bff-service|product-service|order-service|payment-service|inventory-service|orchestrator-service|mock-paypal-service|)$' /tmp/aws-render.yaml | wc -l   # 9 paths
grep -A40 'kind: Service' /tmp/aws-render.yaml | grep -c 'healthcheck-path: /actuator/health/readiness'   # gateway Service check = 1
grep -A40 'kind: Service' /tmp/aws-render.yaml | grep -c 'healthcheck-path: /$'                            # frontend Service check = 1
```
Expected: the 9-path grep prints `9`; the gateway-actuator health-check count is `1`; the frontend `/` health-check count is `1`. A frontend Deployment + Service must be present (`grep -c 'image: 583178372344.*frontend:dev' /tmp/aws-render.yaml` → at least `1`).

- [ ] **Step 5: Verify no stray Ingress-level health check leaked through**

Run: `grep -B2 -A2 'kind: Ingress' /tmp/aws-render.yaml | grep -c 'healthcheck'`
Expected: `0` — the only `gateway-alb` Ingress has no `healthcheck-*` annotation; all health checks live on Services.

- [ ] **Step 6: Commit**

```bash
git add k8s/apps/overlays/aws/ingress-gateway.yaml k8s/apps/overlays/aws/gateway/kustomization.yaml k8s/apps/overlays/aws/kustomization.yaml
git commit -m "feat(aws): path-route the ALB to gateway + frontend (same-origin storefront)

8 service prefixes → gateway, / → frontend SPA on one ALB. Health checks move
per-target-group onto each Service (gateway 19093/actuator, frontend / on the
traffic port) so the static SPA target group stops inheriting the gateway probe.
Host-less + HTTP only; TLS and the domain are Phase 5b.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: `up-all.sh` — surface the storefront link

**Files:**
- Modify: `scripts/aws/up-all.sh:165-171` (final banner)

- [ ] **Step 1: Add the storefront line**

Give the operator a clickable browser link, not just an API endpoint. Old:

```bash
banner "DONE · stack is up"
ALB="$(kubectl -n apps get ingress gateway-alb \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
echo "  Gateway ALB : ${ALB:-<pending — re-check: kubectl -n apps get ingress gateway-alb>}"
echo "  Verify      : login should return a JWT; catalog lists products; cart shows stock"
echo "  Remember    : 'make aws-down' when done — the cluster bills ~\$0.25-0.30/hr."
```

New:

```bash
banner "DONE · stack is up"
ALB="$(kubectl -n apps get ingress gateway-alb \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
echo "  Gateway ALB : ${ALB:-<pending — re-check: kubectl -n apps get ingress gateway-alb>}"
echo "  Storefront  : http://${ALB:-<pending>}/   ← open in a browser and shop the funnel"
echo "  Verify      : login should return a JWT; catalog lists products; cart shows stock"
echo "  Remember    : 'make aws-down' when done — the cluster bills ~\$0.25-0.30/hr."
```

- [ ] **Step 2: Verify syntax + the new line**

Run: `bash -n scripts/aws/up-all.sh && grep -n 'Storefront  : http://' scripts/aws/up-all.sh`
Expected: no syntax error; grep prints the new storefront line.

- [ ] **Step 3: Commit**

```bash
git add scripts/aws/up-all.sh
git commit -m "feat(aws): print the storefront link in the up-all banner

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (offline, before handoff)

- [ ] **Step 1: All shell scripts parse**

Run: `for f in k8s/images/build.sh scripts/aws/push-images.sh scripts/aws/seed-secrets.sh scripts/aws/gen-aws-overlay.sh scripts/aws/up-all.sh; do bash -n "$f" && echo "ok $f"; done`
Expected: five `ok …` lines.

- [ ] **Step 2: The whole AWS overlay renders**

Run: `kubectl kustomize k8s/apps/overlays/aws >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Cross-check the same-origin contract end to end**

Run:
```bash
grep -n 'VITE_API_BASE_URL-http'           k8s/images/build.sh           # dash, not :-
grep -n 'export VITE_API_BASE_URL=""'      scripts/aws/push-images.sh
grep -n '"application.frontend.base-url":""'        scripts/aws/seed-secrets.sh
grep -n '"mock.public-base-url":"/mock-paypal-service"' scripts/aws/seed-secrets.sh
```
Expected: each grep prints exactly one matching line.

---

## Billed steps (USER — do NOT run from this session)

These hit AWS account `583178372344` / profile `microecom` / region `ap-southeast-1` and cost money. The user runs them.

- [ ] Rebuild + push the frontend image with the empty base, then bring the stack up:
  `PUSH=all make aws-all` (only the **frontend** image strictly needs a rebuild for the empty `VITE_API_BASE_URL`; the payment-service pod must restart to re-read the empty `frontend.base-url`, which `aws-all` handles).
- [ ] Open `http://<alb-host>/` and run the funnel: storefront browse (images load from S3) → register/login → add to cart (stock shows) → checkout → choose `approve` at the mock-paypal page → land on `/payment/success` → confirm the order reaches COMPLETED.
- [ ] `make aws-down` when done (cluster bills ~$0.25–0.30/hr).

---

## Out of scope (Phase 5b)

Route 53 hosted zone + `shop.microecom.click`; ACM cert + DNS validation; ALB HTTPS:443 + HTTP→HTTPS redirect; external-dns + IRSA; S3 CORS for the domain. The relative URLs seeded here keep working unchanged under the domain, so 5b layers TLS on top without re-wiring payment or the SPA. **The user writes that Terraform.**
