# Backend FE-Ready + Deploy-Ready Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four backend gaps (CORS at gateway, public BFF product detail, user-initiated order cancel, actuator+Prometheus on every JVM service) so a frontend can be built and the system can be deployed to k8s with proper probes.

**Architecture:** Additive changes only. Section 4 (actuator) goes onto every service via a separate management port (9091) so the gateway never routes it. Section 1 (CORS) is gateway-only. Section 2 (public BFF) is a single Mongo seed entry. Section 3 (cancel) reuses the existing `order-service.order.canceled-status` Kafka topic and `PaymentCanceled` payload — order-service self-publishes on user-cancel and the existing `OrderServiceListener.handleOrderCanceled` consumes it, so dedup, status flip, and inventory rollback all use the established saga path.

**Tech Stack:** Spring Boot 3.3.6, Spring Cloud Gateway (reactive), Spring Boot Actuator, Micrometer Prometheus, Spring Kafka + Avro, MongoDB, Lombok, JUnit 5, AssertJ, Mockito, Reactor Test (`WebTestClient`).

---

## Reference Spec

`docs/superpowers/specs/2026-05-01-backend-fe-deploy-readiness-design.md`

## Repo Conventions Worth Knowing

These are non-obvious to a fresh engineer and matter for the steps below:

- **No `@Service` / `@Component` on service impls.** Service implementations are wired manually in `@Configuration` classes (e.g. `OrderServiceConfiguration`, `AuthorizationServerConfiguration`). When you add a constructor parameter to an impl, update the `@Bean` factory method in the matching configuration class. **Exception:** Kafka listeners (`@Component` `OrderServiceListener`) and controllers stay annotated.
- **Master-slave repository split.** JPA repositories live under `repository/master/` (writes) and `repository/slave/` (reads). The routing datasource picks the connection by package. Write paths use master repos; read paths use slave repos.
- **Response shape.** Controllers return `BaseResponse` via static factories: `BaseResponse.ok(data)`, `.created(data)`, `.notFound(data)`. Never construct `BaseResponse` directly.
- **`PagingRequest`.** `page` is 1-indexed (min 1). Convert to 0-indexed (`page - 1`) before passing to Spring Data.
- **Identity.** Gateway extracts `userId` from JWT and forwards it as `X-User-Id`. Controllers read `@RequestHeader("X-User-Id") String userId`. Don't parse JWTs in business services.
- **Gateway routing.** `Path=/<service-name>/**` → `lb://<SERVICE-NAME>` with no `StripPrefix`. Each service sets `server.servlet.context-path: /<service-name>`. Controllers use bare paths.
- **Exception classes** live in `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/`. They extend `BaseException` and use a constant `ResponseCode` mapping. Look at `ImageNotUploadedException` as a template.
- **Avro events** are generated from `core/common-dto/src/main/avro/*.avsc`. `PaymentCanceled` already exists with a single `orderId` field.
- **Order status enum:** `PROCESSING, COMPLETED, CANCELED, FAILED, REFUNDED` (see `order-service/.../constant/OrderStatus.java`). The cancellable state is **`PROCESSING`**, not `PENDING`.
- **Build order:** `make build` (wraps `scripts/maven/install-modules.sh`) installs core modules first. Run `make build` after changing anything in `core/common-dto`.
- **Tests run without infra** by guarding context-loading tests; mirror that pattern.

## File Structure

### New files

| File | Responsibility |
|---|---|
| `gateway/src/main/java/org/aibles/gateway/configuration/CorsProperties.java` | `@ConfigurationProperties("application.gateway.cors")` POJO — origins, methods, headers, credentials, max-age |
| `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/OrderNotCancellableException.java` | Thrown when order is in a non-cancellable state |
| `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/OrderAlreadyCanceledException.java` | Thrown when order is already CANCELED |
| `order-service/src/main/java/org/aibles/order_service/dto/response/OrderCancelResponse.java` | `{orderId, status}` response payload |
| `gateway/src/test/java/org/aibles/gateway/configuration/CorsConfigurationTest.java` | Reactive WebTestClient preflight assertions |
| `order-service/src/test/java/org/aibles/order_service/service/OrderCancelServiceTest.java` | Unit tests for cancel ownership, state guards, happy path |
| `order-service/src/test/java/org/aibles/order_service/controller/OrderControllerCancelTest.java` | Controller test for the new endpoint |

### Modified files

| File | Why |
|---|---|
| `gateway/src/main/java/org/aibles/gateway/configuration/SecurityConfiguration.java` | Replace `Customizer.withDefaults()` with explicit `CorsConfigurationSource` bean |
| `gateway/src/main/resources/application.yml` | Add `application.gateway.cors.*` defaults and management endpoints |
| `<service>/pom.xml` (×9) | Add actuator + micrometer-prometheus deps |
| `<service>/src/main/resources/application.yml` (×9) | Add `management:` block with separate port 9091 and per-service readiness group |
| `docker/api_role.json` | Add `PERMIT_ALL` entry for `GET /bff-service/v1/products/**` |
| `order-service/src/main/java/org/aibles/order_service/controller/OrderController.java` | Add `PATCH /v1/orders/{orderId}:cancel` |
| `order-service/src/main/java/org/aibles/order_service/service/OrderService.java` | Add `cancel(userId, orderId)` interface method |
| `order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java` | Implement `cancel`: ownership + state checks, publish `PaymentCanceled` Avro |
| `CLAUDE.md` | Document CORS, actuator port, public BFF route |

The "nine services" list for actuator: `gateway`, `eureka-server`, `authorization-server`, `product-service`, `inventory-service`, `order-service`, `payment-service`, `orchestrator-service`, `bff-service`.

---

## Section 4 — Actuator + Prometheus on Every JVM Service

Done first because it's pure-additive and has the smallest blast radius. We do one reference service end-to-end (Task 1), then roll the same pattern across the remaining eight (Task 2).

### Task 1: Add Actuator on `order-service` (reference implementation)

**Files:**
- Modify: `order-service/pom.xml`
- Modify: `order-service/src/main/resources/application.yml`
- Test (smoke, manual): `curl http://localhost:9091/actuator/health` and `/actuator/prometheus`

There is no automated boot-and-curl test in this codebase pattern — the service requires Vault/MySQL/Redis/Kafka to even start a `@SpringBootTest` context. We rely on a manual smoke test after `make up` and on the eventual k8s probe behavior. Do **not** introduce a new full-context test that would need infra.

- [ ] **Step 1: Add the two actuator dependencies to `order-service/pom.xml`**

Find the closing `</dependencies>` near the bottom and insert the following block immediately before it (preserve tab indentation if the file uses tabs — check with `cat -A pom.xml | head -5`):

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

- [ ] **Step 2: Verify the deps compile**

```bash
cd order-service && mvn -q -DskipTests compile
```

Expected: `BUILD SUCCESS`. If it fails, the indentation likely mixed tabs and spaces — fix with the surrounding file's style.

- [ ] **Step 3: Add the `management:` block to `order-service/src/main/resources/application.yml`**

Append at the bottom of the file (after the existing `application:` block; same root-level indentation as `spring:`, `server:`, `application:`):

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

- [ ] **Step 4: Boot the service and smoke-test the four endpoints**

Assumes `make up` has the infra running. From repo root:

```bash
make logs svc=order-service &  # or check via your usual mechanism
# Wait until you see "Started OrderServiceApplication"
curl -s http://localhost:9091/actuator/health | jq
curl -s http://localhost:9091/actuator/health/liveness | jq
curl -s http://localhost:9091/actuator/health/readiness | jq
curl -s http://localhost:9091/actuator/prometheus | head -20
```

Expected:
- `health` → `{"status":"UP"}`
- `liveness` → `{"status":"UP"}`
- `readiness` → `{"status":"UP"}` once db+redis are reachable
- `prometheus` → text/plain with lines like `jvm_memory_used_bytes{...,application="order-service",...}` and `http_server_requests_seconds_count{...}`

- [ ] **Step 5: Verify gateway does NOT expose the management port**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/order-service/actuator/health
```

Expected: `404` (or whatever the gateway returns for an unknown path). The management endpoints are intentionally not routed.

- [ ] **Step 6: Commit**

```bash
git add order-service/pom.xml order-service/src/main/resources/application.yml
git commit -m "$(cat <<'EOF'
feat(order-service): expose actuator + prometheus on port 9091

Adds Spring Boot Actuator and Micrometer Prometheus registry on a
separate management port (9091). Liveness, readiness (with db+redis
groups), and prometheus endpoints are reachable directly on the pod;
the gateway does not route /actuator/**.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Roll Out Actuator to the Remaining Eight Services

For each service below, perform Steps A–D from this task. The dependency block is identical for every service. The `management:` block is identical except for the `readiness.include` line, which reflects the service's actual external dependencies.

**Per-service readiness includes:**

| Service | `readiness.include` |
|---|---|
| gateway | `readinessState` |
| eureka-server | `readinessState` |
| authorization-server | `readinessState,db,redis,mail` |
| product-service | `readinessState,db,redis` |
| inventory-service | `readinessState,db,redis` |
| payment-service | `readinessState,db` |
| orchestrator-service | `readinessState,db` |
| bff-service | `readinessState` |

If a service has no MySQL datasource (e.g. eureka-server, gateway, bff-service), do not add `db` to the readiness group — Actuator will fail readiness if the indicator is included but the bean is missing. The table above already accounts for this.

**Common dependency block** (paste before `</dependencies>` in each `pom.xml`):

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

Use spaces vs tabs to match the existing file style. Check with `cat -A <file> | head -5`.

**Common application.yml block** (append at the bottom of `src/main/resources/application.yml`, root-level indentation; substitute the per-service `readiness.include`):

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
          include: <PER-SERVICE — see table>
  metrics:
    tags:
      application: ${spring.application.name}
```

For each of the eight services in the order listed in the table:

- [ ] **Step A: Add the dependency block to `<service>/pom.xml`**
- [ ] **Step B: Add the `management:` block to `<service>/src/main/resources/application.yml`** with the right `readiness.include`
- [ ] **Step C: Boot and smoke-test**

```bash
curl -s http://localhost:9091/actuator/health | jq
curl -s http://localhost:9091/actuator/prometheus | grep "application=\"<service-name>\"" | head -3
```

Expected: `health.status=UP` and at least one prometheus line tagged with the service's application name.

- [ ] **Step D: Commit**

```bash
git add <service>/pom.xml <service>/src/main/resources/application.yml
git commit -m "$(cat <<'EOF'
feat(<service>): expose actuator + prometheus on port 9091

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

**Caveat for `gateway`:** the gateway is a reactive (Netty) service. Actuator dependencies still work, but verify the management port doesn't conflict with the WebFlux server port (gateway's main port is 8080; 9091 is unused). After adding actuator, `curl http://localhost:9091/actuator/health` from the host should work; do not expect any change to the main 8080 routing.

**Caveat for `eureka-server`:** there is no Spring Data datasource. Keep `readiness.include: readinessState` only.

After all eight services are committed, do a final sanity check:

- [ ] **Step E: Verify all nine services expose `/actuator/health`**

```bash
for port in 9091; do
  for svc in order-service product-service inventory-service payment-service orchestrator-service authorization-server bff-service gateway eureka-server; do
    echo -n "$svc: "
    # If you've configured each service's management port differently per host, adjust.
    # When running via make up, services share the host so all 9091's collide — see below.
  done
done
```

**Important caveat:** when you run all services on the same host via `make up`, `management.server.port: 9091` will collide because nine JVMs cannot bind the same port on one host. Two options:

1. **Per-service management port range** (recommended for local dev): assign 9091, 9092, … via Vault or per-service config override. Add the offset in each service's `application.yml`.
2. **Accept the collision locally** and verify only when each service is run alone (e.g. via `mvn spring-boot:run` from one service dir) or via k8s where each pod has its own network namespace and 9091 doesn't collide.

For this plan, take **option 2**: keep `9091` everywhere. The local smoke test in Step C should be done one service at a time (stop the rest, or test inside the container's network in `make up`). The collision is intentional — in k8s every pod has its own loopback so 9091 is correct there. Document this in the CLAUDE.md update at the end.

If you prefer option 1 instead, make each service's `application.yml` use `management.server.port: ${MANAGEMENT_PORT:9091}` and pass per-service `MANAGEMENT_PORT` env vars from `make up` / `scripts/services.list`. That's a separate refactor — skip it for this plan.

---

## Section 1 — CORS at Gateway

### Task 3: CORS Properties Class

**Files:**
- Create: `gateway/src/main/java/org/aibles/gateway/configuration/CorsProperties.java`

- [ ] **Step 1: Create `CorsProperties.java`**

```java
package org.aibles.gateway.configuration;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.List;

@Data
@ConfigurationProperties(prefix = "application.gateway.cors")
public class CorsProperties {

    private List<String> allowedOrigins = List.of("http://localhost:3000", "http://localhost:5173");
    private List<String> allowedMethods = List.of("GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS");
    private List<String> allowedHeaders = List.of("*");
    private List<String> exposedHeaders = List.of("Authorization");
    private boolean allowCredentials = true;
    private long maxAge = 3600L;
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd gateway && mvn -q -DskipTests compile
```

Expected: `BUILD SUCCESS`.

- [ ] **Step 3: Commit**

```bash
git add gateway/src/main/java/org/aibles/gateway/configuration/CorsProperties.java
git commit -m "feat(gateway): add CorsProperties config holder

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 4: Wire CORS Bean and Defaults

**Files:**
- Modify: `gateway/src/main/java/org/aibles/gateway/configuration/SecurityConfiguration.java`
- Modify: `gateway/src/main/resources/application.yml`
- Test: `gateway/src/test/java/org/aibles/gateway/configuration/CorsConfigurationTest.java`

- [ ] **Step 1: Write the failing reactive CORS test**

Create `gateway/src/test/java/org/aibles/gateway/configuration/CorsConfigurationTest.java`:

```java
package org.aibles.gateway.configuration;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.SpringBootTest.WebEnvironment;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.reactive.server.WebTestClient;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = WebEnvironment.RANDOM_PORT,
    properties = {
        "spring.cloud.vault.enabled=false",
        "spring.cloud.vault.kv.enabled=false",
        "spring.cloud.vault.fail-fast=false",
        "eureka.client.enabled=false",
        "eureka.client.register-with-eureka=false",
        "eureka.client.fetch-registry=false",
        "spring.config.import=optional:vault://"
    })
@TestPropertySource(properties = {
    "application.gateway.cors.allowed-origins=http://localhost:3000"
})
class CorsConfigurationTest {

    @Autowired
    private WebTestClient client;

    @Test
    void preflightFromAllowedOriginReturnsCorsHeaders() {
        client.options().uri("/authorization-server/v1/auth:login")
            .header("Origin", "http://localhost:3000")
            .header("Access-Control-Request-Method", "POST")
            .header("Access-Control-Request-Headers", "Authorization,Content-Type")
            .exchange()
            .expectHeader().valueEquals("Access-Control-Allow-Origin", "http://localhost:3000")
            .expectHeader().valueEquals("Access-Control-Allow-Credentials", "true")
            .expectHeader().value("Access-Control-Allow-Methods", methods ->
                assertThat(methods).contains("POST"));
    }

    @Test
    void preflightFromDisallowedOriginIsRejected() {
        client.options().uri("/authorization-server/v1/auth:login")
            .header("Origin", "http://evil.example.com")
            .header("Access-Control-Request-Method", "POST")
            .exchange()
            .expectHeader().doesNotExist("Access-Control-Allow-Origin");
    }
}
```

- [ ] **Step 2: Run the test — expect FAIL**

```bash
cd gateway && mvn -q test -Dtest=CorsConfigurationTest
```

Expected: FAIL — `withDefaults()` either returns no `Access-Control-Allow-Origin` for any origin or a wildcard. Capture the actual failure to confirm it's a CORS-header issue, not a context-load failure.

If the test fails to even load the context due to other beans (e.g. `ApiRoleRepository` requires Mongo), add the necessary mocks via `@MockBean`:

```java
@MockBean private org.aibles.gateway.repository.ApiRoleRepository apiRoleRepository;
```

Iterate until the failure is genuinely about missing CORS headers, not context bootstrap.

- [ ] **Step 3: Modify `SecurityConfiguration.java` to wire the CORS source**

Replace the existing `springSecurityFilterChain` and add a new bean. Full file should be:

```java
package org.aibles.gateway.configuration;

import org.aibles.gateway.filter.AuthorizationFilter;
import org.aibles.gateway.filter.JwtAuthenticationFilter;
import org.aibles.gateway.repository.ApiRoleRepository;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.reactive.EnableWebFluxSecurity;
import org.springframework.security.config.web.server.SecurityWebFiltersOrder;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.web.server.SecurityWebFilterChain;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.reactive.CorsConfigurationSource;
import org.springframework.web.cors.reactive.UrlBasedCorsConfigurationSource;
import org.springframework.web.reactive.function.client.WebClient;

@Configuration
@EnableWebFluxSecurity
@EnableConfigurationProperties(CorsProperties.class)
public class SecurityConfiguration {

    @Bean
    public JwtAuthenticationFilter jwtAuthenticationFilter(WebClient lbWebClient) {
        return new JwtAuthenticationFilter(lbWebClient);
    }

    @Bean
    public AuthorizationFilter authorizationFilter(ApiRoleRepository apiRoleRepository) {
        return new AuthorizationFilter(apiRoleRepository);
    }

    @Bean
    public CorsConfigurationSource corsConfigurationSource(CorsProperties props) {
        CorsConfiguration cfg = new CorsConfiguration();
        cfg.setAllowedOrigins(props.getAllowedOrigins());
        cfg.setAllowedMethods(props.getAllowedMethods());
        cfg.setAllowedHeaders(props.getAllowedHeaders());
        cfg.setExposedHeaders(props.getExposedHeaders());
        cfg.setAllowCredentials(props.isAllowCredentials());
        cfg.setMaxAge(props.getMaxAge());

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", cfg);
        return source;
    }

    @Bean
    public SecurityWebFilterChain springSecurityFilterChain(ServerHttpSecurity http,
                                                            JwtAuthenticationFilter jwtAuthenticationFilter,
                                                            AuthorizationFilter authorizationFilter,
                                                            CorsConfigurationSource corsConfigurationSource) {
        return http.cors(cors -> cors.configurationSource(corsConfigurationSource))
                .csrf(ServerHttpSecurity.CsrfSpec::disable)
                .addFilterAt(jwtAuthenticationFilter, SecurityWebFiltersOrder.AUTHENTICATION)
                .addFilterAt(authorizationFilter, SecurityWebFiltersOrder.AUTHORIZATION)
                .build();
    }
}
```

- [ ] **Step 4: Add the CORS defaults to `gateway/src/main/resources/application.yml`**

Append at root level (sibling of `spring:`, `server:`, `eureka:`, `springdoc:`):

```yaml
application:
  gateway:
    cors:
      allowed-origins:
        - http://localhost:3000
        - http://localhost:5173
      allowed-methods:
        - GET
        - POST
        - PUT
        - PATCH
        - DELETE
        - OPTIONS
      allowed-headers:
        - "*"
      exposed-headers:
        - Authorization
      allow-credentials: true
      max-age: 3600
```

- [ ] **Step 5: Run the test — expect PASS**

```bash
cd gateway && mvn -q test -Dtest=CorsConfigurationTest
```

Expected: PASS. Both test methods green.

- [ ] **Step 6: Run the full gateway test suite to make sure nothing else broke**

```bash
cd gateway && mvn -q test
```

Expected: PASS or only pre-existing failures. If a pre-existing test breaks, do not "fix" it by deleting — investigate.

- [ ] **Step 7: Commit**

```bash
git add gateway/src/main/java/org/aibles/gateway/configuration/SecurityConfiguration.java \
        gateway/src/main/resources/application.yml \
        gateway/src/test/java/org/aibles/gateway/configuration/CorsConfigurationTest.java
git commit -m "$(cat <<'EOF'
feat(gateway): wire explicit CORS source for browser FE

Replaces Customizer.withDefaults() with a UrlBasedCorsConfigurationSource
fed by application.gateway.cors.* properties (defaults: localhost:3000,
localhost:5173, credentials=true, max-age=3600).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Section 2 — Public BFF Product Detail

### Task 5: Add `PERMIT_ALL` Entry for BFF Product Detail

**Files:**
- Modify: `docker/api_role.json`

The seed already covers `/product-service/v1/products/**` GET as `PERMIT_ALL`. Only the BFF product-detail route is missing.

- [ ] **Step 1: Find the existing product-service GET PERMIT_ALL entry as a placement reference**

```bash
grep -n "product-service/v1/products" /Users/sonanh/Documents/AIBLES/microservice-ecommerce/docker/api_role.json
```

Identify the line range of the existing `{ "_id": ..., "path": "/product-service/v1/products/**", "roles": ["PERMIT_ALL"], "method": ["GET"] }` block. Note the exact closing position.

- [ ] **Step 2: Insert the new BFF entry immediately after that block**

Add this object as a new array element. Use a fresh `_id` ObjectId (any unique 24-hex string; the existing seeds use random ones). Mirror the formatting of surrounding entries exactly:

```json
  {
    "_id": {"$oid": "67f00100000000000000bf01"},
    "path": "/bff-service/v1/products/**",
    "roles": ["PERMIT_ALL"],
    "method": ["GET"]
  },
```

Make sure the trailing comma is correct depending on whether it's the last array element. Validate the file is still valid JSON:

```bash
python3 -m json.tool /Users/sonanh/Documents/AIBLES/microservice-ecommerce/docker/api_role.json > /dev/null && echo OK
```

Expected: `OK`. If it errors, fix the trailing comma / bracket.

- [ ] **Step 3: Re-seed Mongo so the live `api_role` collection picks up the new entry**

The seed loader is in `scripts/seed/`. Run the seed step:

```bash
make seed-data
```

(Or whatever the project's current command is — check `Makefile`. If `seed-data` is not idempotent for `api_role`, you may need to manually upsert: `mongosh ecommerce_inventory --eval 'db.api_role.insertOne({...})'`.)

- [ ] **Step 4: Verify the new rule via curl**

Boot the BFF and gateway (via `make up`), then with no `Authorization` header:

```bash
# Pick any product id you have. List public products first to grab one:
curl -s http://localhost:8080/product-service/v1/products | jq '.data.contents[0].id'
PID=<paste-id-here>

curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8080/bff-service/v1/products/$PID"
```

Expected: `200`. Pre-change behavior was `401` or `403` (no `api_role` match → default deny).

Negative check (still walled):

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/order-service/v1/orders
```

Expected: `401` (orders endpoint still requires login).

- [ ] **Step 5: Commit**

```bash
git add docker/api_role.json
git commit -m "$(cat <<'EOF'
feat(gateway): make BFF product detail public

Adds GET /bff-service/v1/products/** as PERMIT_ALL so the storefront
detail page works for unauthenticated visitors. /product-service/v1/products/**
GET was already public.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Section 3 — Order Cancellation

User-cancel reuses the existing `order-service.order.canceled-status` Kafka topic and `PaymentCanceled` Avro payload. Order-service self-publishes; its existing `OrderServiceListener.handleOrderCanceled` consumes and runs `OrderServiceImpl.handleCanceledOrder`, which dedupes via `ProcessedPaymentEvent`, flips status to `CANCELED`, and releases inventory. We do **not** add a new topic, event, or dedup table.

The endpoint returns `200` with `status: CANCELED` optimistically. The actual state change is asynchronous (Kafka-driven) — same eventual-consistency model as PayPal-cancel and saga-timeout-cancel today.

### Task 6: Common-DTO Exception Classes

**Files:**
- Look at: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/ImageNotUploadedException.java` (template)
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/OrderNotCancellableException.java`
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/OrderAlreadyCanceledException.java`
- Possibly modify: the `ResponseCode` enum/class used by existing exceptions

- [ ] **Step 1: Read the existing exception template and the response-code constant**

```bash
cat /Users/sonanh/Documents/AIBLES/microservice-ecommerce/core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/ImageNotUploadedException.java
grep -rn "ResponseCode" /Users/sonanh/Documents/AIBLES/microservice-ecommerce/core/common-dto/src/main/java | head -10
```

Note the package, parent class (likely `BaseException`), constructor signature, and where the `ResponseCode` constants live (e.g. `core_exception_api.constant.ResponseCode` or similar). The new exceptions must follow the same pattern exactly.

- [ ] **Step 2: Add the two new `ResponseCode` entries**

In whatever class enumerates response codes (find via the grep above), add:

```java
ORDER_NOT_CANCELLABLE("ORDER_NOT_CANCELLABLE", "Order cannot be canceled in its current state", 409),
ORDER_ALREADY_CANCELED("ORDER_ALREADY_CANCELED", "Order is already canceled", 409),
```

Match the existing entry signature exactly — if entries take only `(code, message)` because HTTP status is mapped elsewhere, drop the `409`. The example above is illustrative.

- [ ] **Step 3: Create `OrderNotCancellableException.java` mirroring the template**

```java
package org.aibles.ecommerce.common_dto.exception;

// Match the imports of ImageNotUploadedException — likely something like:
// import org.aibles.ecommerce.core_exception_api.constant.ResponseCode;
// import org.aibles.ecommerce.core_exception_api.exception.BaseException;

public class OrderNotCancellableException extends BaseException {

    public OrderNotCancellableException() {
        super(ResponseCode.ORDER_NOT_CANCELLABLE);
    }
}
```

Adapt the parent class and `ResponseCode` import to whatever the template uses — do not invent symbols.

- [ ] **Step 4: Create `OrderAlreadyCanceledException.java` the same way**

```java
package org.aibles.ecommerce.common_dto.exception;

public class OrderAlreadyCanceledException extends BaseException {

    public OrderAlreadyCanceledException() {
        super(ResponseCode.ORDER_ALREADY_CANCELED);
    }
}
```

- [ ] **Step 5: Build and install common-dto**

```bash
cd core/common-dto && mvn -q -DskipTests install
```

Expected: `BUILD SUCCESS`.

- [ ] **Step 6: Commit**

```bash
git add core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/OrderNotCancellableException.java \
        core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/exception/OrderAlreadyCanceledException.java \
        # plus the ResponseCode file if you modified one
git commit -m "$(cat <<'EOF'
feat(common-dto): add order-cancel exception types

OrderNotCancellableException covers COMPLETED/FAILED/REFUNDED states.
OrderAlreadyCanceledException covers CANCELED. Both surface as 409 Conflict.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 7: Cancel Response DTO

**Files:**
- Create: `order-service/src/main/java/org/aibles/order_service/dto/response/OrderCancelResponse.java`

- [ ] **Step 1: Create the response DTO**

```java
package org.aibles.order_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.order_service.constant.OrderStatus;

@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class OrderCancelResponse {
    private String orderId;
    private OrderStatus status;
}
```

Snake-case JSON to match other responses in this service. Field `orderId` will serialize as `order_id`.

- [ ] **Step 2: Compile**

```bash
cd order-service && mvn -q -DskipTests compile
```

Expected: `BUILD SUCCESS`.

- [ ] **Step 3: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/dto/response/OrderCancelResponse.java
git commit -m "feat(order-service): add OrderCancelResponse DTO

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 8: Service Layer — `cancel(userId, orderId)`

**Files:**
- Modify: `order-service/src/main/java/org/aibles/order_service/service/OrderService.java`
- Modify: `order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java`
- Test: `order-service/src/test/java/org/aibles/order_service/service/OrderCancelServiceTest.java`

- [ ] **Step 1: Read existing OrderServiceImpl bits relevant to cancel**

```bash
grep -n "findById\|getOrderById\|@Override\|class OrderServiceImpl\|eventPublisher\|MongoSavedEvent\|EcommerceEvent" /Users/sonanh/Documents/AIBLES/microservice-ecommerce/order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java | head -30
```

Note:
- The repository field name and read method (likely `slaveOrderRepo.findById(orderId)`).
- The `userId` field on the `Order` entity (verify with `grep -n "userId\|user_id" .../entity/Order.java`).
- The pattern used to publish an event — `eventPublisher.publishEvent(new MongoSavedEvent(this, EcommerceEvent.ORDER_CREATED.getValue(), payload))`. Find or add the matching event constant for `order.canceled-status` (likely already exists for the existing PayPal-cancel flow). If there's no `EcommerceEvent` value pointing at the canceled-status topic, look at how the saga's `SagaOrchestrationServiceImpl` or PayPal callback publishes — it may use a `KafkaTemplate` directly with a topic from `application.kafka.topics.order-service.order.canceled-status`. Mirror whichever path the existing code uses.

- [ ] **Step 2: Write the failing service test**

Create `order-service/src/test/java/org/aibles/order_service/service/OrderCancelServiceTest.java`:

```java
package org.aibles.order_service.service;

import org.aibles.ecommerce.common_dto.exception.OrderAlreadyCanceledException;
import org.aibles.ecommerce.common_dto.exception.OrderNotCancellableException;
import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.dto.response.OrderCancelResponse;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.service.impl.OrderServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

// IMPORTANT: replace the constructor args below with the real list from
// the existing OrderServiceImpl constructor signature. Fill in mocks for
// every dependency. Do NOT instantiate real implementations.
class OrderCancelServiceTest {

    // Declare mocks for every constructor dependency on OrderServiceImpl,
    // e.g. masterOrderRepo, slaveOrderRepo, masterOrderItemRepo,
    // slaveOrderItemRepo, redisRepository, eventPublisher,
    // distributedLockProvider, etc. Use the real classes from imports.

    private OrderServiceImpl service;

    @BeforeEach
    void setUp() {
        // Instantiate all mocks above with mock(...).class
        // service = new OrderServiceImpl(masterOrderRepo, slaveOrderRepo, ...);
    }

    @Test
    void cancelHappyPath_processingOrderOwnedByUser_returnsCanceledAndPublishes() {
        Order order = new Order();
        order.setId("o1");
        order.setUserId("u1");
        order.setStatus(OrderStatus.PROCESSING);
        when(slaveOrderRepo.findById("o1")).thenReturn(Optional.of(order));

        OrderCancelResponse resp = service.cancel("u1", "o1");

        assertThat(resp.getOrderId()).isEqualTo("o1");
        assertThat(resp.getStatus()).isEqualTo(OrderStatus.CANCELED);
        // ApplicationEventPublisher is the publish mechanism (mirroring
        // the ORDER_CREATED path). Use an ArgumentCaptor:
        //   ArgumentCaptor<MongoSavedEvent> cap = ArgumentCaptor.forClass(MongoSavedEvent.class);
        //   verify(eventPublisher).publishEvent(cap.capture());
        //   MongoSavedEvent ev = cap.getValue();
        //   assertThat(ev.getName()).isEqualTo(EcommerceEvent.PAYMENT_CANCELED.getValue());
        //   assertThat(((PaymentCanceled) ev.getData()).getOrderId().toString()).isEqualTo("o1");
        // (Adjust getter names — `getName`/`getData` — to whatever MongoSavedEvent actually exposes.)
    }

    @Test
    void cancelByOtherUser_throwsForbidden() {
        Order order = new Order();
        order.setId("o1");
        order.setUserId("u1");
        order.setStatus(OrderStatus.PROCESSING);
        when(slaveOrderRepo.findById("o1")).thenReturn(Optional.of(order));

        // The exception used for "not your order" is the project's existing
        // forbidden type (search the codebase: ForbiddenException,
        // ResourceForbiddenException, etc.). Use whichever the codebase uses.
        assertThatThrownBy(() -> service.cancel("u2", "o1"))
            .isInstanceOf(/* ForbiddenException-or-equivalent */ RuntimeException.class);
    }

    @Test
    void cancelCompletedOrder_throwsNotCancellable() {
        Order order = new Order();
        order.setId("o1");
        order.setUserId("u1");
        order.setStatus(OrderStatus.COMPLETED);
        when(slaveOrderRepo.findById("o1")).thenReturn(Optional.of(order));

        assertThatThrownBy(() -> service.cancel("u1", "o1"))
            .isInstanceOf(OrderNotCancellableException.class);
    }

    @Test
    void cancelAlreadyCanceledOrder_throwsAlreadyCanceled() {
        Order order = new Order();
        order.setId("o1");
        order.setUserId("u1");
        order.setStatus(OrderStatus.CANCELED);
        when(slaveOrderRepo.findById("o1")).thenReturn(Optional.of(order));

        assertThatThrownBy(() -> service.cancel("u1", "o1"))
            .isInstanceOf(OrderAlreadyCanceledException.class);
    }

    @Test
    void cancelFailedOrder_throwsNotCancellable() {
        Order order = new Order();
        order.setId("o1");
        order.setUserId("u1");
        order.setStatus(OrderStatus.FAILED);
        when(slaveOrderRepo.findById("o1")).thenReturn(Optional.of(order));

        assertThatThrownBy(() -> service.cancel("u1", "o1"))
            .isInstanceOf(OrderNotCancellableException.class);
    }

    @Test
    void cancelRefundedOrder_throwsNotCancellable() {
        Order order = new Order();
        order.setId("o1");
        order.setUserId("u1");
        order.setStatus(OrderStatus.REFUNDED);
        when(slaveOrderRepo.findById("o1")).thenReturn(Optional.of(order));

        assertThatThrownBy(() -> service.cancel("u1", "o1"))
            .isInstanceOf(OrderNotCancellableException.class);
    }

    @Test
    void cancelNonexistentOrder_throwsNotFound() {
        when(slaveOrderRepo.findById("missing")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.cancel("u1", "missing"))
            .isInstanceOf(/* OrderNotFoundException or codebase's NotFound type */ RuntimeException.class);
    }
}
```

Concrete instructions for filling in the placeholders:
1. Open the existing OrderServiceImpl constructor and copy every parameter into the test as a `mock(X.class)` field.
2. Search the codebase for the existing forbidden-access exception (`grep -rn "Forbidden\|FORBIDDEN" order-service/src/main/java`).
3. Search for the existing not-found exception used elsewhere in OrderService (`grep -n "NotFound\|throw new" .../OrderServiceImpl.java`).
4. Replace the placeholder `RuntimeException.class` with the actual classes you find.

- [ ] **Step 3: Run the test — expect FAIL**

```bash
cd order-service && mvn -q test -Dtest=OrderCancelServiceTest
```

Expected: COMPILE FAIL — `cancel` method doesn't exist on `OrderService`.

- [ ] **Step 4: Add `cancel` to the `OrderService` interface**

In `order-service/src/main/java/org/aibles/order_service/service/OrderService.java`, add:

```java
OrderCancelResponse cancel(String userId, String orderId);
```

Add the import:

```java
import org.aibles.order_service.dto.response.OrderCancelResponse;
```

- [ ] **Step 5: Implement `cancel` in `OrderServiceImpl`**

Add this method to `OrderServiceImpl`:

```java
@Override
public OrderCancelResponse cancel(String userId, String orderId) {
    log.info("(cancel) user={} order={}", userId, orderId);

    Order order = slaveOrderRepo.findById(orderId)
        .orElseThrow(() -> new /* match existing NotFound type */ OrderNotFoundException(orderId));

    if (!userId.equals(order.getUserId())) {
        throw new /* match existing Forbidden type */ ForbiddenException();
    }

    OrderStatus status = order.getStatus();
    if (status == OrderStatus.CANCELED) {
        throw new OrderAlreadyCanceledException();
    }
    if (status != OrderStatus.PROCESSING) {
        // Covers COMPLETED, FAILED, REFUNDED
        throw new OrderNotCancellableException();
    }

    // Self-publish PaymentCanceled via the existing CDC pipeline.
    // Mirrors the ORDER_CREATED publish pattern at OrderServiceImpl line 163
    // and the PayPal IPN-cancel pattern at PaymentServiceImpl ~line 183.
    // The EventPublisherListener writes the payload to Mongo; CDC routes
    // it to topic order-service.order.canceled-status; OrderServiceListener
    // consumes it and runs handleCanceledOrder (which dedupes via
    // ProcessedPaymentEvent and rolls back inventory).
    PaymentCanceled paymentCanceled = PaymentCanceled.newBuilder()
        .setOrderId(orderId)
        .build();
    eventPublisher.publishEvent(new MongoSavedEvent(
        this,
        EcommerceEvent.PAYMENT_CANCELED.getValue(),
        paymentCanceled));

    return OrderCancelResponse.builder()
        .orderId(orderId)
        .status(OrderStatus.CANCELED)
        .build();
}
```

No new constructor parameter is needed — `eventPublisher` is already a field on `OrderServiceImpl` (used by the `create` path). Required imports if not already present:

```java
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
```

- [ ] **Step 6: Run the test — expect PASS**

```bash
cd order-service && mvn -q test -Dtest=OrderCancelServiceTest
```

Expected: PASS, all 7 tests green.

- [ ] **Step 7: Run the full order-service test suite**

```bash
cd order-service && mvn -q test
```

Expected: PASS or only pre-existing failures (do not "fix" pre-existing failures by deleting them).

- [ ] **Step 8: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/service/OrderService.java \
        order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java \
        order-service/src/test/java/org/aibles/order_service/service/OrderCancelServiceTest.java \
        # plus OrderServiceConfiguration if you added a constructor arg
git commit -m "$(cat <<'EOF'
feat(order-service): add OrderService.cancel reusing saga path

User-cancel publishes PaymentCanceled to the existing
order-service.order.canceled-status topic. The same listener and
handleCanceledOrder flow that drives PayPal-cancel and saga-timeout-cancel
runs unchanged, including ProcessedPaymentEvent dedup, status flip to
CANCELED, and inventory rollback.

State guard: only PROCESSING orders are cancellable. COMPLETED, FAILED,
and REFUNDED yield ORDER_NOT_CANCELLABLE; CANCELED yields
ORDER_ALREADY_CANCELED.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task 9: Controller Endpoint

**Files:**
- Modify: `order-service/src/main/java/org/aibles/order_service/controller/OrderController.java`
- Test: `order-service/src/test/java/org/aibles/order_service/controller/OrderControllerCancelTest.java`

- [ ] **Step 1: Write the failing controller test**

Create `order-service/src/test/java/org/aibles/order_service/controller/OrderControllerCancelTest.java`:

```java
package org.aibles.order_service.controller;

import org.aibles.ecommerce.common_dto.exception.OrderAlreadyCanceledException;
import org.aibles.ecommerce.common_dto.exception.OrderNotCancellableException;
import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.dto.response.OrderCancelResponse;
import org.aibles.order_service.service.OrderService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(controllers = OrderController.class,
    excludeAutoConfiguration = {
        org.springframework.boot.autoconfigure.security.servlet.SecurityAutoConfiguration.class,
        org.springframework.boot.autoconfigure.security.servlet.SecurityFilterAutoConfiguration.class
    })
@AutoConfigureMockMvc(addFilters = false)
class OrderControllerCancelTest {

    @Autowired
    private MockMvc mvc;

    @MockBean
    private OrderService orderService;

    @Test
    void cancelHappyPath_returnsCanceled() throws Exception {
        when(orderService.cancel(eq("u1"), eq("o1")))
            .thenReturn(OrderCancelResponse.builder()
                .orderId("o1").status(OrderStatus.CANCELED).build());

        mvc.perform(patch("/v1/orders/o1:cancel")
                .header("X-User-Id", "u1"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.order_id").value("o1"))
            .andExpect(jsonPath("$.data.status").value("CANCELED"));
    }

    @Test
    void cancelNotCancellable_returns409() throws Exception {
        when(orderService.cancel(eq("u1"), eq("o2")))
            .thenThrow(new OrderNotCancellableException());

        mvc.perform(patch("/v1/orders/o2:cancel")
                .header("X-User-Id", "u1"))
            .andExpect(status().isConflict());
    }

    @Test
    void cancelAlreadyCanceled_returns409() throws Exception {
        when(orderService.cancel(eq("u1"), eq("o3")))
            .thenThrow(new OrderAlreadyCanceledException());

        mvc.perform(patch("/v1/orders/o3:cancel")
                .header("X-User-Id", "u1"))
            .andExpect(status().isConflict());
    }
}
```

If the project's exception handler returns a different HTTP status mapping than what `BaseException` → `409` would produce, adjust the assertions to match. Verify by reading the global exception handler in `core-exception-api`.

If `WebMvcTest` fails to load the order-service application context due to Vault/Mongo dependencies, mirror the pattern in `authorization-server`'s test config: add `src/test/resources/application.yml` disabling Vault and excluding its autoconfiguration. Check whether `order-service` already has such a file before creating one.

- [ ] **Step 2: Run the test — expect FAIL**

```bash
cd order-service && mvn -q test -Dtest=OrderControllerCancelTest
```

Expected: FAIL — endpoint mapping doesn't exist.

- [ ] **Step 3: Add the endpoint to `OrderController`**

Insert this method into `OrderController`:

```java
@PatchMapping("/{orderId}:cancel")
@ResponseStatus(HttpStatus.OK)
public BaseResponse cancel(@RequestHeader("X-User-Id") String userId,
                           @PathVariable String orderId) {
    log.info("(cancel) user={} order={}", userId, orderId);
    return BaseResponse.ok(orderService.cancel(userId, orderId));
}
```

Add the import for `PatchMapping` if not already present. The existing wildcard import `org.springframework.web.bind.annotation.*` should cover it.

**Note on the colon in the path:** Spring MVC happily routes `:cancel` as a literal path segment. The convention matches existing endpoints like `/v1/auth:login` and `/v1/admin/users:filter`. No URL encoding is needed in the route declaration; clients send the URL as-is.

- [ ] **Step 4: Run the test — expect PASS**

```bash
cd order-service && mvn -q test -Dtest=OrderControllerCancelTest
```

Expected: PASS, all 3 tests green.

- [ ] **Step 5: Run the full order-service test suite**

```bash
cd order-service && mvn -q test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/controller/OrderController.java \
        order-service/src/test/java/org/aibles/order_service/controller/OrderControllerCancelTest.java
git commit -m "$(cat <<'EOF'
feat(order-service): expose PATCH /v1/orders/{id}:cancel

Wires the new OrderService.cancel into the controller. Auth: any
authenticated user; ownership and state checks enforced in the service.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Section 5 — Documentation

### Task 10: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add an "Observability" subsection**

Open `CLAUDE.md`. Find the "Code Conventions (non-obvious)" section. Add a new subsection at the bottom of that section:

```markdown
### Observability

Every JVM service exposes Spring Boot Actuator on a separate management
port (`9091`) so it's never reachable through the gateway. Three endpoints
matter:

- `/actuator/health/liveness` — k8s liveness probe target
- `/actuator/health/readiness` — k8s readiness probe target (gates traffic
  during startup until the service's external deps are reachable)
- `/actuator/prometheus` — Micrometer Prometheus scrape endpoint, tagged
  with `application=<service-name>`

Local-dev caveat: when nine services run on the same host via `make up`,
they all try to bind `9091` and only one wins. Either run a single service
at a time when smoke-testing actuator, or assign distinct management ports
in `services.list`. In k8s every pod has its own loopback so 9091 is fine
across the cluster.

The gateway intentionally does not route `/actuator/**`. The management
port is internal-only — protect it at the network level (k8s
NetworkPolicy, AWS SG) when deploying.
```

- [ ] **Step 2: Add a "CORS" subsection (or add to the existing gateway section)**

Find the existing "Gateway routing — no StripPrefix" subsection. Insert below it:

```markdown
### Gateway CORS

The gateway publishes a single `CorsConfigurationSource` covering all
routes. Allowed origins, methods, headers, and credentials live under
`application.gateway.cors.*` in `gateway/src/main/resources/application.yml`
(overridable via Vault for prod). Defaults are `http://localhost:3000`
and `http://localhost:5173` with `allow-credentials=true`.

Per-service CORS would be redundant — all browser traffic enters via the
gateway.
```

- [ ] **Step 3: Note the public BFF route in the existing service-routing area**

Append a single bullet to whichever bulleted list documents the public-vs-private route split (or add it to the "Image storage" section's neighbor):

```markdown
- `GET /bff-service/v1/products/**` is public (`PERMIT_ALL`) so the
  storefront detail page works without login. All other BFF routes
  require authentication.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: document actuator port, gateway CORS, public BFF route

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Final Verification

After all ten tasks are committed, run a top-level smoke pass:

- [ ] **End-to-end smoke**

1. `make build` — installs core modules including the updated common-dto.
2. `make up` — boots everything; auth, product, BFF, order all reach UP.
3. From a fresh terminal:

```bash
# CORS preflight reaches gateway and is honored
curl -i -X OPTIONS http://localhost:8080/authorization-server/v1/auth:login \
  -H "Origin: http://localhost:3000" \
  -H "Access-Control-Request-Method: POST" 2>&1 | grep -i "access-control"
# Expect Access-Control-Allow-Origin: http://localhost:3000 and Allow-Methods including POST

# Public BFF product detail without auth
PID=$(curl -s http://localhost:8080/product-service/v1/products | jq -r '.data.contents[0].id')
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8080/bff-service/v1/products/$PID"
# Expect 200

# Order endpoints still walled
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/order-service/v1/orders
# Expect 401

# (After logging in and creating a PROCESSING order)
TOKEN=...   # access token from /v1/auth:login
ORDER_ID=...
curl -s -X PATCH "http://localhost:8080/order-service/v1/orders/${ORDER_ID}:cancel" \
  -H "Authorization: Bearer $TOKEN" | jq
# Expect { data: { order_id: "<id>", status: "CANCELED" } }

# A few seconds later, GET the order — status should be CANCELED in the read model
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:8080/order-service/v1/orders/${ORDER_ID}" | jq '.data.status'
# Expect "CANCELED"
```

4. Spot-check actuator on each service one at a time (per local-dev caveat):

```bash
# Stop everything else, run order-service alone via `mvn spring-boot:run` from order-service/
curl -s http://localhost:9091/actuator/health/liveness | jq
curl -s http://localhost:9091/actuator/prometheus | grep 'application="order-service"' | head -3
```

If any acceptance check fails, stop and investigate before declaring done.
