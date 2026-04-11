# BFF Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a `bff-service` (Backend for Frontend) that aggregates data from multiple microservices into UI-optimized responses for each MFE, eliminating the need for microfrontend shells to make multiple parallel API calls.

**Architecture:** New Spring Boot service registered with Eureka, routed through the gateway. Calls product-service via OpenFeign (REST) and inventory-service via gRPC (reusing the existing `inventory_service.proto` contract from `grpc-common`). Three aggregate endpoints: product detail + stock, order detail (via Feign to order-service), cart items enriched with current stock. Secrets pulled from Vault like all other services.

**Tech Stack:** Java 17, Spring Boot 3.3.6, Spring Cloud OpenFeign, gRPC (grpc-netty-shaded), Eureka client, Vault config, Lombok

**Prerequisite:** Plan 1 (order read API) must be completed before the order-detail BFF endpoint works.

---

## File Map

| Action | File |
|--------|------|
| Create | `bff-service/pom.xml` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/BffServiceApplication.java` |
| Create | `bff-service/src/main/resources/bootstrap.yml` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/ProductFeignClient.java` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/OrderFeignClient.java` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/InventoryGrpcClientService.java` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/GrpcClientConfig.java` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/FeignClientConfig.java` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/ProductDetailBffResponse.java` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/OrderDetailBffResponse.java` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/controller/BffController.java` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/BffService.java` |
| Create | `bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/impl/BffServiceImpl.java` |
| Modify | `docker/vault-configs/bff-service.json` (new Vault config file) |
| Modify | `gateway/src/main/resources/application.yml` (add BFF route) |

---

## Task 1: Create pom.xml and main application class

**Files:**
- Create: `bff-service/pom.xml`
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/BffServiceApplication.java`

- [ ] **Step 1: Create pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>3.3.6</version>
        <relativePath/>
    </parent>

    <groupId>org.aibles.ecommerce</groupId>
    <artifactId>bff-service</artifactId>
    <version>0.0.1</version>
    <packaging>jar</packaging>

    <properties>
        <java.version>17</java.version>
        <spring-cloud.version>2023.0.3</spring-cloud.version>
        <grpc.version>1.62.2</grpc.version>
    </properties>

    <dependencyManagement>
        <dependencies>
            <dependency>
                <groupId>org.springframework.cloud</groupId>
                <artifactId>spring-cloud-dependencies</artifactId>
                <version>${spring-cloud.version}</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>
        </dependencies>
    </dependencyManagement>

    <dependencies>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.cloud</groupId>
            <artifactId>spring-cloud-starter-netflix-eureka-client</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.cloud</groupId>
            <artifactId>spring-cloud-starter-vault-config</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.cloud</groupId>
            <artifactId>spring-cloud-starter-openfeign</artifactId>
        </dependency>
        <dependency>
            <groupId>io.grpc</groupId>
            <artifactId>grpc-netty-shaded</artifactId>
            <version>${grpc.version}</version>
        </dependency>
        <dependency>
            <groupId>org.aibles.ecommerce</groupId>
            <artifactId>grpc-common</artifactId>
            <version>0.0.1</version>
        </dependency>
        <dependency>
            <groupId>org.aibles.ecommerce</groupId>
            <artifactId>common-dto</artifactId>
            <version>0.0.1</version>
        </dependency>
        <dependency>
            <groupId>org.aibles.ecommerce</groupId>
            <artifactId>core-exception-api</artifactId>
            <version>0.0.1</version>
        </dependency>
        <dependency>
            <groupId>org.springdoc</groupId>
            <artifactId>springdoc-openapi-starter-webmvc-ui</artifactId>
            <version>2.6.0</version>
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
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Create directory structure**

```bash
mkdir -p bff-service/src/main/java/org/aibles/ecommerce/bff_service/{client,configuration,controller,dto,service/impl}
mkdir -p bff-service/src/main/resources
mkdir -p bff-service/src/test/java/org/aibles/ecommerce/bff_service
```

- [ ] **Step 3: Create BffServiceApplication**

```java
package org.aibles.ecommerce.bff_service;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.openfeign.EnableFeignClients;

@SpringBootApplication
@EnableFeignClients
public class BffServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(BffServiceApplication.class, args);
    }
}
```

- [ ] **Step 4: Create application.yml** (follow the exact pattern of product-service's application.yml)

```yaml
spring:
  application:
    name: bff-service
  cloud:
    vault:
      uri: http://localhost:8200
      token: ${VAULT_TOKEN}
      fail-fast: true
      kv:
        enabled: true
        backend: secret
        default-context: ecommerce
        application-name: bff-service
  config:
    import: optional:vault://
server:
  servlet:
    context-path: /bff-service
```

> `server.servlet.context-path: /bff-service` is what makes the gateway route work without `StripPrefix`. The gateway forwards `/bff-service/**` → bff-service, and the context path strips the `/bff-service` prefix so the controller sees bare paths.

- [ ] **Step 5: Commit scaffold**

```bash
git add bff-service/
git commit -m "feat(bff-service): scaffold new BFF service with pom.xml and application class"
```

---

## Task 2: Create Vault config and gateway route

**Files:**
- Create: `docker/vault-configs/bff-service.json`
- Modify: `gateway/src/main/resources/application.yml`

- [ ] **Step 1: Create Vault config file for BFF**

```bash
# First check what an existing service's vault config looks like
cat docker/vault-configs/orchestrator-service.json
```

Then create `docker/vault-configs/bff-service.json` with at minimum:

```json
{
  "server.port": 8087,
  "eureka.client.service-url.defaultZone": "http://localhost:8761/eureka/",
  "eureka.instance.prefer-ip-address": true,
  "inventory.grpc.host": "localhost",
  "inventory.grpc.port": 9090
}
```

> Port 8087 — check existing services to confirm it's unused. Adjust if needed.

- [ ] **Step 2: Load the config into Vault**

```bash
# With Vault running and unsealed:
docker exec -it vault vault kv put secret/bff-service \
  "server.port=8087" \
  "eureka.client.service-url.defaultZone=http://localhost:8761/eureka/" \
  "eureka.instance.prefer-ip-address=true" \
  "inventory.grpc.host=localhost" \
  "inventory.grpc.port=9090"
```

- [ ] **Step 3: Add BFF route to gateway**

Open `gateway/src/main/resources/application.yml` and add a route entry after the last existing route (before the `vault:` section):

```yaml
        - id: bff-service
          uri: lb://BFF-SERVICE
          predicates:
            - Path=/bff-service/**
```

> No `StripPrefix` needed — the same pattern as all other services. `lb://BFF-SERVICE` is uppercase because Eureka registers service names in uppercase by default. The service's `server.servlet.context-path: /bff-service` strips the prefix on the service side.

Also add BFF to the Swagger aggregation in the same file:

```yaml
      - name: bff-service
        url: /bff-service/v3/api-docs
```

- [ ] **Step 4: Commit**

```bash
git add docker/vault-configs/bff-service.json gateway/src/main/resources/application.yml
git commit -m "feat(bff-service): add Vault config and gateway route for bff-service"
```

---

## Task 3: Create gRPC client for inventory-service

**Files:**
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/GrpcClientConfig.java`
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/InventoryGrpcClientService.java`

- [ ] **Step 1: Create GrpcClientConfig** (same pattern as order-service's GrpcClientConfig)

```java
package org.aibles.ecommerce.bff_service.configuration;

import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.inventory.grpc.InventoryServiceGrpc;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class GrpcClientConfig {

    @Value("${inventory.grpc.host}")
    private String grpcHost;

    @Value("${inventory.grpc.port}")
    private int grpcPort;

    @Bean
    public ManagedChannel managedChannel() {
        return ManagedChannelBuilder.forAddress(grpcHost, grpcPort)
                .usePlaintext()
                .build();
    }

    @Bean
    public InventoryServiceGrpc.InventoryServiceBlockingStub inventoryStub(ManagedChannel channel) {
        return InventoryServiceGrpc.newBlockingStub(channel);
    }

    @Bean
    public InventoryGrpcClientService inventoryGrpcClientService(
            InventoryServiceGrpc.InventoryServiceBlockingStub stub) {
        return new InventoryGrpcClientService(stub);
    }
}
```

- [ ] **Step 2: Create InventoryGrpcClientService**

```java
package org.aibles.ecommerce.bff_service.client;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsRequest;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryServiceGrpc;

import java.util.List;

@Slf4j
public class InventoryGrpcClientService {

    private final InventoryServiceGrpc.InventoryServiceBlockingStub stub;

    public InventoryGrpcClientService(InventoryServiceGrpc.InventoryServiceBlockingStub stub) {
        this.stub = stub;
    }

    public InventoryProductIdsResponse fetchInventory(List<String> productIds) {
        log.info("(fetchInventory) productIds: {}", productIds);
        InventoryProductIdsRequest request = InventoryProductIdsRequest.newBuilder()
                .addAllIds(productIds)
                .build();
        return stub.listInventoryProducts(request);
    }
}
```

- [ ] **Step 3: Compile**

```bash
cd bff-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
git add bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/InventoryGrpcClientService.java \
        bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/GrpcClientConfig.java
git commit -m "feat(bff-service): add gRPC client for inventory-service"
```

---

## Task 4: Create Feign clients for product-service and order-service

**Files:**
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/ProductFeignClient.java`
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/OrderFeignClient.java`
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/FeignClientConfig.java`

- [ ] **Step 1: Create FeignClientConfig** (forwards X-User-Id header)

```java
package org.aibles.ecommerce.bff_service.configuration;

import feign.RequestInterceptor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

@Configuration
public class FeignClientConfig {

    @Bean
    public RequestInterceptor userIdHeaderInterceptor() {
        return template -> {
            var attrs = (ServletRequestAttributes) RequestContextHolder.getRequestAttributes();
            if (attrs != null) {
                String userId = attrs.getRequest().getHeader("X-User-Id");
                if (userId != null) {
                    template.header("X-User-Id", userId);
                }
            }
        };
    }
}
```

> This interceptor automatically forwards the `X-User-Id` header from the incoming BFF request to downstream Feign calls. Without it, order-service and order-cart calls would fail (they require that header).

- [ ] **Step 2: Create ProductFeignClient**

```java
package org.aibles.ecommerce.bff_service.client;

import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;

@FeignClient(name = "product-service")
public interface ProductFeignClient {

    @GetMapping("/v1/products/{id}")
    BaseResponse getById(@PathVariable("id") String id);
}
```

- [ ] **Step 3: Create OrderFeignClient**

```java
package org.aibles.ecommerce.bff_service.client;

import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestHeader;

@FeignClient(name = "order-service")
public interface OrderFeignClient {

    @GetMapping("/v1/orders/{orderId}")
    BaseResponse getOrder(@RequestHeader("X-User-Id") String userId,
                          @PathVariable("orderId") String orderId);

    @GetMapping("/v1/shopping-carts")
    BaseResponse getCart(@RequestHeader("X-User-Id") String userId);
}
```

- [ ] **Step 4: Compile**

```bash
cd bff-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add bff-service/src/main/java/org/aibles/ecommerce/bff_service/client/ \
        bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/FeignClientConfig.java
git commit -m "feat(bff-service): add Feign clients for product-service and order-service"
```

---

## Task 5: Create aggregate response DTOs

**Files:**
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/ProductDetailBffResponse.java`
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/OrderDetailBffResponse.java`

- [ ] **Step 1: Create ProductDetailBffResponse**

```java
package org.aibles.ecommerce.bff_service.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.util.Map;

@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class ProductDetailBffResponse {

    private String id;
    private String name;
    private Double price;
    private String category;
    private Map<String, Object> attributes;
    private long stockQuantity;      // from inventory gRPC
    private boolean inStock;         // stockQuantity > 0
}
```

- [ ] **Step 2: Create OrderDetailBffResponse**

```java
package org.aibles.ecommerce.bff_service.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.util.Map;

@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class OrderDetailBffResponse {

    private Object order;     // passthrough from order-service (OrderDetailResponse)
    private Object payment;   // reserved for future payment enrichment (null for now)
}
```

> `OrderDetailBffResponse.order` is typed as `Object` to avoid duplicating the order-service DTO structure. The BFF simply passes through the order-service response and adds any extra data alongside it. This keeps the BFF thin.

- [ ] **Step 3: Compile**

```bash
cd bff-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
git add bff-service/src/main/java/org/aibles/ecommerce/bff_service/dto/
git commit -m "feat(bff-service): add aggregate response DTOs"
```

---

## Task 6: Implement BffService and BffController

**Files:**
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/BffService.java`
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/service/impl/BffServiceImpl.java`
- Create: `bff-service/src/main/java/org/aibles/ecommerce/bff_service/controller/BffController.java`

- [ ] **Step 1: Create BffService interface**

```java
package org.aibles.ecommerce.bff_service.service;

import org.aibles.ecommerce.bff_service.dto.ProductDetailBffResponse;
import org.aibles.ecommerce.bff_service.dto.OrderDetailBffResponse;

public interface BffService {

    ProductDetailBffResponse getProductDetail(String productId);

    OrderDetailBffResponse getOrderDetail(String userId, String orderId);
}
```

- [ ] **Step 2: Implement BffServiceImpl**

```java
package org.aibles.ecommerce.bff_service.service.impl;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.dto.OrderDetailBffResponse;
import org.aibles.ecommerce.bff_service.dto.ProductDetailBffResponse;
import org.aibles.ecommerce.bff_service.service.BffService;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryProduct;
import org.aibles.ecommerce.inventory.grpc.InventoryProductIdsResponse;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@Slf4j
public class BffServiceImpl implements BffService {

    private final ProductFeignClient productFeignClient;
    private final OrderFeignClient orderFeignClient;
    private final InventoryGrpcClientService inventoryGrpcClientService;
    private final ObjectMapper objectMapper;

    public BffServiceImpl(ProductFeignClient productFeignClient,
                          OrderFeignClient orderFeignClient,
                          InventoryGrpcClientService inventoryGrpcClientService,
                          ObjectMapper objectMapper) {
        this.productFeignClient = productFeignClient;
        this.orderFeignClient = orderFeignClient;
        this.inventoryGrpcClientService = inventoryGrpcClientService;
        this.objectMapper = objectMapper;
    }

    @Override
    public ProductDetailBffResponse getProductDetail(String productId) {
        log.info("(getProductDetail) productId: {}", productId);

        // Fetch product from product-service
        BaseResponse productResponse = productFeignClient.getById(productId);
        Map<String, Object> productData = (Map<String, Object>) productResponse.getData();

        // Fetch stock from inventory-service via gRPC
        InventoryProductIdsResponse inventoryResponse =
                inventoryGrpcClientService.fetchInventory(List.of(productId));

        long stockQuantity = 0L;
        if (!inventoryResponse.getInventoryProductsList().isEmpty()) {
            InventoryProduct inv = inventoryResponse.getInventoryProductsList().get(0);
            stockQuantity = inv.getQuantity();
        }

        return ProductDetailBffResponse.builder()
                .id((String) productData.get("id"))
                .name((String) productData.get("name"))
                .price(productData.get("price") != null ?
                        ((Number) productData.get("price")).doubleValue() : null)
                .category((String) productData.get("category"))
                .attributes((Map<String, Object>) productData.get("attributes"))
                .stockQuantity(stockQuantity)
                .inStock(stockQuantity > 0)
                .build();
    }

    @Override
    public OrderDetailBffResponse getOrderDetail(String userId, String orderId) {
        log.info("(getOrderDetail) userId: {}, orderId: {}", userId, orderId);
        BaseResponse orderResponse = orderFeignClient.getOrder(userId, orderId);
        return OrderDetailBffResponse.builder()
                .order(orderResponse.getData())
                .payment(null)
                .build();
    }
}
```

- [ ] **Step 3: Create BffController**

```java
package org.aibles.ecommerce.bff_service.controller;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.bff_service.service.BffService;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@Slf4j
@RestController
public class BffController {

    private final BffService bffService;

    public BffController(BffService bffService) {
        this.bffService = bffService;
    }

    @GetMapping("/v1/products/{productId}")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse getProductDetail(@PathVariable String productId) {
        log.info("(getProductDetail) productId: {}", productId);
        return BaseResponse.ok(bffService.getProductDetail(productId));
    }

    @GetMapping("/v1/orders/{orderId}")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse getOrderDetail(@RequestHeader("X-User-Id") String userId,
                                       @PathVariable String orderId) {
        log.info("(getOrderDetail) userId: {}, orderId: {}", userId, orderId);
        return BaseResponse.ok(bffService.getOrderDetail(userId, orderId));
    }
}
```

> No `@RequestMapping` at the class level. The full path is `/bff-service/v1/products/{productId}` — the `server.servlet.context-path: /bff-service` prefix is handled by Spring Boot, matching the gateway route `/bff-service/**`.

- [ ] **Step 4: Register BffServiceImpl as a Spring bean**

Create `bff-service/src/main/java/org/aibles/ecommerce/bff_service/configuration/BffServiceConfiguration.java`:

```java
package org.aibles.ecommerce.bff_service.configuration;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.service.BffService;
import org.aibles.ecommerce.bff_service.service.impl.BffServiceImpl;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class BffServiceConfiguration {

    @Bean
    public BffService bffService(ProductFeignClient productFeignClient,
                                  OrderFeignClient orderFeignClient,
                                  InventoryGrpcClientService inventoryGrpcClientService,
                                  ObjectMapper objectMapper) {
        return new BffServiceImpl(productFeignClient, orderFeignClient,
                inventoryGrpcClientService, objectMapper);
    }
}
```

- [ ] **Step 5: Compile**

```bash
cd bff-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 6: Run all tests**

```bash
cd bff-service && mvn test -q
```
Expected: Context loads test PASS

- [ ] **Step 7: Commit**

```bash
git add bff-service/src/main/java/org/aibles/ecommerce/bff_service/
git commit -m "feat(bff-service): implement BffService and BffController with product+inventory aggregation"
```

---

## Task 7: Register bff-service in root pom.xml

**Files:**
- Modify: `pom.xml` (root, if it exists as a multi-module parent)

- [ ] **Step 1: Check if there is a root pom.xml with modules**

```bash
cat pom.xml 2>/dev/null | grep -A20 "<modules>"
```

If a root pom.xml exists with `<modules>`, add `<module>bff-service</module>` to the list.

If no root pom.xml exists (each service is standalone), skip this task.

- [ ] **Step 2: If added, verify build**

```bash
mvn compile -pl bff-service -am -q
```
Expected: BUILD SUCCESS

- [ ] **Step 3: Commit if changed**

```bash
git add pom.xml
git commit -m "feat: register bff-service in root pom.xml"
```

---

## Verification

- [ ] Start bff-service: `cd bff-service && mvn spring-boot:run`
- [ ] Confirm it registers in Eureka dashboard at `http://localhost:8761`
- [ ] `GET http://localhost:6868/bff-service/v1/products/{productId}` — confirm response includes `stock_quantity` and `in_stock` alongside product data
- [ ] `GET http://localhost:6868/bff-service/v1/orders/{orderId}` with `X-User-Id` header — confirm order detail is returned
- [ ] Confirm product with stock=0 returns `"in_stock": false`
- [ ] Confirm unauthorized order access (wrong userId) returns 404
