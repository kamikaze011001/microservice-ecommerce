# Mock PayPal Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone Spring Boot mock of PayPal's REST API so k6 stress tests and local frontend dev can run the full payment lifecycle (success / cancel / fail) without real PayPal, with `payment-service`/`core-paypal` code untouched.

**Architecture:** A new standalone module `mock-paypal-service` (Java 24, virtual threads) implements the exact 5 PayPal REST endpoints `core-paypal` calls plus one HTML "approve" page. It holds per-token state in an in-memory `ConcurrentHashMap` (single replica). The switch from real PayPal is config-only: point `application.paypal.base-url` at the mock. Browser reaches the approve page through the gateway (`Path=/mock-paypal-service/**`, context-path keeps the convention); k6 hits the approve endpoint directly with a `?decision=` param.

**Tech Stack:** Spring Boot 3.5.x, Java 24, Lombok, Spring MVC, Spring Boot Actuator, Maven. No Vault/DB/Kafka/Eureka deps.

---

## Conventions locked for this plan

- **Module path:** `mock-paypal-service/` at repo root (sibling of `payment-service/`).
- **Ports:** HTTP `8585`, management `18585` (follows the `1`+app-port management convention).
- **Context-path:** `/mock-paypal-service` (set in `application.yml`). Controllers use bare PayPal paths (`/v2/checkout/orders`, `/checkout`); the context-path prepends `/mock-paypal-service`.
- **payment-service `base-url` becomes:** `http://mock-paypal-service.apps.svc.cluster.local:8585/mock-paypal-service` (k8s) / `http://localhost:8585/mock-paypal-service` (local). The trailing `/mock-paypal-service` matches the context-path so `baseUrl + "/v2/checkout/orders"` resolves.
- **JSON casing:** every DTO is `@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)` — matches `core-paypal`.
- **Fail trigger:** the capture endpoint returns **HTTP 422** with a body whose `name` field is set, because `RestTemplateErrorHandler` throws `PaypalRestTemplateException` on any 4xx/5xx → `payment-service` publishes `PaymentFailed`.
- **Local runtime:** bare JVM process via `scripts/services.list` (NOT docker-compose). Local real→mock toggle = edit `docker/vault-configs/payment-service.json`.
- **Java version note:** repo services are Java 17 on Spring Boot 3.3.6, which does not support Java 24. This module pins **Spring Boot 3.5.x + Java 24** for itself only. If `mvn` reports the chosen patch version doesn't support Java 24, bump to the latest `3.5.x`.

---

## File Structure

**New module `mock-paypal-service/`:**

| File | Responsibility |
|---|---|
| `pom.xml` | Standalone Boot 3.5.x / Java 24 module |
| `Dockerfile` | Multi-stage JDK 24 build → runnable jar |
| `src/main/java/org/aibles/mockpaypal/MockPaypalApplication.java` | Spring Boot entrypoint |
| `.../model/Decision.java` | enum: PENDING, APPROVE, CANCEL, FAIL |
| `.../model/OrderState.java` | per-token state holder |
| `.../store/OrderStore.java` | `ConcurrentHashMap` wrapper: create / get / setDecision / setCapture |
| `.../dto/*` | request + response DTOs mirroring PayPal wire shapes |
| `.../web/OAuthController.java` | `POST /v1/oauth2/token` |
| `.../web/OrdersController.java` | create / capture / details endpoints |
| `.../web/CheckoutPageController.java` | `GET /checkout` HTML + decision redirects |
| `.../web/RefundController.java` | `POST /v2/payments/captures/{id}/refund` |
| `src/main/resources/application.yml` | ports, context-path, virtual threads, actuator, `mock.public-base-url` |
| `src/test/java/org/aibles/mockpaypal/**` | MockMvc slice tests + state-machine test |

**Modified existing files:**

| File | Change |
|---|---|
| `scripts/services.list` | register `mock-paypal-service 8585 - 3` |
| `gateway/src/main/resources/application.yml` | add `mock-paypal-service` route |
| `k8s/apps/base/mock-paypal-service/{deployment,service,kustomization}.yaml` | new base (created) |
| `k8s/apps/overlays/local/kustomization.yaml` | add base + patch payment-service env |
| `k8s/infra/jobs/03-vault-seed/seed.sh` | add mock block + gateway route uri + payment-service base-url override |
| `docker/vault-configs/mock-paypal-service.json` | new local Vault config |
| `docker/vault-configs/payment-service.json` | base-url override (commented toggle) |
| `scripts/vault/import-secrets.sh` | load the new config (if it enumerates files explicitly) |
| `k6-tests/tests/full-flow.js` | drive `?decision=` mix |

---

## Phase A — The mock service module

### Task 1: Maven module skeleton + application boots

**Files:**
- Create: `mock-paypal-service/pom.xml`
- Create: `mock-paypal-service/src/main/java/org/aibles/mockpaypal/MockPaypalApplication.java`
- Create: `mock-paypal-service/src/main/resources/application.yml`

- [ ] **Step 1: Write `pom.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>3.5.3</version>
        <relativePath/>
    </parent>
    <groupId>org.aibles</groupId>
    <artifactId>mock-paypal-service</artifactId>
    <version>0.0.1-SNAPSHOT</version>
    <name>mock-paypal-service</name>
    <description>Mock PayPal REST API for stress testing and local dev</description>
    <properties>
        <java.version>24</java.version>
    </properties>
    <dependencies>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-actuator</artifactId>
        </dependency>
        <dependency>
            <groupId>org.projectlombok</groupId>
            <artifactId>lombok</artifactId>
            <optional>true</optional>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
    <build>
        <plugins>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-compiler-plugin</artifactId>
                <configuration>
                    <annotationProcessorPaths>
                        <path>
                            <groupId>org.projectlombok</groupId>
                            <artifactId>lombok</artifactId>
                        </path>
                    </annotationProcessorPaths>
                </configuration>
            </plugin>
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
                <configuration>
                    <excludes>
                        <exclude>
                            <groupId>org.projectlombok</groupId>
                            <artifactId>lombok</artifactId>
                        </exclude>
                    </excludes>
                </configuration>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Write `MockPaypalApplication.java`**

```java
package org.aibles.mockpaypal;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class MockPaypalApplication {
    public static void main(String[] args) {
        SpringApplication.run(MockPaypalApplication.class, args);
    }
}
```

- [ ] **Step 3: Write `application.yml`**

```yaml
server:
  port: 8585
  servlet:
    context-path: /mock-paypal-service
spring:
  application:
    name: mock-paypal-service
  threads:
    virtual:
      enabled: true
management:
  server:
    port: 18585
  endpoints:
    web:
      exposure:
        include: health
  endpoint:
    health:
      probes:
        enabled: true
mock:
  public-base-url: ${MOCK_PUBLIC_BASE_URL:http://localhost:8585/mock-paypal-service}
```

- [ ] **Step 4: Verify it compiles and boots on Java 24**

Run: `cd mock-paypal-service && mvn -q clean compile`
Expected: BUILD SUCCESS. If it fails complaining Java 24 is unsupported by Boot 3.5.3, change `<version>3.5.3</version>` to the latest `3.5.x` and retry.

- [ ] **Step 5: Commit**

```bash
git add mock-paypal-service/pom.xml mock-paypal-service/src/main/java mock-paypal-service/src/main/resources
git commit -m "feat(mock-paypal): bootstrap Java 24 Spring Boot module"
```

---

### Task 2: In-memory order store

**Files:**
- Create: `mock-paypal-service/src/main/java/org/aibles/mockpaypal/model/Decision.java`
- Create: `mock-paypal-service/src/main/java/org/aibles/mockpaypal/model/OrderState.java`
- Create: `mock-paypal-service/src/main/java/org/aibles/mockpaypal/store/OrderStore.java`
- Test: `mock-paypal-service/src/test/java/org/aibles/mockpaypal/store/OrderStoreTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.mockpaypal.store;

import org.aibles.mockpaypal.model.Decision;
import org.aibles.mockpaypal.model.OrderState;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class OrderStoreTest {

    @Test
    void create_thenGet_returnsStoredState() {
        OrderStore store = new OrderStore();
        OrderState s = store.create("order-1", "USD", "99.99",
                "https://r/success", "https://r/cancel");

        assertThat(s.getToken()).isNotBlank();
        assertThat(s.getOrderId()).isEqualTo("order-1");
        assertThat(s.getDecision()).isEqualTo(Decision.PENDING);
        assertThat(store.get(s.getToken())).isSameAs(s);
    }

    @Test
    void setDecision_updatesState() {
        OrderStore store = new OrderStore();
        OrderState s = store.create("order-2", "USD", "10.00", "r", "c");

        store.setDecision(s.getToken(), Decision.FAIL);

        assertThat(store.get(s.getToken()).getDecision()).isEqualTo(Decision.FAIL);
    }

    @Test
    void setCapture_recordsCaptureId() {
        OrderStore store = new OrderStore();
        OrderState s = store.create("order-3", "USD", "10.00", "r", "c");

        store.setCapture(s.getToken(), "cap-123");

        assertThat(store.get(s.getToken()).getCaptureId()).isEqualTo("cap-123");
    }

    @Test
    void get_unknownToken_returnsNull() {
        assertThat(new OrderStore().get("nope")).isNull();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mock-paypal-service && mvn -q -Dtest=OrderStoreTest test`
Expected: FAIL — `OrderStore`, `OrderState`, `Decision` do not exist (compilation error).

- [ ] **Step 3: Write `Decision.java`**

```java
package org.aibles.mockpaypal.model;

public enum Decision {
    PENDING, APPROVE, CANCEL, FAIL
}
```

- [ ] **Step 4: Write `OrderState.java`**

```java
package org.aibles.mockpaypal.model;

import lombok.Builder;
import lombok.Data;

@Data
@Builder
public class OrderState {
    private final String token;
    private final String orderId;
    private final String currencyCode;
    private final String value;
    private final String returnUrl;
    private final String cancelUrl;
    private volatile Decision decision;
    private volatile String captureId;
}
```

- [ ] **Step 5: Write `OrderStore.java`**

```java
package org.aibles.mockpaypal.store;

import org.aibles.mockpaypal.model.Decision;
import org.aibles.mockpaypal.model.OrderState;
import org.springframework.stereotype.Component;

import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

@Component
public class OrderStore {

    private final ConcurrentHashMap<String, OrderState> states = new ConcurrentHashMap<>();

    public OrderState create(String orderId, String currencyCode, String value,
                             String returnUrl, String cancelUrl) {
        String token = "MOCKORDER-" + UUID.randomUUID().toString().replace("-", "").toUpperCase();
        OrderState state = OrderState.builder()
                .token(token)
                .orderId(orderId)
                .currencyCode(currencyCode)
                .value(value)
                .returnUrl(returnUrl)
                .cancelUrl(cancelUrl)
                .decision(Decision.PENDING)
                .build();
        states.put(token, state);
        return state;
    }

    public OrderState get(String token) {
        return states.get(token);
    }

    public void setDecision(String token, Decision decision) {
        OrderState s = states.get(token);
        if (s != null) {
            s.setDecision(decision);
        }
    }

    public void setCapture(String token, String captureId) {
        OrderState s = states.get(token);
        if (s != null) {
            s.setCaptureId(captureId);
        }
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd mock-paypal-service && mvn -q -Dtest=OrderStoreTest test`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add mock-paypal-service/src/main/java/org/aibles/mockpaypal/model mock-paypal-service/src/main/java/org/aibles/mockpaypal/store mock-paypal-service/src/test
git commit -m "feat(mock-paypal): in-memory order store with decision state"
```

---

### Task 3: Response/request DTOs

These mirror the exact wire shapes `core-paypal` produces/consumes (all snake_case). No behavior yet — just the data carriers, so later controller tasks can reference them.

**Files:**
- Create: `mock-paypal-service/src/main/java/org/aibles/mockpaypal/dto/TokenResponse.java`
- Create: `.../dto/CreateOrderRequest.java`
- Create: `.../dto/PaypalLink.java`
- Create: `.../dto/OrderResponse.java`
- Create: `.../dto/PurchaseUnitView.java`
- Create: `.../dto/CaptureResponse.java`
- Create: `.../dto/OrderDetailResponse.java`
- Create: `.../dto/RefundResponse.java`
- Create: `.../dto/PaypalErrorResponse.java`

- [ ] **Step 1: Write `TokenResponse.java`**

```java
package org.aibles.mockpaypal.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;

@Data
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class TokenResponse {
    private String accessToken;
    private String tokenType;
    private long expiresIn;
}
```

- [ ] **Step 2: Write `CreateOrderRequest.java` (inbound parse — only the fields we read)**

```java
package org.aibles.mockpaypal.dto;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.Data;

import java.util.List;

@Data
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
@JsonIgnoreProperties(ignoreUnknown = true)
public class CreateOrderRequest {
    private List<PurchaseUnit> purchaseUnits;
    private PaymentSource paymentSource;

    @Data
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class PurchaseUnit {
        private Amount amount;
        private String customId;
    }

    @Data
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class Amount {
        private String currencyCode;
        private String value;
    }

    @Data
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class PaymentSource {
        private Paypal paypal;
    }

    @Data
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class Paypal {
        private ExperienceContext experienceContext;
    }

    @Data
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class ExperienceContext {
        private String returnUrl;
        private String cancelUrl;
    }
}
```

- [ ] **Step 3: Write `PaypalLink.java`**

```java
package org.aibles.mockpaypal.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;

@Data
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class PaypalLink {
    private String href;
    private String rel;
    private String method;
}
```

- [ ] **Step 4: Write `OrderResponse.java`**

```java
package org.aibles.mockpaypal.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;

import java.util.List;

@Data
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class OrderResponse {
    private String id;
    private String status;
    private List<PaypalLink> links;
}
```

- [ ] **Step 5: Write `PurchaseUnitView.java` (shared by capture + details responses)**

```java
package org.aibles.mockpaypal.dto;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;

import java.util.List;

@Data
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
@JsonInclude(JsonInclude.Include.NON_NULL)
public class PurchaseUnitView {
    private Amount amount;
    private String customId;
    private Payments payments;

    @Data
    @AllArgsConstructor
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public static class Amount {
        private String currencyCode;
        private String value;
    }

    @Data
    @AllArgsConstructor
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    @JsonInclude(JsonInclude.Include.NON_NULL)
    public static class Payments {
        private List<Capture> captures;
    }

    @Data
    @AllArgsConstructor
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    @JsonInclude(JsonInclude.Include.NON_NULL)
    public static class Capture {
        private String id;
        private String status;
        private String customId;
    }
}
```

- [ ] **Step 6: Write `CaptureResponse.java`**

```java
package org.aibles.mockpaypal.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;

import java.util.List;

@Data
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class CaptureResponse {
    private String id;
    private String status;
    private String intent;
    private List<PurchaseUnitView> purchaseUnits;
}
```

- [ ] **Step 7: Write `OrderDetailResponse.java`**

```java
package org.aibles.mockpaypal.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;

import java.util.List;

@Data
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class OrderDetailResponse {
    private String id;
    private String intent;
    private String status;
    private List<PurchaseUnitView> purchaseUnits;
    private List<PaypalLink> links;
}
```

- [ ] **Step 8: Write `RefundResponse.java` (note `amount` is a primitive double, matching core-paypal)**

```java
package org.aibles.mockpaypal.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;

import java.util.List;

@Data
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class RefundResponse {
    private String id;
    private String status;
    private String customId;
    private double amount;
    private List<PaypalLink> links;
}
```

- [ ] **Step 9: Write `PaypalErrorResponse.java` (the 422 body for the fail path)**

```java
package org.aibles.mockpaypal.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;

@Data
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class PaypalErrorResponse {
    private String name;
    private String message;
}
```

- [ ] **Step 10: Verify compile**

Run: `cd mock-paypal-service && mvn -q clean compile`
Expected: BUILD SUCCESS.

- [ ] **Step 11: Commit**

```bash
git add mock-paypal-service/src/main/java/org/aibles/mockpaypal/dto
git commit -m "feat(mock-paypal): wire-shape DTOs matching core-paypal JSON"
```

---

### Task 4: OAuth token endpoint

**Files:**
- Create: `mock-paypal-service/src/main/java/org/aibles/mockpaypal/web/OAuthController.java`
- Test: `mock-paypal-service/src/test/java/org/aibles/mockpaypal/web/OAuthControllerTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.mockpaypal.web;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(OAuthController.class)
class OAuthControllerTest {

    @Autowired MockMvc mvc;

    @Test
    void token_returnsMockAccessToken() throws Exception {
        mvc.perform(post("/v1/oauth2/token")
                        .contentType("application/x-www-form-urlencoded")
                        .content("grant_type=client_credentials"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.access_token").value("mock-access-token"))
                .andExpect(jsonPath("$.token_type").value("Bearer"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mock-paypal-service && mvn -q -Dtest=OAuthControllerTest test`
Expected: FAIL — `OAuthController` does not exist.

- [ ] **Step 3: Write `OAuthController.java`**

```java
package org.aibles.mockpaypal.web;

import org.aibles.mockpaypal.dto.TokenResponse;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class OAuthController {

    @PostMapping("/v1/oauth2/token")
    public TokenResponse token() {
        return new TokenResponse("mock-access-token", "Bearer", 32400L);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mock-paypal-service && mvn -q -Dtest=OAuthControllerTest test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mock-paypal-service/src/main/java/org/aibles/mockpaypal/web/OAuthController.java mock-paypal-service/src/test/java/org/aibles/mockpaypal/web/OAuthControllerTest.java
git commit -m "feat(mock-paypal): OAuth token endpoint"
```

---

### Task 5: Create-order endpoint

Reads `custom_id`, amount, return/cancel URLs; stores state; returns `id` + `links[]` with an `approve`/`payer-action` link to the mock checkout page.

**Files:**
- Create: `mock-paypal-service/src/main/java/org/aibles/mockpaypal/web/OrdersController.java`
- Test: `mock-paypal-service/src/test/java/org/aibles/mockpaypal/web/CreateOrderTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.mockpaypal.web;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import static org.hamcrest.Matchers.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
@TestPropertySource(properties = "mock.public-base-url=http://mock.test/mock-paypal-service")
class CreateOrderTest {

    @Autowired MockMvc mvc;

    private static final String BODY = """
        {
          "intent":"CAPTURE",
          "purchase_units":[{"amount":{"currency_code":"USD","value":"99.99"},"custom_id":"order-777"}],
          "payment_source":{"paypal":{"experience_context":{
            "return_url":"http://gw/payment-service/v1/paypal:success",
            "cancel_url":"http://gw/payment-service/v1/paypal:cancel"}}}
        }
        """;

    @Test
    void createOrder_returnsApproveLinkToCheckoutPage() throws Exception {
        mvc.perform(post("/v2/checkout/orders")
                        .contentType("application/json").content(BODY))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id", startsWith("MOCKORDER-")))
                .andExpect(jsonPath("$.status").value("PAYER_ACTION_REQUIRED"))
                .andExpect(jsonPath("$.links[?(@.rel=='payer-action')].href",
                        hasItem(allOf(
                                startsWith("http://mock.test/mock-paypal-service/checkout?token=MOCKORDER-")))));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mock-paypal-service && mvn -q -Dtest=CreateOrderTest test`
Expected: FAIL — `OrdersController` does not exist.

- [ ] **Step 3: Write `OrdersController.java` (create-order only for now)**

```java
package org.aibles.mockpaypal.web;

import org.aibles.mockpaypal.dto.CreateOrderRequest;
import org.aibles.mockpaypal.dto.OrderResponse;
import org.aibles.mockpaypal.dto.PaypalLink;
import org.aibles.mockpaypal.model.OrderState;
import org.aibles.mockpaypal.store.OrderStore;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
public class OrdersController {

    private final OrderStore store;
    private final String publicBaseUrl;

    public OrdersController(OrderStore store,
                            @Value("${mock.public-base-url}") String publicBaseUrl) {
        this.store = store;
        this.publicBaseUrl = publicBaseUrl;
    }

    @PostMapping("/v2/checkout/orders")
    public OrderResponse createOrder(@RequestBody CreateOrderRequest req) {
        CreateOrderRequest.PurchaseUnit pu = req.getPurchaseUnits().get(0);
        CreateOrderRequest.ExperienceContext ctx =
                req.getPaymentSource().getPaypal().getExperienceContext();

        OrderState state = store.create(
                pu.getCustomId(),
                pu.getAmount().getCurrencyCode(),
                pu.getAmount().getValue(),
                ctx.getReturnUrl(),
                ctx.getCancelUrl());

        String approveHref = publicBaseUrl + "/checkout?token=" + state.getToken();
        List<PaypalLink> links = List.of(
                new PaypalLink(publicBaseUrl + "/v2/checkout/orders/" + state.getToken(), "self", "GET"),
                new PaypalLink(approveHref, "approve", "GET"),
                new PaypalLink(approveHref, "payer-action", "GET"));

        return new OrderResponse(state.getToken(), "PAYER_ACTION_REQUIRED", links);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mock-paypal-service && mvn -q -Dtest=CreateOrderTest test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mock-paypal-service/src/main/java/org/aibles/mockpaypal/web/OrdersController.java mock-paypal-service/src/test/java/org/aibles/mockpaypal/web/CreateOrderTest.java
git commit -m "feat(mock-paypal): create-order endpoint with approve link"
```

---

### Task 6: Checkout page + decision redirects

Browser (no `decision`) gets HTML with 3 buttons. `?decision=approve|fail` → 302 to `return_url`; `cancel` → 302 to `cancel_url`. Decision recorded on state.

**Files:**
- Create: `mock-paypal-service/src/main/java/org/aibles/mockpaypal/web/CheckoutPageController.java`
- Test: `mock-paypal-service/src/test/java/org/aibles/mockpaypal/web/CheckoutPageTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.mockpaypal.web;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
class CheckoutPageTest {

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper om;

    private static final String BODY = """
        {"intent":"CAPTURE",
         "purchase_units":[{"amount":{"currency_code":"USD","value":"5.00"},"custom_id":"o-1"}],
         "payment_source":{"paypal":{"experience_context":{
           "return_url":"http://gw/ok","cancel_url":"http://gw/no"}}}}
        """;

    private String createTokenAndGet() throws Exception {
        MvcResult r = mvc.perform(post("/v2/checkout/orders")
                .contentType("application/json").content(BODY)).andReturn();
        JsonNode n = om.readTree(r.getResponse().getContentAsString());
        return n.get("id").asText();
    }

    @Test
    void checkoutPage_html_hasThreeButtons() throws Exception {
        String token = createTokenAndGet();
        mvc.perform(get("/checkout").param("token", token))
                .andExpect(status().isOk())
                .andExpect(content().string(org.hamcrest.Matchers.containsString("decision=approve")))
                .andExpect(content().string(org.hamcrest.Matchers.containsString("decision=cancel")))
                .andExpect(content().string(org.hamcrest.Matchers.containsString("decision=fail")));
    }

    @Test
    void decisionApprove_redirectsToReturnUrl() throws Exception {
        String token = createTokenAndGet();
        mvc.perform(get("/checkout").param("token", token).param("decision", "approve"))
                .andExpect(status().is3xxRedirection())
                .andExpect(header().string("Location", "http://gw/ok"));
    }

    @Test
    void decisionFail_redirectsToReturnUrl() throws Exception {
        String token = createTokenAndGet();
        mvc.perform(get("/checkout").param("token", token).param("decision", "fail"))
                .andExpect(status().is3xxRedirection())
                .andExpect(header().string("Location", "http://gw/ok"));
    }

    @Test
    void decisionCancel_redirectsToCancelUrl() throws Exception {
        String token = createTokenAndGet();
        mvc.perform(get("/checkout").param("token", token).param("decision", "cancel"))
                .andExpect(status().is3xxRedirection())
                .andExpect(header().string("Location", "http://gw/no"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mock-paypal-service && mvn -q -Dtest=CheckoutPageTest test`
Expected: FAIL — `CheckoutPageController` does not exist.

- [ ] **Step 3: Write `CheckoutPageController.java`**

```java
package org.aibles.mockpaypal.web;

import org.aibles.mockpaypal.model.Decision;
import org.aibles.mockpaypal.model.OrderState;
import org.aibles.mockpaypal.store.OrderStore;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;

@RestController
public class CheckoutPageController {

    private final OrderStore store;

    public CheckoutPageController(OrderStore store) {
        this.store = store;
    }

    @GetMapping("/checkout")
    public ResponseEntity<String> checkout(@RequestParam String token,
                                           @RequestParam(required = false) String decision) {
        OrderState state = store.get(token);
        if (state == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                    .body("Unknown token: " + token);
        }

        if (decision == null) {
            return ResponseEntity.ok()
                    .contentType(MediaType.TEXT_HTML)
                    .body(renderPage(token, state));
        }

        return switch (decision) {
            case "approve" -> {
                store.setDecision(token, Decision.APPROVE);
                yield redirect(state.getReturnUrl());
            }
            case "fail" -> {
                store.setDecision(token, Decision.FAIL);
                yield redirect(state.getReturnUrl());
            }
            case "cancel" -> {
                store.setDecision(token, Decision.CANCEL);
                yield redirect(state.getCancelUrl());
            }
            default -> ResponseEntity.badRequest().body("Unknown decision: " + decision);
        };
    }

    private ResponseEntity<String> redirect(String location) {
        return ResponseEntity.status(HttpStatus.FOUND).location(URI.create(location)).build();
    }

    private String renderPage(String token, OrderState state) {
        String base = "/mock-paypal-service/checkout?token=" + token + "&decision=";
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <title>Mock PayPal Checkout</title></head>
            <body style="font-family:sans-serif;max-width:420px;margin:60px auto;text-align:center">
            <h2>Mock PayPal</h2>
            <p>Order <code>%s</code> &mdash; <b>%s %s</b></p>
            <p>
              <a href="%sapprove" style="display:inline-block;padding:12px 20px;background:#0070ba;color:#fff;text-decoration:none;border-radius:6px">Approve</a>
              <a href="%scancel"  style="display:inline-block;padding:12px 20px;background:#888;color:#fff;text-decoration:none;border-radius:6px">Cancel</a>
              <a href="%sfail"    style="display:inline-block;padding:12px 20px;background:#c0392b;color:#fff;text-decoration:none;border-radius:6px">Fail</a>
            </p></body></html>
            """.formatted(state.getOrderId(), state.getValue(), state.getCurrencyCode(),
                          base, base, base);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mock-paypal-service && mvn -q -Dtest=CheckoutPageTest test`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add mock-paypal-service/src/main/java/org/aibles/mockpaypal/web/CheckoutPageController.java mock-paypal-service/src/test/java/org/aibles/mockpaypal/web/CheckoutPageTest.java
git commit -m "feat(mock-paypal): checkout page + decision redirects"
```

---

### Task 7: Capture + order-details endpoints

Capture: if decision==FAIL → 422 with error body; else → COMPLETED + capture id. Details: returns `custom_id` and capture id.

**Files:**
- Modify: `mock-paypal-service/src/main/java/org/aibles/mockpaypal/web/OrdersController.java`
- Test: `mock-paypal-service/src/test/java/org/aibles/mockpaypal/web/CaptureAndDetailsTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.mockpaypal.web;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
class CaptureAndDetailsTest {

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper om;

    private static final String BODY = """
        {"intent":"CAPTURE",
         "purchase_units":[{"amount":{"currency_code":"USD","value":"5.00"},"custom_id":"o-cap"}],
         "payment_source":{"paypal":{"experience_context":{
           "return_url":"http://gw/ok","cancel_url":"http://gw/no"}}}}
        """;

    private String newToken() throws Exception {
        MvcResult r = mvc.perform(post("/v2/checkout/orders")
                .contentType("application/json").content(BODY)).andReturn();
        return om.readTree(r.getResponse().getContentAsString()).get("id").asText();
    }

    @Test
    void capture_afterApprove_returnsCompletedWithCaptureId() throws Exception {
        String token = newToken();
        mvc.perform(get("/checkout").param("token", token).param("decision", "approve"));

        mvc.perform(post("/v2/checkout/orders/" + token + "/capture"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("COMPLETED"))
                .andExpect(jsonPath("$.purchase_units[0].custom_id").value("o-cap"))
                .andExpect(jsonPath("$.purchase_units[0].payments.captures[0].id",
                        org.hamcrest.Matchers.startsWith("MOCKCAP-")))
                .andExpect(jsonPath("$.purchase_units[0].payments.captures[0].status").value("COMPLETED"));
    }

    @Test
    void capture_afterFail_returns422WithErrorName() throws Exception {
        String token = newToken();
        mvc.perform(get("/checkout").param("token", token).param("decision", "fail"));

        mvc.perform(post("/v2/checkout/orders/" + token + "/capture"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.name").value("UNPROCESSABLE_ENTITY"));
    }

    @Test
    void details_afterCapture_exposesCustomIdAndCaptureId() throws Exception {
        String token = newToken();
        mvc.perform(get("/checkout").param("token", token).param("decision", "approve"));
        mvc.perform(post("/v2/checkout/orders/" + token + "/capture"));

        mvc.perform(get("/v2/checkout/orders/" + token))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.purchase_units[0].custom_id").value("o-cap"))
                .andExpect(jsonPath("$.purchase_units[0].payments.captures[0].id",
                        org.hamcrest.Matchers.startsWith("MOCKCAP-")));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mock-paypal-service && mvn -q -Dtest=CaptureAndDetailsTest test`
Expected: FAIL — capture/details endpoints don't exist (404).

- [ ] **Step 3: Add capture + details to `OrdersController.java`**

Add these imports at the top of the existing file:

```java
import org.aibles.mockpaypal.dto.CaptureResponse;
import org.aibles.mockpaypal.dto.OrderDetailResponse;
import org.aibles.mockpaypal.dto.PaypalErrorResponse;
import org.aibles.mockpaypal.dto.PurchaseUnitView;
import org.aibles.mockpaypal.model.Decision;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

import java.util.UUID;
```

Add these methods inside the `OrdersController` class:

```java
    @PostMapping("/v2/checkout/orders/{token}/capture")
    public ResponseEntity<?> capture(@PathVariable String token) {
        OrderState state = store.get(token);
        if (state == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                    .body(new PaypalErrorResponse("RESOURCE_NOT_FOUND", "Unknown order " + token));
        }
        if (state.getDecision() == Decision.FAIL) {
            return ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY)
                    .body(new PaypalErrorResponse("UNPROCESSABLE_ENTITY",
                            "The instrument presented was either declined by the processor or bank, or it can't be used for this payment."));
        }
        String captureId = "MOCKCAP-" + UUID.randomUUID().toString().replace("-", "").toUpperCase();
        store.setCapture(token, captureId);
        return ResponseEntity.ok(new CaptureResponse(
                token, "COMPLETED", "CAPTURE",
                List.of(purchaseUnitView(state, captureId))));
    }

    @GetMapping("/v2/checkout/orders/{token}")
    public ResponseEntity<?> details(@PathVariable String token) {
        OrderState state = store.get(token);
        if (state == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                    .body(new PaypalErrorResponse("RESOURCE_NOT_FOUND", "Unknown order " + token));
        }
        String status = state.getCaptureId() != null ? "COMPLETED" : "APPROVED";
        return ResponseEntity.ok(new OrderDetailResponse(
                token, "CAPTURE", status,
                List.of(purchaseUnitView(state, state.getCaptureId())),
                List.of()));
    }

    private PurchaseUnitView purchaseUnitView(OrderState state, String captureId) {
        PurchaseUnitView.Payments payments = null;
        if (captureId != null) {
            payments = new PurchaseUnitView.Payments(List.of(
                    new PurchaseUnitView.Capture(captureId, "COMPLETED", state.getOrderId())));
        }
        return new PurchaseUnitView(
                new PurchaseUnitView.Amount(state.getCurrencyCode(), state.getValue()),
                state.getOrderId(),
                payments);
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mock-paypal-service && mvn -q -Dtest=CaptureAndDetailsTest test`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add mock-paypal-service/src/main/java/org/aibles/mockpaypal/web/OrdersController.java mock-paypal-service/src/test/java/org/aibles/mockpaypal/web/CaptureAndDetailsTest.java
git commit -m "feat(mock-paypal): capture (success/422) + order-details endpoints"
```

---

### Task 8: Refund endpoint

**Files:**
- Create: `mock-paypal-service/src/main/java/org/aibles/mockpaypal/web/RefundController.java`
- Test: `mock-paypal-service/src/test/java/org/aibles/mockpaypal/web/RefundControllerTest.java`

- [ ] **Step 1: Write the failing test**

```java
package org.aibles.mockpaypal.web;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(RefundController.class)
class RefundControllerTest {

    @Autowired MockMvc mvc;

    @Test
    void refund_returnsCompleted() throws Exception {
        mvc.perform(post("/v2/payments/captures/CAP-1/refund")
                        .contentType("application/json")
                        .content("{\"custom_id\":\"o-1\",\"amount\":{\"currency_code\":\"USD\",\"value\":\"5.00\"}}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("COMPLETED"))
                .andExpect(jsonPath("$.custom_id").value("o-1"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mock-paypal-service && mvn -q -Dtest=RefundControllerTest test`
Expected: FAIL — `RefundController` does not exist.

- [ ] **Step 3: Write `RefundController.java`**

```java
package org.aibles.mockpaypal.web;

import com.fasterxml.jackson.databind.JsonNode;
import org.aibles.mockpaypal.dto.PaypalLink;
import org.aibles.mockpaypal.dto.RefundResponse;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
public class RefundController {

    @PostMapping("/v2/payments/captures/{captureId}/refund")
    public RefundResponse refund(@PathVariable String captureId, @RequestBody(required = false) JsonNode body) {
        String customId = body != null && body.hasNonNull("custom_id")
                ? body.get("custom_id").asText() : null;
        double amount = 0.0;
        if (body != null && body.has("amount") && body.get("amount").hasNonNull("value")) {
            amount = Double.parseDouble(body.get("amount").get("value").asText());
        }
        String refundId = "MOCKREFUND-" + UUID.randomUUID().toString().replace("-", "").toUpperCase();
        return new RefundResponse(refundId, "COMPLETED", customId, amount,
                List.of(new PaypalLink("/v2/payments/refunds/" + refundId, "self", "GET")));
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mock-paypal-service && mvn -q -Dtest=RefundControllerTest test`
Expected: PASS.

- [ ] **Step 5: Run the whole module test suite**

Run: `cd mock-paypal-service && mvn -q clean test`
Expected: BUILD SUCCESS, all tests green.

- [ ] **Step 6: Commit**

```bash
git add mock-paypal-service/src/main/java/org/aibles/mockpaypal/web/RefundController.java mock-paypal-service/src/test/java/org/aibles/mockpaypal/web/RefundControllerTest.java
git commit -m "feat(mock-paypal): refund endpoint"
```

---

## Phase B — Build & image wiring

### Task 9: Dockerfile (JDK 24) + image build registration

The shared image build likely uses a JDK 17 base, which can't compile this module. Give the mock its own self-contained multi-stage Dockerfile.

**Files:**
- Create: `mock-paypal-service/Dockerfile`
- Modify: `k8s/images/build.sh`

- [ ] **Step 1: Write `mock-paypal-service/Dockerfile`**

```dockerfile
# Stage 1 — build
FROM maven:3.9-eclipse-temurin-24 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q -e -B dependency:go-offline
COPY src ./src
RUN mvn -q -B clean package -DskipTests

# Stage 2 — run
FROM eclipse-temurin:24-jre
WORKDIR /app
COPY --from=build /app/target/mock-paypal-service-*.jar app.jar
EXPOSE 8585 18585
ENTRYPOINT ["java","-XX:MaxRAMPercentage=75.0","-jar","/app/app.jar"]
```

> If `maven:3.9-eclipse-temurin-24` or `eclipse-temurin:24-jre` tags are unavailable, run `docker search`/check Docker Hub for the current JDK 24 tag and substitute. The two-stage shape stays the same.

- [ ] **Step 2: Inspect the existing build script, then register the service**

Run: `sed -n '1,60p' k8s/images/build.sh`
Read how `SERVICES` is declared and how each image is built (shared Dockerfile vs per-service). Then:
- If the script supports a per-service `Dockerfile` (i.e. it builds `docker build -f <service>/Dockerfile`), add `mock-paypal-service` to the `SERVICES` array.
- If it uses a single shared Dockerfile for all services, instead add an explicit block that builds this module with its own Dockerfile, e.g.:

```bash
# mock-paypal-service uses Java 24 — build with its own Dockerfile
docker build -t localhost:5001/mock-paypal-service:dev \
  -f mock-paypal-service/Dockerfile mock-paypal-service
docker push localhost:5001/mock-paypal-service:dev
```

- [ ] **Step 3: Build the image to verify**

Run: `docker build -t localhost:5001/mock-paypal-service:dev -f mock-paypal-service/Dockerfile mock-paypal-service`
Expected: image builds successfully.

- [ ] **Step 4: Commit**

```bash
git add mock-paypal-service/Dockerfile k8s/images/build.sh
git commit -m "build(mock-paypal): JDK 24 Dockerfile + image registration"
```

---

## Phase C — k8s deploy

### Task 10: k8s base manifests

**Files:**
- Create: `k8s/apps/base/mock-paypal-service/deployment.yaml`
- Create: `k8s/apps/base/mock-paypal-service/service.yaml`
- Create: `k8s/apps/base/mock-paypal-service/kustomization.yaml`

- [ ] **Step 1: Write `deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mock-paypal-service
  namespace: apps
  labels: { app: mock-paypal-service }
spec:
  replicas: 1
  selector:
    matchLabels: { app: mock-paypal-service }
  template:
    metadata:
      labels: { app: mock-paypal-service }
    spec:
      containers:
        - name: mock-paypal-service
          image: localhost:5001/mock-paypal-service:dev
          imagePullPolicy: IfNotPresent
          ports:
            - { name: http, containerPort: 8585 }
            - { name: management, containerPort: 18585 }
          env:
            - name: MOCK_PUBLIC_BASE_URL
              value: http://api.microecom.local/mock-paypal-service
            - name: JAVA_OPTS
              value: "-XX:MaxRAMPercentage=75.0"
          resources:
            requests: { cpu: 50m, memory: 256Mi }
            limits:   { cpu: 500m, memory: 384Mi }
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: management }
            initialDelaySeconds: 30
            periodSeconds: 15
            failureThreshold: 4
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: management }
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 6
```

> Single replica is intentional — per-token decision state is in-memory (see spec "State & scaling"). Do NOT add an HPA.

- [ ] **Step 2: Write `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mock-paypal-service
  namespace: apps
  labels: { app: mock-paypal-service }
spec:
  type: ClusterIP
  selector: { app: mock-paypal-service }
  ports:
    - { name: http, port: 8585, targetPort: http }
    - { name: management, port: 18585, targetPort: management }
```

- [ ] **Step 3: Write `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: apps
resources:
  - deployment.yaml
  - service.yaml
```

- [ ] **Step 4: Validate the kustomization builds**

Run: `kubectl kustomize k8s/apps/base/mock-paypal-service`
Expected: prints the rendered Deployment + Service YAML without error.

- [ ] **Step 5: Commit**

```bash
git add k8s/apps/base/mock-paypal-service
git commit -m "feat(k8s): mock-paypal-service base manifests"
```

---

### Task 11: Overlay wiring + gateway route + Vault

**Files:**
- Modify: `k8s/apps/overlays/local/kustomization.yaml`
- Modify: `gateway/src/main/resources/application.yml`
- Modify: `k8s/infra/jobs/03-vault-seed/seed.sh`

- [ ] **Step 1: Add the base + payment-service patch to the overlay**

Edit `k8s/apps/overlays/local/kustomization.yaml`. Add to `resources:` (after `bff-service`):

```yaml
  - ../../base/mock-paypal-service
```

Then add a `patches:` block at the end of the file to point payment-service at the mock (overrides Vault's base-url via `SPRING_APPLICATION_JSON`, which Spring merges with high precedence):

```yaml
patches:
  - target:
      kind: Deployment
      name: payment-service
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: SPRING_APPLICATION_JSON
          value: '{"application":{"paypal":{"base-url":"http://mock-paypal-service.apps.svc.cluster.local:8585/mock-paypal-service"}}}'
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: PAYPAL_TUNNEL_URL
          value: "http://api.microecom.local"
```

> `PAYPAL_TUNNEL_URL` = ingress host so the browser's post-approval redirect (`return_url`) and k6 (via hostAliases, Task 13) both reach `payment-service` through the gateway.

- [ ] **Step 2: Validate the overlay builds and applies the patch**

Run: `kubectl kustomize k8s/apps/overlays/local | grep -A2 SPRING_APPLICATION_JSON`
Expected: shows the injected env var on the payment-service container.

- [ ] **Step 3: Add the gateway route**

Edit `gateway/src/main/resources/application.yml`. In `spring.cloud.gateway.routes`, add (after the `bff-service` route):

```yaml
        - id: mock-paypal-service
          uri: ${gateway.routes.mock-paypal-service.uri:lb://MOCK-PAYPAL-SERVICE}
          predicates:
            - Path=/mock-paypal-service/**
```

> No `StripPrefix` — the mock's context-path is `/mock-paypal-service`, so the prefix lands naturally, consistent with every other route.

- [ ] **Step 4: Add Vault seed entries**

Edit `k8s/infra/jobs/03-vault-seed/seed.sh`:

(a) Add a new mock block near the other service blocks:

```sh
put_if_missing mock-paypal-service \
  server.port="8585" \
  mock.public-base-url="http://api.microecom.local/mock-paypal-service"
```

(b) In the **existing** `put_if_missing gateway ...` block, add this line (do NOT create a second gateway block):

```sh
  gateway.routes.mock-paypal-service.uri="http://mock-paypal-service.apps.svc.cluster.local:8585" \
```

- [ ] **Step 5: Commit**

```bash
git add k8s/apps/overlays/local/kustomization.yaml gateway/src/main/resources/application.yml k8s/infra/jobs/03-vault-seed/seed.sh
git commit -m "feat(k8s): wire mock-paypal into overlay, gateway route, vault seed"
```

---

## Phase D — Local dev (JVM process)

### Task 12: Register service locally + local Vault configs

**Files:**
- Modify: `scripts/services.list`
- Create: `docker/vault-configs/mock-paypal-service.json`
- Modify: `scripts/vault/import-secrets.sh` (only if it enumerates config files explicitly)
- Modify: `docker/vault-configs/payment-service.json`

- [ ] **Step 1: Register in `scripts/services.list`**

Add this line inside the `SERVICES=( ... )` array (tier 3, no gRPC):

```bash
  "mock-paypal-service   8585  -     3"
```

- [ ] **Step 2: Create `docker/vault-configs/mock-paypal-service.json`**

```json
{
  "server.port": "8585",
  "mock.public-base-url": "http://localhost:8585/mock-paypal-service"
}
```

- [ ] **Step 3: Ensure the import script loads it**

Run: `sed -n '1,80p' scripts/vault/import-secrets.sh`
- If the script loops over all `docker/vault-configs/*.json`, no change is needed.
- If it lists files explicitly, add `mock-paypal-service` to that list following the existing pattern.

- [ ] **Step 4: Add a commented toggle to `docker/vault-configs/payment-service.json`**

Leave the real PayPal value as the default, but document the mock override. Change the `application.paypal.base-url` line so the mock value is discoverable — keep real PayPal active by default:

```json
  "application.paypal.base-url": "https://api-m.sandbox.paypal.com",
  "_comment_mock_paypal": "To use the mock locally: set base-url to http://localhost:8585/mock-paypal-service and PAYPAL_TUNNEL_URL env to http://localhost:6868 (local gateway), then run: make vault-import && make svc-restart svc=payment-service",
```

> JSON has no comments, so this uses an extra `_comment_*` key, which Spring's Vault property source ignores harmlessly. Verify the local gateway port in `scripts/services.list` (currently `6868`) and use that for `PAYPAL_TUNNEL_URL`.

- [ ] **Step 5: Verify services.list drift guard passes and the service starts**

Run: `make build && make up MOCK_PAYPAL=ignored`
(The `MOCK_PAYPAL` var is unused locally — registration in `services.list` is what starts it. The flag exists only for the k8s/compose path; locally the service always starts once registered.)
Expected: `make status` lists `mock-paypal-service` as healthy on 8585. The drift guard does not error.

> Note: this supersedes the spec's "docker-compose behind a make flag" — per the chosen JVM-process approach, the mock is just another registered service. To run WITHOUT the mock, simply don't point payment-service's base-url at it.

- [ ] **Step 6: Commit**

```bash
git add scripts/services.list docker/vault-configs/mock-paypal-service.json docker/vault-configs/payment-service.json scripts/vault/import-secrets.sh
git commit -m "feat(local): register mock-paypal-service as JVM process + vault configs"
```

---

## Phase E — k6 stress driver

### Task 13: k6 full-flow drives decision mix + reachability

**Files:**
- Modify: `k6-tests/tests/full-flow.js`
- Modify: `k8s/apps/base/k6-stress/` job (add `hostAliases`) — locate the Job YAML first

- [ ] **Step 1: Read the current full-flow script's payment section**

Run: `sed -n '120,170p' k6-tests/tests/full-flow.js`
Confirm where it calls the approve link (the report noted lines ~148-155 already stub this).

- [ ] **Step 2: Replace the approve step to drive a decision mix**

In `k6-tests/tests/full-flow.js`, after the create-payment call returns the `links` array, replace the approve-link handling with:

```javascript
// Pick an outcome: 90% approve, 5% cancel, 5% fail
const roll = Math.random();
const decision = roll < 0.90 ? 'approve' : (roll < 0.95 ? 'cancel' : 'fail');

// approveLink.href already points at the mock checkout page
const sep = approveLink.href.includes('?') ? '&' : '?';
const driveUrl = `${approveLink.href}${sep}decision=${decision}`;

// Follow the redirect chain into payment-service's callback
const res = http.get(driveUrl, { redirects: 5 });
check(res, {
  'payment callback reached': (r) => r.status === 200 || r.status === 302,
});
```

- [ ] **Step 3: Add `hostAliases` so the in-cluster k6 Job can resolve the ingress host**

Locate the k6 Job: `ls k8s/apps/base/k6-stress/` and open the Job YAML. Under `spec.template.spec`, add (resolve the ingress-nginx controller ClusterIP first with `kubectl -n ingress-nginx get svc`):

```yaml
      hostAliases:
        - ip: "<INGRESS_NGINX_CONTROLLER_CLUSTER_IP>"
          hostnames:
            - "api.microecom.local"
```

> Alternative if you prefer not to hardcode the IP: point k6's `BASE_URL` at the ingress controller Service DNS and send a `Host: api.microecom.local` header on each request. Pick one; `hostAliases` keeps the script's URLs identical to the browser's.

- [ ] **Step 4: Smoke-run k6 against a running stack**

Run: `k6 run k6-tests/tests/full-flow.js` (point its BASE_URL at the gateway with the mock active)
Expected: checks pass; order statuses transition to COMPLETED/CANCELED/FAILED in roughly the 90/5/5 mix. No PayPal sandbox calls occur.

- [ ] **Step 5: Commit**

```bash
git add k6-tests/tests/full-flow.js k8s/apps/base/k6-stress
git commit -m "test(k6): drive mock-paypal decision mix + ingress hostAliases"
```

---

## Phase F — Docs

### Task 14: Document the mock in CLAUDE.md + a module README

**Files:**
- Create: `mock-paypal-service/README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write `mock-paypal-service/README.md`**

```markdown
# mock-paypal-service

A drop-in mock of PayPal's REST API for stress testing (k6) and local frontend
dev. Java 24 + virtual threads, single replica, in-memory per-token state.

## How it works
- Implements the 5 PayPal endpoints `core-paypal` calls + a `/checkout` page.
- Switch is config-only: point `application.paypal.base-url` at this service
  (with the `/mock-paypal-service` context-path suffix).
- Decision (approve/cancel/fail) is chosen at `/checkout` and remembered per
  token; `fail` makes the capture endpoint return 422 → `PaymentFailed`.

## Endpoints
| Method | Path | Purpose |
|---|---|---|
| POST | /v1/oauth2/token | mock OAuth token |
| POST | /v2/checkout/orders | create order, returns approve link |
| GET  | /checkout?token=&decision= | approve page / decision redirect |
| POST | /v2/checkout/orders/{token}/capture | COMPLETED, or 422 if decision=fail |
| GET  | /v2/checkout/orders/{token} | order details (custom_id, capture id) |
| POST | /v2/payments/captures/{id}/refund | mock refund |

## k6
Append `?decision=approve|cancel|fail` to the approve link to drive an outcome.

## Run locally
Registered in `scripts/services.list`; starts with `make up` on port 8585.
Point payment-service at it via `docker/vault-configs/payment-service.json`.
```

- [ ] **Step 2: Add a short note to `CLAUDE.md`**

Under the "Security & Communication" or a new "Testing" subsection, add:

```markdown
### Mock PayPal (stress test / local dev)
`mock-paypal-service` (Java 24, port 8585) mocks PayPal's REST API so k6 and
local frontend can run the full payment flow without real PayPal. Switch is
config-only: set `application.paypal.base-url` to
`http://<host>:8585/mock-paypal-service`. Decision (approve/cancel/fail) is
chosen at the `/checkout` page (browser) or via `?decision=` (k6); `fail`
returns 422 from capture to trigger `PaymentFailed`. Single replica by design
(in-memory per-token state). See `mock-paypal-service/README.md`.
```

- [ ] **Step 3: Commit**

```bash
git add mock-paypal-service/README.md CLAUDE.md
git commit -m "docs(mock-paypal): module README + CLAUDE.md note"
```

---

## Manual end-to-end verification (after all tasks)

- [ ] **Local browser flow:** `make up`, set payment-service base-url to the mock, place an order in the frontend → lands on the mock checkout page → click Approve → returns to frontend `/payment/success` with order COMPLETED. Repeat with Cancel and Fail.
- [ ] **k6 flow:** run `full-flow.js` against the gateway with the mock active → checks green, outcome mix ~90/5/5, zero PayPal sandbox traffic.
- [ ] **Event check:** tail orchestrator/order logs and confirm `PaymentSuccess`, `PaymentCanceled`, and `PaymentFailed` all appear under the k6 run.

---

## Self-Review notes (author)

- **Spec coverage:** all 6 mock endpoints (Tasks 4–8), decision state machine (Tasks 2,6,7), k8s deploy + gateway route + Vault (Tasks 10–11), local JVM wiring (Task 12), k6 driver + reachability (Task 13), tests throughout, docs (Task 14). The spec's "local docker-compose behind a make flag" is intentionally superseded by the JVM-process approach (user decision) — noted in Task 12.
- **Fail trigger** verified against `RestTemplateErrorHandler` (any 4xx/5xx → `PaypalRestTemplateException`); 422 chosen.
- **JSON casing** matches `core-paypal`'s `SnakeCaseStrategy` on every DTO; `RefundResponse.amount` is a primitive `double` to match.
- **Type consistency:** `OrderStore.create/get/setDecision/setCapture`, `Decision.{PENDING,APPROVE,CANCEL,FAIL}`, `PurchaseUnitView.{Amount,Payments,Capture}` referenced identically across Tasks 2–7.
- **Open risk:** exact Spring Boot 3.5.x patch / JDK 24 Docker tag availability — Tasks 1 & 9 include fallbacks.
```
