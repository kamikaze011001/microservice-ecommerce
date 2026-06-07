# Mock PayPal Service — Design

**Date:** 2026-06-05
**Status:** Approved (design), pending implementation plan
**Branch:** `feat/mock-paypal-service`

## Problem

Stress testing (k6) and local frontend development cannot drive real PayPal
sandbox checkout: it requires a human at PayPal's hosted page, real
credentials, and a public tunnel callback. We need a drop-in mock that lets
both **headless k6 load tests** and the **Vue frontend** complete the full
payment lifecycle — success, cancel, and failure — while keeping
`payment-service` behavior **byte-for-byte identical** to the real PayPal flow.

## Key constraint that makes this clean

`payment-service` reaches PayPal through a **single config knob**:
`application.paypal.base-url` (default `https://api-m.sandbox.paypal.com`,
overridden in Vault at `secret/payment-service`). All five PayPal REST calls in
`core-paypal`'s `PaypalServiceImpl` are built as `baseUrl + <path>`. Pointing
`base-url` at the mock intercepts every call. **No `payment-service` or
`core-paypal` code changes** — only configuration.

The current PayPal flow (for reference):

1. Frontend `POST /payment-service/v1/payments?orderId=` → `PaypalServiceImpl.createOrder`
   (`POST {base}/v2/checkout/orders`) → returns `PaypalOrderSimple` with a
   `links[]` array; frontend does `window.location = approveLink.href`.
2. User approves on PayPal's hosted page → PayPal redirects browser to
   `{PAYPAL_TUNNEL_URL}/payment-service/v1/paypal:success?token={paypalOrderId}`.
3. `IPNPaypalController` success handler → `captureOrder` (`POST {base}/v2/checkout/orders/{token}/capture`)
   → `getOrderDetails` (`GET {base}/v2/checkout/orders/{token}`) → extracts
   `custom_id` (internal orderId) and capture id → `markSuccess` →
   publishes `PaymentSuccess` (Avro/Kafka) → 302 to `{frontend.base-url}/payment/success?orderId=`.
4. Cancel path → `paypal:cancel` → `PaymentCanceled`. Any
   `PaypalRestTemplateException` (4xx/5xx from PayPal) → `PaymentFailed`.

## Goals

- k6 can run the full payment flow headlessly, choosing per-request whether the
  payment **succeeds, is canceled, or fails**.
- The Vue frontend can complete checkout against the mock with a clickable
  mock "PayPal page" (Approve / Cancel / Fail), no PayPal credentials.
- `payment-service` / `core-paypal` code is untouched — switch is config-only.
- Runs both **in k8s** (where the k6-stress Job lives) and **locally via
  docker-compose** (frontend dev parity).

## Non-goals

- Real money, real PayPal accounts, webhooks/IPN signature verification.
- Multi-replica horizontal scaling of the mock (single replica is sufficient;
  see "State & scaling").
- Replacing the real PayPal integration in any production/prod-like profile.

## Architecture

A new standalone module **`mock-paypal-service`**.

- **Spring Boot, Java 24, virtual threads enabled** (`spring.threads.virtual.enabled=true`).
  Each mock request is I/O-light, but a stress test opens thousands of
  concurrent connections; virtual threads absorb that on a single small pod far
  more cheaply than the platform-thread pool the Java 17 services use. This is a
  deliberate, isolated departure from the repo's Java 17 norm — justified
  because the mock is a throwaway test fixture, not a production service.
- **No Vault, no DB, no Kafka, no Eureka.** Pure REST.
- **State:** in-memory `ConcurrentHashMap<token, OrderState>` where
  `OrderState = { orderId (custom_id), amount, currency, returnUrl, cancelUrl,
  decision (null|APPROVE|CANCEL|FAIL), captureId, status }`.

> **Version compatibility note (verify at implementation):** the rest of the
> repo uses Spring Boot 3.3.6, which officially supports up to ~Java 23. Java 24
> likely requires **Spring Boot 3.4.x+**. Because the mock is standalone, pin a
> Java-24-compatible Boot version for *this module only* — it does not affect
> the other services.

## Endpoints

Response JSON shapes must match what `core-paypal` deserializes
(`PaypalOrderSimple`, `PaypalCaptureResponse`, `PaypalRefundResponse`, and order
details exposing `purchase_units[0].custom_id` and
`purchase_units[0].payments.captures[0].id`). All cross-service JSON in this repo
is snake_case (`@JsonNaming(SnakeCaseStrategy)`) — the mock's responses must use
snake_case keys to match.

| # | Endpoint | Behavior |
|---|----------|----------|
| 1 | `POST /v1/oauth2/token` | Return `{ "access_token": "mock-access-token", "token_type": "Bearer", "expires_in": 3600 }`. Ignores Basic auth contents. |
| 2 | `POST /v2/checkout/orders` | Parse `purchase_units[0].custom_id` (=internal orderId), `amount`, and the `payment_source` return/cancel URLs from the request body. Mint a `paypalOrderId` token. Store `OrderState` with `decision=null`, `status=CREATED`. Return `PaypalOrderSimple`-shaped JSON: `id` = token, `status` = `PAYER_ACTION_REQUIRED`, and `links[]` containing `{ "rel": "approve", "href": "{MOCK_PUBLIC_BASE_URL}/checkout?token={id}", "method": "GET" }` (also expose as `payer-action` for client compatibility). |
| 3 | `GET /checkout?token={id}[&decision=approve\|cancel\|fail]` | **The mock "PayPal page."** No `decision` + browser `Accept: text/html` → render a minimal HTML page with three buttons (Approve / Cancel / Fail), each a link to this same endpoint with the `decision` param. With `decision`: record it on the `OrderState`, then `302`: `approve`/`fail` → `returnUrl` (`paypal:success?token=`); `cancel` → `cancelUrl` (`paypal:cancel?token=`). |
| 4 | `POST /v2/checkout/orders/{token}/capture` | If `decision==FAIL` → return **HTTP 422** with a PayPal-shaped error body (triggers `PaypalRestTemplateException` → `PaymentFailed`). Otherwise mint a `captureId`, set `status=CAPTURED`, return `PaypalCaptureResponse`-shaped JSON with `status=COMPLETED` and `purchase_units[0].payments.captures[0].id = captureId`. |
| 5 | `GET /v2/checkout/orders/{token}` | Return order-details JSON exposing `purchase_units[0].custom_id` = internal orderId and (if captured) the capture id. Used by `payment-service` to recover `orderId`/`captureId`. |
| 6 | `POST /v2/payments/captures/{captureId}/refund` | Return `PaypalRefundResponse`-shaped JSON with `status=COMPLETED`. |
| — | `GET /healthz` (or Actuator health) | Liveness/readiness probe target. |

**The decision state machine is the core trick:** the success/cancel/fail choice
is captured at step 3 (the checkout page) and read back at step 4 (capture).
"Fail" redirects to the *success* return URL so `payment-service` proceeds to
call capture, where the mock returns 422 — reproducing exactly what a declined
card looks like to `payment-service`, exercising its real `PaymentFailed` path.

## Flows

### Browser (frontend) — identical to real PayPal from payment-service's view

```
Browser → POST /payment-service/v1/payments?orderId   (via gateway/ingress)
        ← PaypalOrderSimple { links:[approve → {MOCK_PUBLIC_BASE_URL}/checkout?token=X] }
Browser → window.location = approve link
        → GET {mock}/checkout?token=X                 (mock page: Approve/Cancel/Fail)
Browser → click Approve → GET {mock}/checkout?token=X&decision=approve
        ← 302 {PAYPAL_TUNNEL_URL}/payment-service/v1/paypal:success?token=X
Browser → GET paypal:success                          (payment-service)
payment-service → POST {mock}/v2/checkout/orders/X/capture   (server→server)
                → GET  {mock}/v2/checkout/orders/X
                → publishes PaymentSuccess (Kafka)
        ← 302 {frontend.base-url}/payment/success?orderId
Browser → frontend polls order status → COMPLETED
```

Cancel → `decision=cancel` → `paypal:cancel` → `PaymentCanceled`.
Fail → `decision=fail` → `paypal:success` → capture returns 422 → `PaymentFailed`.

### k6 (headless)

```
k6 → POST /payment-service/v1/payments?orderId        (via gateway)
   ← reads approve link → derives token X
k6 → GET {mock}/checkout?token=X&decision=approve|cancel|fail   (no HTML; 302 directly)
   → follows 302 into payment-service callback
   → payment-service runs capture/details → events fire
```

k6 mixes outcomes by varying the `decision` query param across virtual users
(e.g. 90% approve, 5% cancel, 5% fail) to load-test the saga's success and
compensation paths.

## Config & toggle

The only `payment-service`-side change is **configuration**:

- `application.paypal.base-url` → the mock's address.
- `PAYPAL_TUNNEL_URL` → a host reachable by whoever drives the flow (browser via
  ingress; k6 in-cluster).
- `MOCK_PUBLIC_BASE_URL` (mock env) → the base the mock embeds into the `approve`
  link, so the browser can reach the checkout page.

### k8s

- New `Deployment` + `Service` `mock-paypal` in namespace `apps`, `replicas: 1`,
  **no HPA**, probes on `/healthz` (or Actuator). Follows the existing
  `k8s/apps/base/<service>/` layout (deployment.yaml, service.yaml,
  kustomization.yaml).
- **Gateway route `Path=/mock-paypal/**`** → mock Service, so the browser
  reaches the checkout page through ingress (`http://api.microecom.local/mock-paypal/checkout?...`).
- A **kustomize overlay** (e.g. `apps/overlays/<mock|stress>`) that:
  - adds the `mock-paypal` Deployment/Service + gateway route,
  - flips `payment-service`'s Vault `application.paypal.base-url` to
    `http://mock-paypal.apps.svc.cluster.local:8080` (via the vault-seed job
    override for that overlay),
  - sets `PAYPAL_TUNNEL_URL` and `MOCK_PUBLIC_BASE_URL` to the ingress host.
- **k6 reachability:** for the in-cluster k6 Job to follow the 302 into the
  ingress host, give the k6 Job a `hostAliases` entry mapping
  `api.microecom.local` → the ingress-nginx controller ClusterIP (alternative:
  k6 targets the ingress controller Service and sends a `Host: api.microecom.local`
  header). **Chosen default: `hostAliases`**, because it keeps the k6 script's
  URLs identical to the browser's and the redirect resolves naturally.

### local docker-compose

- Add `mock-paypal` to a docker-compose file on a fixed port (e.g. `8099`),
  building/running the module jar.
- Local Vault-seed override: `payment-service` `application.paypal.base-url` →
  `http://localhost:8099`; `PAYPAL_TUNNEL_URL` → `http://localhost:8080`
  (gateway on host); `MOCK_PUBLIC_BASE_URL` → `http://localhost:8099` (browser on
  host reaches the published port).
- **Gated behind a make flag** (e.g. `make up MOCK_PAYPAL=1`) so a normal
  `make up` continues to use real PayPal. **Chosen default: flag on `make up`**
  rather than a separate target, to keep one entrypoint.

## State & scaling

**Single replica, in-memory `ConcurrentHashMap`.** The per-token decision must be
written at the checkout step and read at the capture step; with multiple replicas
behind a Service those could land on different pods and lose the state. A single
replica + virtual threads handles high concurrency on one pod without a shared
store. If horizontal scale is ever needed, swap the map for Redis (keyed by
token) — explicitly out of scope now (YAGNI).

## Testing

- **Mock unit/slice tests** (`MockMvc`): all 6 endpoints + the approve/cancel/fail
  decision state machine (e.g. capture returns 422 only after a `fail` decision;
  approve before capture yields `COMPLETED`; cancel redirects to `cancelUrl`).
- **k6 full-flow scenario** through the gateway exercising a mix of outcomes
  under load, asserting `PaymentSuccess`/`PaymentCanceled`/`PaymentFailed` are
  produced (observed via order status transitions).
- Mock has **no infra deps**, so its tests run in CI with nothing else up.

## Open implementation details (resolved during plan)

- Exact Spring Boot version pinned for Java 24.
- Precise request/response DTO field set mirrored from `core-paypal`'s
  `PaypalOrderRequest` / `PaypalOrderSimple` / `PaypalCaptureResponse` /
  `PaypalRefundResponse` and the order-details shape.
- Overlay naming (`mock` vs `stress`) and how the vault-seed override is layered.
