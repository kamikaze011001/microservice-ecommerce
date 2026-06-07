# mock-paypal-service

A drop-in mock of PayPal's REST API for stress testing (k6) and local frontend
dev. Java 25 + virtual threads, single replica, in-memory per-token state.

## How it works
- Implements the 5 PayPal endpoints `core-paypal` calls + a `/checkout` page.
- Switch is config-only: point `application.paypal.base-url` at this service
  (with the `/mock-paypal-service` context-path suffix). No payment-service or
  core-paypal code changes.
- Decision (approve/cancel/fail) is chosen at `/checkout` and remembered per
  token; `fail` makes the capture endpoint return HTTP 422 → `PaymentFailed`.

## Endpoints
| Method | Path | Purpose |
|---|---|---|
| POST | /v1/oauth2/token | mock OAuth token |
| POST | /v2/checkout/orders | create order, returns approve link |
| GET  | /checkout?token=&decision= | approve page / decision redirect |
| POST | /v2/checkout/orders/{token}/capture | COMPLETED, or 422 if decision=fail |
| GET  | /v2/checkout/orders/{token} | order details (custom_id, capture id) |
| POST | /v2/payments/captures/{id}/refund | mock refund |

All paths are served under the context-path `/mock-paypal-service` (HTTP 8585,
management 18585). Responses are snake_case (`@JsonNaming(SnakeCaseStrategy)`) to
match `core-paypal`.

## Build & run
This module targets **Java 25** (the rest of the repo is Java 17). Build/run it
with a JDK 25 toolchain:
```bash
export JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.3-tem"   # or any JDK 25
cd mock-paypal-service && mvn clean test     # 16 unit/slice tests
mvn spring-boot:run                          # starts on :8585
```
Docker: `mock-paypal-service/Dockerfile` is a standalone multi-stage JDK 25
build (the shared `k8s/images/Dockerfile.jvm` uses a JDK-17 cores base and can't
compile it). Build via `SVC=mock-paypal-service k8s/images/build.sh`.

## Run locally (bare JVM, like the other services)
Registered in `scripts/services.list`; starts with `make up` on port 8585.
Because `make up` launches every service with `mvn spring-boot:run`, run it with
`JAVA_HOME` pointing at a JDK 25 (JDK 25 also runs the Java-17 services). To make
payment-service use the mock locally, follow the `_comment_mock_paypal` note in
`docker/vault-configs/payment-service.json`.

## k8s
- Base manifests: `k8s/apps/base/mock-paypal-service/` (single replica — no HPA,
  state is in-memory per token). Wired into `k8s/apps/overlays/local`, which also
  patches payment-service to point `application.paypal.base-url` at the mock.
- Gateway route `Path=/mock-paypal-service/**` (no StripPrefix); the browser-facing
  `/mock-paypal-service/checkout` is PERMIT_ALL in `docker/api_role.json`.

## k6 stress
- In-cluster Job `k6-payment-stress` (`k8s/apps/base/k6-stress/payment-flow.js`,
  fired via `make k8s-payment-stress`) runs the full payment saga under load with
  a 90/5/5 approve/cancel/fail mix. It rewrites the mock's browser-facing
  `api.microecom.local` origin back to the in-cluster gateway Service DNS (so no
  `hostAliases`/ingress-ClusterIP templating is needed). Requires the perftest
  users (seeded by `make k8s-seed-perftest`) and the real catalog products
  (`PRODUCT_IDS` in `payment-job.yaml`) to be seeded.
