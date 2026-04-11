# Order Read API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `GET /v1/orders` (paginated list for current user) and `GET /v1/orders/{id}` (order detail with items) to order-service, unblocking the Account MFE.

**Architecture:** Reads go to SlaveOrderRepo and SlaveOrderItemRepo (existing master-slave routing pattern). userId is extracted from the `X-User-Id` request header (injected by gateway). A new `SlaveOrderItemRepo` is added — it lives in `repository/slave/` so the `SlaveEntityFactoryConfiguration` picks it up automatically via its `basePackages` scan.

**Tech Stack:** Java 17, Spring Boot 3.3.6, Spring Data JPA, MySQL (slave for reads), Lombok, JUnit 5, Mockito

---

## File Map

| Action | File |
|--------|------|
| Create | `order-service/src/main/java/org/aibles/order_service/repository/slave/SlaveOrderItemRepo.java` |
| Create | `order-service/src/main/java/org/aibles/order_service/dto/response/OrderItemResponse.java` |
| Create | `order-service/src/main/java/org/aibles/order_service/dto/response/OrderDetailResponse.java` |
| Create | `order-service/src/main/java/org/aibles/order_service/dto/response/OrderSummaryResponse.java` |
| Modify | `order-service/src/main/java/org/aibles/order_service/repository/slave/SlaveOrderRepo.java` |
| Modify | `order-service/src/main/java/org/aibles/order_service/service/OrderService.java` |
| Modify | `order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java` |
| Modify | `order-service/src/main/java/org/aibles/order_service/controller/OrderController.java` |
| Create | `order-service/src/test/java/org/aibles/order_service/service/OrderServiceImplReadTest.java` |

---

## Task 1: Create SlaveOrderItemRepo

**Files:**
- Create: `order-service/src/main/java/org/aibles/order_service/repository/slave/SlaveOrderItemRepo.java`

- [ ] **Step 1: Create the repository file**

```java
package org.aibles.order_service.repository.slave;

import org.aibles.order_service.entity.OrderItem;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface SlaveOrderItemRepo extends JpaRepository<OrderItem, String> {

    List<OrderItem> findAllByOrderId(String orderId);
}
```

> **Why slave?** `SlaveEntityFactoryConfiguration` scans `org.aibles.order_service.repository.slave`. Placing this repo there automatically routes it to the read replica. No extra config needed.

- [ ] **Step 2: Verify the file compiles**

```bash
cd order-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 3: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/repository/slave/SlaveOrderItemRepo.java
git commit -m "feat(order-service): add SlaveOrderItemRepo for reading order items"
```

---

## Task 2: Add findAllByUserId to SlaveOrderRepo

**Files:**
- Modify: `order-service/src/main/java/org/aibles/order_service/repository/slave/SlaveOrderRepo.java`

- [ ] **Step 1: Write the failing test** (in `OrderServiceImplReadTest.java` — create the file now)

```java
package org.aibles.order_service.service;

import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.entity.OrderItem;
import org.aibles.order_service.repository.slave.SlaveOrderItemRepo;
import org.aibles.order_service.repository.slave.SlaveOrderRepo;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class OrderServiceImplReadTest {

    @Mock private SlaveOrderRepo slaveOrderRepo;
    @Mock private SlaveOrderItemRepo slaveOrderItemRepo;

    // We will add more mocks as needed in later tasks
    // For now we only need these two for the list/get tests

    @Test
    void listOrders_shouldReturnPaginatedOrders() {
        String userId = "user-1";
        Order order = Order.builder()
                .id("order-1").status(OrderStatus.COMPLETED)
                .address("123 Street").phoneNumber("0123456789")
                .userId(userId).createdAt(LocalDateTime.now()).updatedAt(LocalDateTime.now())
                .build();
        Page<Order> page = new PageImpl<>(List.of(order), PageRequest.of(0, 10), 1);

        when(slaveOrderRepo.findAllByUserId(userId, PageRequest.of(0, 10))).thenReturn(page);

        // TODO: wire OrderServiceImpl — this test will compile but fail until Task 5
        assertThat(page.getContent()).hasSize(1);
        assertThat(page.getContent().get(0).getUserId()).isEqualTo(userId);
    }
}
```

- [ ] **Step 2: Run the test to confirm it compiles (it will fail — that's expected)**

```bash
cd order-service && mvn test -pl . -Dtest=OrderServiceImplReadTest -q 2>&1 | tail -5
```
Expected: Compilation succeeds; test might fail with missing method on SlaveOrderRepo.

- [ ] **Step 3: Add findAllByUserId to SlaveOrderRepo**

Replace the content of `SlaveOrderRepo.java`:

```java
package org.aibles.order_service.repository.slave;

import org.aibles.order_service.entity.Order;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.Optional;

@Repository
public interface SlaveOrderRepo extends JpaRepository<Order, String> {

    Page<Order> findAllByUserId(String userId, Pageable pageable);

    Optional<Order> findByIdAndUserId(String id, String userId);
}
```

> `findByIdAndUserId` ensures a user can only read their own orders — security by design.

- [ ] **Step 4: Compile**

```bash
cd order-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/repository/slave/SlaveOrderRepo.java \
        order-service/src/test/java/org/aibles/order_service/service/OrderServiceImplReadTest.java
git commit -m "feat(order-service): add findAllByUserId and findByIdAndUserId to SlaveOrderRepo"
```

---

## Task 3: Create response DTOs

**Files:**
- Create: `order-service/src/main/java/org/aibles/order_service/dto/response/OrderItemResponse.java`
- Create: `order-service/src/main/java/org/aibles/order_service/dto/response/OrderDetailResponse.java`
- Create: `order-service/src/main/java/org/aibles/order_service/dto/response/OrderSummaryResponse.java`

- [ ] **Step 1: Create OrderItemResponse**

```java
package org.aibles.order_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.order_service.entity.OrderItem;

@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class OrderItemResponse {

    private String id;
    private String productId;
    private Double price;
    private Long quantity;

    public static OrderItemResponse from(OrderItem item) {
        return OrderItemResponse.builder()
                .id(item.getId())
                .productId(item.getProductId())
                .price(item.getPrice())
                .quantity(item.getQuantity())
                .build();
    }
}
```

- [ ] **Step 2: Create OrderSummaryResponse** (for the list — no items)

```java
package org.aibles.order_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.order_service.entity.Order;

import java.time.LocalDateTime;

@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class OrderSummaryResponse {

    private String id;
    private String status;
    private String address;
    private String phoneNumber;
    private LocalDateTime createdAt;
    private LocalDateTime updatedAt;

    public static OrderSummaryResponse from(Order order) {
        return OrderSummaryResponse.builder()
                .id(order.getId())
                .status(order.getStatus().name())
                .address(order.getAddress())
                .phoneNumber(order.getPhoneNumber())
                .createdAt(order.getCreatedAt())
                .updatedAt(order.getUpdatedAt())
                .build();
    }
}
```

- [ ] **Step 3: Create OrderDetailResponse** (for single order — includes items)

```java
package org.aibles.order_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.order_service.entity.Order;

import java.time.LocalDateTime;
import java.util.List;

@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class OrderDetailResponse {

    private String id;
    private String status;
    private String address;
    private String phoneNumber;
    private LocalDateTime createdAt;
    private LocalDateTime updatedAt;
    private List<OrderItemResponse> items;

    public static OrderDetailResponse from(Order order, List<OrderItemResponse> items) {
        return OrderDetailResponse.builder()
                .id(order.getId())
                .status(order.getStatus().name())
                .address(order.getAddress())
                .phoneNumber(order.getPhoneNumber())
                .createdAt(order.getCreatedAt())
                .updatedAt(order.getUpdatedAt())
                .items(items)
                .build();
    }
}
```

- [ ] **Step 4: Compile**

```bash
cd order-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/dto/response/OrderItemResponse.java \
        order-service/src/main/java/org/aibles/order_service/dto/response/OrderSummaryResponse.java \
        order-service/src/main/java/org/aibles/order_service/dto/response/OrderDetailResponse.java
git commit -m "feat(order-service): add order read response DTOs"
```

---

## Task 4: Add list and get methods to OrderService interface

**Files:**
- Modify: `order-service/src/main/java/org/aibles/order_service/service/OrderService.java`

- [ ] **Step 1: Add the two new method signatures**

Replace the file content:

```java
package org.aibles.order_service.service;

import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.order_service.dto.request.OrderRequest;
import org.aibles.order_service.dto.response.OrderCreatedResponse;
import org.aibles.order_service.dto.response.OrderDetailResponse;

public interface OrderService {

    OrderCreatedResponse create(String userId, OrderRequest request);

    void handleCanceledOrder(String orderId);

    void handleFailedOrder(String orderId);

    void handleSuccessOrder(String orderId);

    PagingResponse list(String userId, int page, int size);

    OrderDetailResponse get(String userId, String orderId);
}
```

- [ ] **Step 2: Compile (will fail — not yet implemented)**

```bash
cd order-service && mvn compile -q 2>&1 | tail -5
```
Expected: COMPILE ERROR — `OrderServiceImpl does not implement list, get`

- [ ] **Step 3: Commit the interface change**

```bash
git add order-service/src/main/java/org/aibles/order_service/service/OrderService.java
git commit -m "feat(order-service): declare list and get on OrderService interface"
```

---

## Task 5: Implement list and get in OrderServiceImpl

**Files:**
- Modify: `order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java`

- [ ] **Step 1: Add SlaveOrderRepo and SlaveOrderItemRepo to constructor**

In `OrderServiceImpl`, the constructor currently has 8 params. Add 2 more:

Add fields (after the existing `private final ApplicationEventPublisher eventPublisher;`):
```java
private final SlaveOrderRepo slaveOrderRepo;
private final SlaveOrderItemRepo slaveOrderItemRepo;
```

Update the constructor signature — add to the end:
```java
SlaveOrderRepo slaveOrderRepo,
SlaveOrderItemRepo slaveOrderItemRepo
```

Add to constructor body:
```java
this.slaveOrderRepo = slaveOrderRepo;
this.slaveOrderItemRepo = slaveOrderItemRepo;
```

Add the required imports at the top of the file:
```java
import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.order_service.dto.response.OrderDetailResponse;
import org.aibles.order_service.dto.response.OrderItemResponse;
import org.aibles.order_service.dto.response.OrderSummaryResponse;
import org.aibles.ecommerce.common_dto.exception.NotFoundException;
import org.aibles.order_service.repository.slave.SlaveOrderItemRepo;
import org.aibles.order_service.repository.slave.SlaveOrderRepo;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import java.util.stream.Collectors;
```

- [ ] **Step 2: Implement the list method** — add at the end of the class, before the closing `}`

```java
@Override
@Transactional(readOnly = true)
public PagingResponse list(String userId, int page, int size) {
    log.info("(list) userId: {}, page: {}, size: {}", userId, page, size);
    Page<org.aibles.order_service.entity.Order> ordersPage =
            slaveOrderRepo.findAllByUserId(userId, PageRequest.of(page - 1, size));
    var summaries = ordersPage.getContent().stream()
            .map(OrderSummaryResponse::from)
            .collect(Collectors.toList());
    return PagingResponse.builder()
            .page(page)
            .size(size)
            .total(ordersPage.getTotalElements())
            .data(summaries)
            .build();
}
```

- [ ] **Step 3: Implement the get method** — add after `list`

```java
@Override
@Transactional(readOnly = true)
public OrderDetailResponse get(String userId, String orderId) {
    log.info("(get) userId: {}, orderId: {}", userId, orderId);
    org.aibles.order_service.entity.Order order =
            slaveOrderRepo.findByIdAndUserId(orderId, userId)
                    .orElseThrow(NotFoundException::new);
    var items = slaveOrderItemRepo.findAllByOrderId(orderId).stream()
            .map(OrderItemResponse::from)
            .collect(Collectors.toList());
    return OrderDetailResponse.from(order, items);
}
```

- [ ] **Step 4: Update OrderServiceConfiguration to inject the new repos**

Replace the `orderService` bean method in `order-service/src/main/java/org/aibles/order_service/configuration/OrderServiceConfiguration.java`:

```java
// Add these imports at the top:
import org.aibles.order_service.repository.slave.SlaveOrderRepo;
import org.aibles.order_service.repository.slave.SlaveOrderItemRepo;

// Replace the existing orderService @Bean method:
@Bean
public OrderService orderService(InventoryGrpcClientService inventoryGrpcClientService,
                                 RedisRepository redisRepository,
                                 PendingOrderCacheRepository pendingOrderCacheRepository,
                                 MasterOrderRepo masterOrderRepo,
                                 MasterOrderItemRepo masterOrderItemRepo,
                                 RedissonClient redissonClient,
                                 ProcessedPaymentEventRepository processedPaymentEventRepository,
                                 ApplicationEventPublisher eventPublisher,
                                 SlaveOrderRepo slaveOrderRepo,
                                 SlaveOrderItemRepo slaveOrderItemRepo) {
    return new OrderServiceImpl(inventoryGrpcClientService,
            redisRepository,
            pendingOrderCacheRepository,
            masterOrderRepo,
            masterOrderItemRepo,
            redissonClient,
            processedPaymentEventRepository,
            eventPublisher,
            slaveOrderRepo,
            slaveOrderItemRepo);
}
```

- [ ] **Step 5: Compile**

```bash
cd order-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 6: Update the test to wire OrderServiceImpl and verify list method**

Replace `OrderServiceImplReadTest.java` with:

```java
package org.aibles.order_service.service;

import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.dto.response.OrderDetailResponse;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.entity.OrderItem;
import org.aibles.order_service.repository.slave.SlaveOrderItemRepo;
import org.aibles.order_service.repository.slave.SlaveOrderRepo;
import org.aibles.order_service.service.impl.OrderServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class OrderServiceImplReadTest {

    @Mock private org.aibles.order_service.client.InventoryGrpcClientService inventoryGrpcClientService;
    @Mock private org.aibles.ecommerce.core_redis.repository.RedisRepository redisRepository;
    @Mock private org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository pendingOrderCacheRepository;
    @Mock private org.aibles.order_service.repository.master.MasterOrderRepo masterOrderRepo;
    @Mock private org.aibles.order_service.repository.master.MasterOrderItemRepo masterOrderItemRepo;
    @Mock private org.redisson.api.RedissonClient redissonClient;
    @Mock private org.aibles.order_service.repository.ProcessedPaymentEventRepository processedPaymentEventRepository;
    @Mock private org.springframework.context.ApplicationEventPublisher eventPublisher;
    @Mock private SlaveOrderRepo slaveOrderRepo;
    @Mock private SlaveOrderItemRepo slaveOrderItemRepo;

    private OrderServiceImpl orderService;

    @BeforeEach
    void setUp() {
        orderService = new OrderServiceImpl(
                inventoryGrpcClientService, redisRepository, pendingOrderCacheRepository,
                masterOrderRepo, masterOrderItemRepo, redissonClient,
                processedPaymentEventRepository, eventPublisher,
                slaveOrderRepo, slaveOrderItemRepo
        );
    }

    @Test
    void list_shouldReturnPaginatedOrderSummaries() {
        String userId = "user-1";
        Order order = Order.builder()
                .id("order-1").status(OrderStatus.COMPLETED)
                .address("123 Street").phoneNumber("0123456789")
                .userId(userId).createdAt(LocalDateTime.now()).updatedAt(LocalDateTime.now())
                .build();
        Page<Order> orderPage = new PageImpl<>(List.of(order), PageRequest.of(0, 10), 1L);
        when(slaveOrderRepo.findAllByUserId(userId, PageRequest.of(0, 10))).thenReturn(orderPage);

        PagingResponse result = orderService.list(userId, 1, 10);

        assertThat(result.getTotal()).isEqualTo(1L);
        assertThat(result.getPage()).isEqualTo(1);
        verify(slaveOrderRepo).findAllByUserId(userId, PageRequest.of(0, 10));
    }

    @Test
    void get_shouldReturnOrderDetailWithItems() {
        String userId = "user-1";
        String orderId = "order-1";
        Order order = Order.builder()
                .id(orderId).status(OrderStatus.COMPLETED)
                .address("123 Street").phoneNumber("0123456789")
                .userId(userId).createdAt(LocalDateTime.now()).updatedAt(LocalDateTime.now())
                .build();
        OrderItem item = OrderItem.builder()
                .id("item-1").productId("prod-1").price(99.0).quantity(2L).orderId(orderId)
                .build();
        when(slaveOrderRepo.findByIdAndUserId(orderId, userId)).thenReturn(Optional.of(order));
        when(slaveOrderItemRepo.findAllByOrderId(orderId)).thenReturn(List.of(item));

        OrderDetailResponse result = orderService.get(userId, orderId);

        assertThat(result.getId()).isEqualTo(orderId);
        assertThat(result.getItems()).hasSize(1);
        assertThat(result.getItems().get(0).getProductId()).isEqualTo("prod-1");
    }

    @Test
    void get_shouldThrowNotFound_whenOrderDoesNotBelongToUser() {
        when(slaveOrderRepo.findByIdAndUserId("order-1", "user-1")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> orderService.get("user-1", "order-1"))
                .isInstanceOf(org.aibles.ecommerce.common_dto.exception.NotFoundException.class);
    }
}
```

- [ ] **Step 7: Run the tests**

```bash
cd order-service && mvn test -Dtest=OrderServiceImplReadTest -q
```
Expected: All 3 tests PASS

- [ ] **Step 8: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java \
        order-service/src/test/java/org/aibles/order_service/service/OrderServiceImplReadTest.java
git commit -m "feat(order-service): implement list and get order methods with slave routing"
```

---

## Task 6: Add GET endpoints to OrderController

**Files:**
- Modify: `order-service/src/main/java/org/aibles/order_service/controller/OrderController.java`

- [ ] **Step 1: Add the two GET endpoints**

Replace the file content:

```java
package org.aibles.order_service.controller;

import jakarta.validation.Valid;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.request.PagingRequest;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.order_service.dto.request.OrderRequest;
import org.aibles.order_service.service.OrderService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@Slf4j
@RestController
@RequestMapping("/v1/orders")
public class OrderController {

    private final OrderService orderService;

    public OrderController(OrderService orderService) {
        this.orderService = orderService;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public BaseResponse create(@RequestHeader("X-User-Id") String userId,
                               @RequestBody @Valid OrderRequest request) {
        log.info("(create)request : {}", request);
        var response = orderService.create(userId, request);
        return BaseResponse.created(response);
    }

    @GetMapping
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse list(@RequestHeader("X-User-Id") String userId,
                             final PagingRequest pagingRequest) {
        log.info("(list) userId: {}, page: {}, size: {}", userId, pagingRequest.getPage(), pagingRequest.getSize());
        var response = orderService.list(userId, pagingRequest.getPage(), pagingRequest.getSize());
        return BaseResponse.ok(response);
    }

    @GetMapping("/{orderId}")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse get(@RequestHeader("X-User-Id") String userId,
                            @PathVariable String orderId) {
        log.info("(get) userId: {}, orderId: {}", userId, orderId);
        var response = orderService.get(userId, orderId);
        return BaseResponse.ok(response);
    }
}
```

- [ ] **Step 2: Compile**

```bash
cd order-service && mvn compile -q
```
Expected: BUILD SUCCESS

- [ ] **Step 3: Run all tests**

```bash
cd order-service && mvn test -q
```
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/controller/OrderController.java
git commit -m "feat(order-service): add GET /v1/orders and GET /v1/orders/{orderId} endpoints"
```

---

## Verification

- [ ] Start order-service: `cd order-service && mvn spring-boot:run`
- [ ] Open Swagger at `http://localhost:8080/swagger-ui.html` — confirm 3 order endpoints show up
- [ ] Create an order via POST `/v1/orders`, then call GET `/v1/orders` with the same X-User-Id — confirm the order appears
- [ ] Call GET `/v1/orders/{orderId}` — confirm items are returned
- [ ] Call GET `/v1/orders/{orderId}` with a different X-User-Id — confirm 404 response
