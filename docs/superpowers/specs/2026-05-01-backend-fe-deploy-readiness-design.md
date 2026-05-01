# Backend FE-Ready + Deploy-Ready Design

**Date:** 2026-05-01
**Status:** Approved
**Scope:** Close the minimum gaps in the existing microservice e-commerce backend so a frontend can be built against it AND so the system can be deployed to k8s/AWS with proper liveness/readiness probes and Prometheus metrics.

## Context

The backend is an event-driven microservice e-commerce platform (Spring Boot 3.3.6 / Java 17 / MySQL master-slave / MongoDB / Redis / Kafka / Vault / S3-compatible MinIO). All core domains exist: auth, profile, products, inventory, cart, orders, payments (PayPal), saga orchestration, and S3 image storage for products and avatars.

This is a **personal learning project**. After this design lands, the next phases are:
1. Build a frontend against this API.
2. Run k6 performance tests on the order creation path.
3. Deploy to AWS (EKS) and learn k8s.

This design is the last backend pass before phase 1.

## Goals

Close exactly the gaps that block phases 1 and 3:
- The frontend can call the API from a browser (cross-origin).
- A visitor can browse products before logging in.
- A user can cancel a pending order through the UI.
- The cluster (kubelet, Prometheus) can observe each service via standard endpoints.

## Non-Goals

The following are intentionally **out of scope** and will not be added:
- HTTP `Idempotency-Key` header on `POST /v1/orders` (separate concern; saga-side dedup already exists for Kafka events).
- Address book / saved shipping addresses (the inline address on `OrderRequest` is sufficient).
- Public categories endpoint (string filter on the product list works).
- Reviews, ratings, wishlist, coupons, dedicated search service.
- Admin order management UI APIs (sales reports, bulk operations).
- k8s manifests, Helm charts, AWS infrastructure-as-code (these belong in a later phase that consumes the actuator endpoints from this design).
- Distributed tracing (OpenTelemetry), custom business metrics, Grafana dashboards.

---

## Section 1 — CORS at Gateway

### Problem

`gateway/src/main/java/org/aibles/gateway/configuration/SecurityConfiguration.java` enables CORS via `http.cors(Customizer.withDefaults())` but no `CorsConfigurationSource` bean is defined. With no source bean, no `Access-Control-Allow-Origin` headers are sent, and any browser-based frontend on a different origin will be blocked.

### Design

Add an explicit `CorsConfigurationSource` reactive bean (gateway is reactive — Spring Cloud Gateway sits on Netty/WebFlux).

**Configuration values** (read from `application.yml`, overridable via Vault for prod):

| Property | Default |
|---|---|
| `application.gateway.cors.allowed-origins` | `http://localhost:3000,http://localhost:5173` |
| `application.gateway.cors.allowed-methods` | `GET,POST,PUT,PATCH,DELETE,OPTIONS` |
| `application.gateway.cors.allowed-headers` | `*` |
| `application.gateway.cors.exposed-headers` | `Authorization` |
| `application.gateway.cors.allow-credentials` | `true` |
| `application.gateway.cors.max-age` | `3600` |

**Why allow-credentials = true:** the JWT travels in the `Authorization` header. Even though it's not strictly a cookie, setting credentials=true is the safest default for a frontend that may also send cookies (refresh-token storage strategies vary).

**Why a single gateway-level CORS:** all external traffic enters via the gateway. Per-service CORS would be redundant and risk inconsistency.

### Files Changed

- `gateway/src/main/java/org/aibles/gateway/configuration/SecurityConfiguration.java` — add `CorsConfigurationSource` bean reading the properties above.
- `gateway/src/main/java/org/aibles/gateway/configuration/CorsProperties.java` (new) — `@ConfigurationProperties("application.gateway.cors")` POJO.
- `gateway/src/main/resources/application.yml` — add `application.gateway.cors.*` defaults.

### Acceptance

- A `curl -X OPTIONS http://localhost:8080/authorization-server/v1/auth:login -H "Origin: http://localhost:3000" -H "Access-Control-Request-Method: POST" -i` preflight response returns `Access-Control-Allow-Origin: http://localhost:3000` and `Access-Control-Allow-Methods` including POST.
- A simple FE on `localhost:3000` can call `POST /authorization-server/v1/auth:login` from `fetch` without a CORS error in the browser console.

---

## Section 2 — Public Product Browse

### Problem

**Current state:** `api_role.json` already has `GET /product-service/v1/products/**` mapped to `PERMIT_ALL`, so the two product GETs are already public per the seed. The genuinely missing piece is `GET /bff-service/v1/products/{productId}`, which has no `api_role` entry. The BFF detail route currently falls through to the default-deny behavior of the `AuthorizationFilter`.

### Design

Add a single `PERMIT_ALL` entry for `GET /bff-service/v1/products/**` to `docker/api_role.json` and re-seed Mongo so the live `api_role` collection picks it up.

| Path | Method | New role |
|---|---|---|
| `/bff-service/v1/products/**` | GET | `PERMIT_ALL` |

Everything else stays login-walled. Specifically:
- All product write ops (POST/PUT/DELETE on `/v1/products/**`) stay `ADMIN`.
- Product image presign/attach stay `ADMIN`.
- Cart, orders, payment, profile, avatar — all stay `AUTHORIZED` or `ADMIN`.

### Files Changed

- `docker/api_role.json` — add one new document for the bff product-detail GET path.
- Operational step (not a code change): re-seed the live `api_role` collection (`make seed-data` or its replacement, after the JSON change).

### Acceptance

- `curl http://localhost:8080/product-service/v1/products` (no Authorization header) returns 200 with the product list.
- `curl http://localhost:8080/product-service/v1/products` with Content-Type and a body — irrelevant; same `PERMIT_ALL` allows it.
- `curl -X POST http://localhost:8080/product-service/v1/products` (no Authorization header) returns 401 (still admin-walled).
- `curl http://localhost:8080/order-service/v1/orders` (no Authorization header) returns 401 (still login-walled).

### Caveats

- `ProductController.list` and `getById`, and `BffController.getProductDetail`, do not currently read `X-User-Id` (verified). No controller-side change is required.

---

## Section 3 — Order Cancellation

### Problem

Frontend will display a user's orders and naturally wants a "Cancel" button on pending ones. No endpoint exists for user-initiated cancellation today. Cancellation only happens implicitly via PayPal IPN cancel callback or saga timeout.

### Design

Add a new endpoint:

```
PATCH /v1/orders/{orderId}:cancel
Auth: user (AUTHORIZED)
Headers: X-User-Id (forwarded by gateway)
Body: none
Response: BaseResponse.ok({ orderId, status: "CANCELED" })
```

**Authorization rule:** the order must belong to the caller. Compare `order.userId == X-User-Id`. Mismatch → `403 Forbidden`.

**State guard:** only `OrderStatus.PROCESSING` is cancellable.
- `COMPLETED` → `409 Conflict`, code `ORDER_NOT_CANCELLABLE`, message "Order already completed".
- `CANCELED` → `409 Conflict`, code `ORDER_ALREADY_CANCELED`, message "Order is already canceled".
- `FAILED` → `409 Conflict`, code `ORDER_NOT_CANCELLABLE`, message "Order failed and cannot be canceled".
- `REFUNDED` → `409 Conflict`, code `ORDER_NOT_CANCELLABLE`, message "Order already refunded".

**Mechanism:** route through the saga rather than directly flipping the status field.

The controller path:
1. Validate ownership and state.
2. Publish an `Order.UserCanceled` Kafka event (or reuse the existing cancellation event the saga already consumes — see "Open Question" below).
3. Return immediately with `status: CANCELED` (optimistic — the saga will compensate inventory asynchronously).

The saga's existing `handleCanceledOrder` flow then:
1. Marks order CANCELED in the read model.
2. Releases inventory reservations.
3. Releases Redis queue counters.

**Why route through the saga:**
Direct status mutation works for the happy path but bypasses inventory release. Three different cancellation triggers (user-initiated, PayPal cancel, saga timeout) should converge on one tested code path. This avoids the "order canceled, stock still reserved" divergence and is the lesson worth learning.

### Resolved: Reuse Existing Cancel Topic

The existing topic is `order-service.order.canceled-status` carrying a `PaymentCanceled` Avro payload (single field: `orderId`). Both the saga's timeout scheduler and the PayPal IPN-cancel path publish to this topic; `OrderServiceListener.handleOrderCanceled` consumes it and calls `OrderServiceImpl.handleCanceledOrder`, which already does the dedup (`ProcessedPaymentEvent`) + status flip + inventory rollback.

For user-initiated cancel, `order-service` will self-publish a `PaymentCanceled` to the same topic. The existing listener+handler chain runs unchanged. The naming of `PaymentCanceled` is slightly misleading (it covers any cancellation, not just payment-driven) but reusing it avoids new schema, new topic, new consumer, and new dedup logic. A future rename is possible but not in scope here.

### Files Changed

- `order-service/src/main/java/.../controller/OrderController.java` — add `cancel` handler.
- `order-service/src/main/java/.../service/OrderService.java` and `OrderServiceImpl.java` — add `cancelOrder(userId, orderId)` method (validation + event publish).
- `order-service/src/main/java/.../service/OrderServiceConfiguration.java` — no new bean; existing `eventPublisher` is reused.
- Possibly `common-dto/.../event/OrderUserCanceledEvent.java` (new) — only if the open question above resolves to "new event".
- `common-dto/.../exception/OrderNotCancellableException.java` (new).
- `common-dto/.../exception/OrderAlreadyCanceledException.java` (new).
- Tests at controller and service level.

### Acceptance

- `PATCH /v1/orders/{my-pending-order-id}:cancel` → 200, response `{ orderId, status: CANCELED }`. Within a few seconds, the order's stored status flips to CANCELED in the read model and the reserved inventory is released.
- `PATCH /v1/orders/{someone-elses-order-id}:cancel` → 403.
- `PATCH /v1/orders/{my-completed-order-id}:cancel` → 409 with `ORDER_NOT_CANCELLABLE`.
- `PATCH /v1/orders/{my-already-canceled-order-id}:cancel` → 409 with `ORDER_ALREADY_CANCELED`.
- `PATCH /v1/orders/{nonexistent}:cancel` → 404.

---

## Section 4 — Actuator + Prometheus on Every Service

### Problem

No JVM service exposes `/actuator/health`, `/actuator/prometheus`, or any management endpoint. Without these:
- k8s has no `livenessProbe` / `readinessProbe` target → can't deploy reliably.
- Prometheus has nothing to scrape → k6 perf runs produce only k6's own client-side metrics; no server-side latency/throughput/error-rate breakdowns.

### Design

Add Spring Boot Actuator and Micrometer's Prometheus registry to every JVM service in the repo:

- gateway
- authorization-server
- product-service
- inventory-service
- order-service
- payment-service
- orchestrator-service
- eureka-server
- bff-service

**Dependencies (each `pom.xml`):**

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
    <scope>runtime</scope>
</dependency>
```

**Config block (each `application.yml`):**

```yaml
management:
  server:
    port: 9091
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
      base-path: /actuator
  endpoint:
    health:
      probes:
        enabled: true
      show-details: when-authorized
      group:
        liveness:
          include: livenessState
        readiness:
          include: readinessState,db,redis
  metrics:
    tags:
      application: ${spring.application.name}
```

**Per-service variation:** the `readiness.include` group should reflect what each service actually depends on:
- order-service, inventory-service, product-service: `readinessState,db,redis`
- authorization-server: `readinessState,db,redis,mail`
- bff-service: `readinessState`
- gateway, eureka-server: `readinessState`
- orchestrator-service: `readinessState,db`
- payment-service: `readinessState,db`

### Why a Separate Management Port (9091)

The management port is **internal-only**, never routed by the gateway. Two reasons:

1. **Security:** `/actuator/prometheus` exposes JVM internals and metric names that hint at architecture. Routing it through the public gateway means the public internet can scrape it. A separate management port that only kubelet and Prometheus can reach (via k8s NetworkPolicy / SG rules) keeps it private without per-endpoint auth gymnastics.
2. **Probe simplicity:** kubelet hits `/actuator/health/liveness` directly on the pod IP, port 9091. No JWT, no CORS, no gateway hop. Probes stay fast and deterministic even under app-port load.

The application port is unchanged.

### Files Changed

For each of the nine services:
- `*/pom.xml` — add the two dependencies.
- `*/src/main/resources/application.yml` — add the `management:` block.

### Acceptance

For each service, with the service running standalone (e.g. `mvn spring-boot:run` on order-service):
- `curl http://localhost:9091/actuator/health` → 200, body shows `{"status":"UP"}`.
- `curl http://localhost:9091/actuator/health/liveness` → 200.
- `curl http://localhost:9091/actuator/health/readiness` → 200 once dependencies are up.
- `curl http://localhost:9091/actuator/prometheus` → 200, body contains `http_server_requests_seconds_count` and `jvm_memory_used_bytes` lines tagged with `application="<service-name>"`.
- `curl http://localhost:8080/order-service/actuator/prometheus` → 404 (gateway does NOT route `/actuator/**`).

---

## Documentation Updates

After implementation:
- `CLAUDE.md` — add a short "Observability" subsection describing the actuator port (9091), the standard endpoint set, and the reason management is on a separate port. Add CORS overview to the gateway section. Mention the public product browse paths.
- No README changes required.

## Test Strategy

- **Section 1 (CORS):** integration test on gateway that asserts preflight response headers for an allowed and a disallowed origin.
- **Section 2 (Public browse):** integration test asserting `GET /product-service/v1/products` succeeds without `Authorization`, and `POST /product-service/v1/products` without `Authorization` returns 401.
- **Section 3 (Order cancel):** unit + controller tests covering the happy path, ownership mismatch, each non-PENDING state, nonexistent id. A small integration test that the cancel event is published on success.
- **Section 4 (Actuator):** smoke test per service that all four endpoints return 200 and the prometheus body contains expected metric names tagged with the service application name.

## Migration / Rollout

All four sections are additive and safe to ship in any order. Suggested sequence (smallest blast radius first):
1. Section 4 (actuator) — pure additive across all services.
2. Section 1 (CORS) — gateway only.
3. Section 2 (public browse) — Mongo seed change; rerun `make bootstrap` or apply a small migration script.
4. Section 3 (order cancel) — new endpoint and saga wiring.

No data migrations beyond the `api_role` seed update in Section 2.
