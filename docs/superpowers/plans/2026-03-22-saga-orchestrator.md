# Saga Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade `orchestrator-service` from a stateless event router into a true Saga Orchestrator that tracks Order-Payment saga state in MySQL and drives compensation via the existing MongoDB CDC pipeline.

**Architecture:** A new `SagaOrchestrationService` manages a `SagaInstance` state machine (persisted in MySQL). It is triggered by `Order.Created` CDC events and drives state transitions on `Payment.*` CDC events. A `SagaTimeoutScheduler` compensates expired sagas using a Redisson distributed lock. Flows 2 & 3 (product/inventory sync) remain stateless in `EventListenerHandler` — unchanged.

**Tech Stack:** Spring Boot 3.3.6, Spring Data JPA, MySQL (master), Redisson 3.45.1, Kafka (Avro), JUnit 5 + Mockito, H2 (test)

**Spec:** `docs/superpowers/specs/2026-03-22-saga-orchestrator-design.md`

---

## File Map

### New files
| File | Responsibility |
|---|---|
| `core/common-dto/src/main/resources/avro/OrderCreated.avsc` | Avro schema: `{orderId}` |
| `core/common-dto/src/main/java/.../event/OrderCreatedEvent.java` | Spring ApplicationEvent wrapper |
| `orchestrator-service/src/main/java/.../entity/SagaInstance.java` | JPA entity with `@Version` |
| `orchestrator-service/src/main/java/.../repository/SagaInstanceRepository.java` | JPA repo |
| `orchestrator-service/src/main/java/.../service/SagaOrchestrationService.java` | Interface |
| `orchestrator-service/src/main/java/.../service/impl/SagaOrchestrationServiceImpl.java` | Core saga logic |
| `orchestrator-service/src/main/java/.../scheduler/SagaTimeoutScheduler.java` | Expired saga cleanup |
| `orchestrator-service/src/main/java/.../config/OrchestratorConfiguration.java` | JPA + scheduler config |
| `orchestrator-service/src/test/java/.../entity/SagaInstanceRepositoryTest.java` | JPA slice test |
| `orchestrator-service/src/test/java/.../service/SagaOrchestrationServiceImplTest.java` | Unit test |
| `orchestrator-service/src/test/java/.../scheduler/SagaTimeoutSchedulerTest.java` | Unit test |

### Modified files
| File | Change |
|---|---|
| `core/common-dto/src/main/java/.../event/EcommerceEvent.java` | Add `ORDER_CREATED` constant |
| `order-service/.../service/impl/OrderServiceImpl.java` | Add `ApplicationEventPublisher`; publish `Order.Created` after reservation |
| `order-service/.../listener/MongoSavedEventListener.java` | Change `@EventListener` to `@TransactionalEventListener(AFTER_COMMIT)` |
| `order-service/.../configuration/OrderServiceConfiguration.java` | Pass `ApplicationEventPublisher` to `OrderServiceImpl` bean |
| `orchestrator-service/pom.xml` | Add JPA, MySQL, core-redis dependencies |
| `orchestrator-service/src/main/resources/application.yml` | Add JPA + saga config |
| `orchestrator-service/.../listener/MongoEventListener.java` | Route `Order.Created` + `Payment.*` to `SagaOrchestrationService` |
| `orchestrator-service/.../eventhandler/EventListenerHandler.java` | Remove 3 payment handler methods |

---

## Task 1: Add OrderCreated Avro schema and event class to common-dto

**Files:**
- Create: `core/common-dto/src/main/resources/avro/OrderCreated.avsc`
- Create: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/event/OrderCreatedEvent.java`
- Modify: `core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/event/EcommerceEvent.java`

- [ ] **Step 1: Create the Avro schema file**

```json
// core/common-dto/src/main/resources/avro/OrderCreated.avsc
{
  "type": "record",
  "namespace": "org.aibles.ecommerce.common_dto.avro_kafka",
  "name": "OrderCreated",
  "fields": [
    {
      "name": "orderId",
      "type": "string"
    }
  ]
}
```

- [ ] **Step 2: Create the Spring ApplicationEvent wrapper**

```java
// core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/event/OrderCreatedEvent.java
package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;

@Getter
public class OrderCreatedEvent extends BaseEvent {

    public OrderCreatedEvent(Object source, Object data) {
        super(source, data);
    }
}
```

- [ ] **Step 3: Add ORDER_CREATED to EcommerceEvent enum**

In `EcommerceEvent.java`, add the new constant to the enum (after the last existing entry):

```java
PRODUCT_UPDATE("Product.Updated", ProductUpdateEvent::new),
ORDER_CREATED("Order.Created", OrderCreatedEvent::new);  // add this line
```

- [ ] **Step 4: Rebuild and install common-dto**

```bash
cd core/common-dto && mvn clean install -DskipTests
```

Expected: `BUILD SUCCESS`. Verify `target/generated-sources/avro/org/aibles/ecommerce/common_dto/avro_kafka/OrderCreated.java` exists.

- [ ] **Step 5: Commit**

```bash
git add core/common-dto/src/main/resources/avro/OrderCreated.avsc \
        core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/event/OrderCreatedEvent.java \
        core/common-dto/src/main/java/org/aibles/ecommerce/common_dto/event/EcommerceEvent.java
git commit -m "feat(common-dto): add OrderCreated Avro schema and OrderCreatedEvent"
```

---

## Task 2: Publish Order.Created from order-service

**Files:**
- Modify: `order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java`
- Modify: `order-service/src/main/java/org/aibles/order_service/configuration/OrderServiceConfiguration.java`

**Context:** `OrderServiceImpl` does not currently have an `ApplicationEventPublisher`. It is created manually in `OrderServiceConfiguration` (not via `@Service`). The event should be published after `persistOrderAndMetadata()` succeeds, inside `executeWithDistributedLocks()`, before returning the orderId.

- [ ] **Step 1: Add ApplicationEventPublisher field and constructor param to OrderServiceImpl**

Add to the field declarations (after `processedPaymentEventRepository`):
```java
private final ApplicationEventPublisher eventPublisher;
```

Add the import:
```java
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.common_dto.avro_kafka.OrderCreated;
import org.springframework.context.ApplicationEventPublisher;
```

Update the constructor to include `ApplicationEventPublisher eventPublisher` as the last parameter and assign `this.eventPublisher = eventPublisher;`.

- [ ] **Step 2: Publish the event in executeWithDistributedLocks**

In `executeWithDistributedLocks()`, after `Order order = persistOrderAndMetadata(...)` and before `return order.getId()`:

```java
// Publish Order.Created for Saga Orchestrator
OrderCreated orderCreated = OrderCreated.newBuilder()
        .setOrderId(order.getId())
        .build();
eventPublisher.publishEvent(new MongoSavedEvent(
        this,
        EcommerceEvent.ORDER_CREATED.getValue(),
        orderCreated
));
```

- [ ] **Step 3: Update OrderServiceConfiguration bean**

In `OrderServiceConfiguration.orderService()`, add `ApplicationEventPublisher eventPublisher` as a parameter and pass it last to `new OrderServiceImpl(...)`:

```java
@Bean
public OrderService orderService(InventoryGrpcClientService inventoryGrpcClientService,
                                 RedisRepository redisRepository,
                                 PendingOrderCacheRepository pendingOrderCacheRepository,
                                 MasterOrderRepo masterOrderRepo,
                                 MasterOrderItemRepo masterOrderItemRepo,
                                 RedissonClient redissonClient,
                                 ProcessedPaymentEventRepository processedPaymentEventRepository,
                                 ApplicationEventPublisher eventPublisher) {
    return new OrderServiceImpl(inventoryGrpcClientService,
            redisRepository,
            pendingOrderCacheRepository,
            masterOrderRepo,
            masterOrderItemRepo,
            redissonClient,
            processedPaymentEventRepository,
            eventPublisher);
}
```

- [ ] **Step 4: Verify order-service compiles**

```bash
cd order-service && mvn clean compile -DskipTests
```

Expected: `BUILD SUCCESS`

- [ ] **Step 5: Fix MongoSavedEventListener to fire after transaction commits**

In `order-service/src/main/java/org/aibles/order_service/listener/MongoSavedEventListener.java`, change `@EventListener` to `@TransactionalEventListener`:

```java
import org.springframework.transaction.event.TransactionalEventListener;
import org.springframework.transaction.event.TransactionPhase;

// Replace @EventListener with:
@TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
@Async
public void handle(final MongoSavedEvent event) {
    // body unchanged
}
```

**Why:** Without this, the `MongoSavedEvent` fires inside the open transaction. If the `@Async` thread saves to MongoDB before the transaction commits (or after it rolls back), the CDC will produce an `Order.Created` event for an order that does not exist in MySQL. `@TransactionalEventListener(AFTER_COMMIT)` guarantees MongoDB is only written after the order row is committed.

- [ ] **Step 6: Verify order-service compiles**

```bash
cd order-service && mvn clean compile -DskipTests 2>&1 | tail -5
```

Expected: `BUILD SUCCESS`

- [ ] **Step 7: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java \
        order-service/src/main/java/org/aibles/order_service/configuration/OrderServiceConfiguration.java \
        order-service/src/main/java/org/aibles/order_service/listener/MongoSavedEventListener.java
git commit -m "feat(order-service): publish Order.Created event after inventory reservation"
```

---

## Task 3: Add dependencies and config to orchestrator-service

> **Dependency note:** This task requires `common-dto` to already be installed (Task 1 Step 4 must have completed with `BUILD SUCCESS`) because `orchestrator-service` depends on `common-dto:0.0.1` which now includes `ORDER_CREATED`.

**Files:**
- Modify: `orchestrator-service/pom.xml`
- Modify: `orchestrator-service/src/main/resources/application.yml`

- [ ] **Step 1: Create the MySQL database for saga state**

```bash
docker exec docker-mysql-master-1 mysql -u root -p -e "CREATE DATABASE IF NOT EXISTS ecommerce_orchestrator;"
```

- [ ] **Step 2: Add Vault secrets for orchestrator-service datasource**

```bash
docker exec -e VAULT_TOKEN=$VAULT_TOKEN docker-vault-1 vault kv put secret/ecommerce/orchestrator-service \
  spring.datasource.url="jdbc:mysql://mysql-master:3306/ecommerce_orchestrator?useSSL=false&serverTimezone=UTC" \
  spring.datasource.username="<same user as other services>" \
  spring.datasource.password="<password>"
```

(Adjust credentials to match what other services use — check `docker/.env` for the MySQL password.)

- [ ] **Step 3: Add JPA, MySQL, and core-redis dependencies to pom.xml**

Inside the `<dependencies>` block, add:

```xml
<!-- JPA + MySQL for SagaInstance -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-jpa</artifactId>
</dependency>
<dependency>
    <groupId>com.mysql</groupId>
    <artifactId>mysql-connector-j</artifactId>
    <scope>runtime</scope>
</dependency>
<!-- Redisson + Redis config via shared core-redis module -->
<dependency>
    <groupId>org.aibles.ecommerce</groupId>
    <artifactId>core-redis</artifactId>
    <version>0.0.1</version>
</dependency>
<!-- H2 for tests -->
<dependency>
    <groupId>com.h2database</groupId>
    <artifactId>h2</artifactId>
    <scope>test</scope>
</dependency>
```

- [ ] **Step 4: Add JPA + saga config to application.yml**

Add the `jpa:` block **inside the existing top-level `spring:` key** (after the `kafka:` block, before `application:`). Also add the `application.saga` section under the existing `application:` key:

```yaml
spring:
  # ... (existing content) ...
  jpa:
    hibernate:
      ddl-auto: update

application:
  # ... (existing kafka topics) ...
  saga:
    timeout-check-interval: 60000    # milliseconds
    compensation-max-retries: 3
    saga-ttl-minutes: 30
```

Note: `spring.datasource` and Redis credentials are fetched from Vault (`ecommerce/orchestrator-service`). Redis credentials must also be in Vault: `spring.data.redis.host`, `spring.data.redis.port`, `spring.data.redis.password` (matching the values used by other services).

- [ ] **Step 5: Create OrchestratorConfiguration.java**

```java
// orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/config/OrchestratorConfiguration.java
package org.aibles.ecommerce.orchestrator_service.config;

import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.springframework.scheduling.annotation.EnableScheduling;

@Configuration
@EnableCoreRedis   // provides RedissonClient bean via core-redis module
@EnableJpaAuditing
@EnableScheduling
public class OrchestratorConfiguration {
}
```

- [ ] **Step 6: Verify orchestrator-service compiles**

```bash
cd orchestrator-service && mvn clean compile -DskipTests 2>&1 | tail -5
```

Expected: `BUILD SUCCESS`

- [ ] **Step 7: Commit**

```bash
git add orchestrator-service/pom.xml \
        orchestrator-service/src/main/resources/application.yml \
        orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/config/OrchestratorConfiguration.java
git commit -m "feat(orchestrator-service): add JPA, MySQL, core-redis dependencies and config"
```

---

## Task 4: Create SagaInstance entity and repository

**Files:**
- Create: `orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/entity/SagaInstance.java`
- Create: `orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/repository/SagaInstanceRepository.java`
- Create: `orchestrator-service/src/test/java/org/aibles/ecommerce/orchestrator_service/entity/SagaInstanceRepositoryTest.java`

- [ ] **Step 1: Write the failing test**

```java
// orchestrator-service/src/test/java/org/aibles/ecommerce/orchestrator_service/entity/SagaInstanceRepositoryTest.java
package org.aibles.ecommerce.orchestrator_service.entity;

import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.test.autoconfigure.orm.jpa.TestEntityManager;
import org.springframework.dao.DataIntegrityViolationException;
import java.time.LocalDateTime;
import java.util.Optional;
import static org.assertj.core.api.Assertions.*;

@DataJpaTest
@Import(OrchestratorConfiguration.class)  // required: loads @EnableJpaAuditing for AuditingEntityListener
class SagaInstanceRepositoryTest {

    @Autowired TestEntityManager em;
    @Autowired SagaInstanceRepository repo;

    @Test
    void findByOrderId_returnsInstance() {
        SagaInstance saga = SagaInstance.builder()
                .id("saga-1")
                .orderId("order-1")
                .state(SagaState.AWAITING_PAYMENT)
                .createdAt(LocalDateTime.now())
                .updatedAt(LocalDateTime.now())
                .expiresAt(LocalDateTime.now().plusMinutes(30))
                .build();
        em.persist(saga);
        em.flush();

        Optional<SagaInstance> result = repo.findByOrderId("order-1");
        assertThat(result).isPresent();
        assertThat(result.get().getState()).isEqualTo(SagaState.AWAITING_PAYMENT);
    }

    @Test
    void duplicateOrderId_throwsDataIntegrityViolation() {
        SagaInstance s1 = buildSaga("saga-2", "order-2");
        SagaInstance s2 = buildSaga("saga-3", "order-2");
        em.persist(s1);
        em.flush();
        assertThatThrownBy(() -> { em.persist(s2); em.flush(); })
                .isInstanceOf(Exception.class);
    }

    @Test
    void findExpiredSagas_returnsOnlyExpiredAwaitingPayment() {
        SagaInstance expired = buildSagaWithExpiry("saga-4", "order-4", LocalDateTime.now().minusMinutes(1));
        SagaInstance notExpired = buildSagaWithExpiry("saga-5", "order-5", LocalDateTime.now().plusMinutes(30));
        SagaInstance completedExpired = buildSagaWithExpiry("saga-6", "order-6", LocalDateTime.now().minusMinutes(1));
        completedExpired.setState(SagaState.COMPLETED);
        em.persist(expired); em.persist(notExpired); em.persist(completedExpired);
        em.flush();

        var result = repo.findExpiredSagas(LocalDateTime.now());
        assertThat(result).hasSize(1);
        assertThat(result.get(0).getOrderId()).isEqualTo("order-4");
    }

    private SagaInstance buildSaga(String id, String orderId) {
        return buildSagaWithExpiry(id, orderId, LocalDateTime.now().plusMinutes(30));
    }

    private SagaInstance buildSagaWithExpiry(String id, String orderId, LocalDateTime expiresAt) {
        return SagaInstance.builder()
                .id(id).orderId(orderId).state(SagaState.AWAITING_PAYMENT)
                .createdAt(LocalDateTime.now()).updatedAt(LocalDateTime.now())
                .expiresAt(expiresAt).build();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd orchestrator-service && mvn test -Dtest=SagaInstanceRepositoryTest -pl . 2>&1 | tail -20
```

Expected: FAIL with `cannot find symbol SagaInstance` or similar.

- [ ] **Step 3: Create SagaState enum**

```java
// orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/entity/SagaState.java
package org.aibles.ecommerce.orchestrator_service.entity;

public enum SagaState {
    STARTED, AWAITING_PAYMENT, CONFIRMING, COMPENSATING,
    COMPLETED, COMPENSATED, FAILED;

    public boolean isTerminal() {
        return this == COMPLETED || this == COMPENSATED || this == FAILED;
    }
}
```

- [ ] **Step 4: Create SagaInstance entity**

```java
// orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/entity/SagaInstance.java
package org.aibles.ecommerce.orchestrator_service.entity;

import jakarta.persistence.*;
import lombok.*;
import org.springframework.data.annotation.CreatedDate;
import org.springframework.data.annotation.LastModifiedDate;
import org.springframework.data.jpa.domain.support.AuditingEntityListener;
import java.time.LocalDateTime;

@Entity
@Table(name = "saga_instance",
       uniqueConstraints = @UniqueConstraint(columnNames = "order_id"))
@EntityListeners(AuditingEntityListener.class)
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class SagaInstance {

    @Id
    private String id;

    @Column(name = "order_id", nullable = false, unique = true)
    private String orderId;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private SagaState state;

    @Version
    private int version;

    @CreatedDate
    @Column(name = "created_at", nullable = false, updatable = false)
    private LocalDateTime createdAt;

    @LastModifiedDate
    @Column(name = "updated_at", nullable = false)
    private LocalDateTime updatedAt;

    @Column(name = "expires_at", nullable = false)
    private LocalDateTime expiresAt;
}
```

- [ ] **Step 5: Create SagaInstanceRepository**

```java
// orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/repository/SagaInstanceRepository.java
package org.aibles.ecommerce.orchestrator_service.repository;

import org.aibles.ecommerce.orchestrator_service.entity.SagaInstance;
import org.aibles.ecommerce.orchestrator_service.entity.SagaState;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

public interface SagaInstanceRepository extends JpaRepository<SagaInstance, String> {

    Optional<SagaInstance> findByOrderId(String orderId);

    @Query("SELECT s FROM SagaInstance s WHERE s.state = org.aibles.ecommerce.orchestrator_service.entity.SagaState.AWAITING_PAYMENT AND s.expiresAt < :now")
    List<SagaInstance> findExpiredSagas(@Param("now") LocalDateTime now);
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd orchestrator-service && mvn test -Dtest=SagaInstanceRepositoryTest 2>&1 | tail -10
```

Expected: `Tests run: 3, Failures: 0, Errors: 0`

- [ ] **Step 7: Commit**

```bash
git add orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/entity/ \
        orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/repository/ \
        orchestrator-service/src/test/java/org/aibles/ecommerce/orchestrator_service/entity/
git commit -m "feat(orchestrator-service): add SagaInstance entity and repository"
```

---

## Task 5: Create SagaOrchestrationService

**Files:**
- Create: `orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/service/SagaOrchestrationService.java`
- Create: `orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/service/impl/SagaOrchestrationServiceImpl.java`
- Create: `orchestrator-service/src/test/java/org/aibles/ecommerce/orchestrator_service/service/SagaOrchestrationServiceImplTest.java`

- [ ] **Step 1: Write the failing tests**

```java
// orchestrator-service/src/test/java/org/aibles/ecommerce/orchestrator_service/service/SagaOrchestrationServiceImplTest.java
package org.aibles.ecommerce.orchestrator_service.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.aibles.ecommerce.common_dto.event.*;
import org.aibles.ecommerce.orchestrator_service.config.ApplicationKafkaProperties;
import org.aibles.ecommerce.orchestrator_service.entity.*;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.aibles.ecommerce.orchestrator_service.service.impl.SagaOrchestrationServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.*;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.kafka.core.KafkaTemplate;
import java.time.LocalDateTime;
import java.util.Map;
import java.util.Optional;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class SagaOrchestrationServiceImplTest {

    @Mock SagaInstanceRepository repo;
    @Mock KafkaTemplate<String, Object> kafkaTemplate;
    @Mock ApplicationKafkaProperties kafkaProperties;
    @Mock ObjectMapper objectMapper;

    SagaOrchestrationServiceImpl service;

    @BeforeEach
    void setUp() {
        when(kafkaProperties.getTopics()).thenReturn(Map.of(
                "order-service.order.success-status", "order-service.order.success-status",
                "order-service.order.failed-status", "order-service.order.failed-status",
                "order-service.order.canceled-status", "order-service.order.canceled-status",
                "inventory-service.inventory-product.update-quantity", "inventory-service.inventory-product.update-quantity"
        ));
        service = new SagaOrchestrationServiceImpl(repo, kafkaTemplate, kafkaProperties, objectMapper, 3, 30);
    }

    @Test
    void startSaga_createsSagaInAwaitingPayment() {
        service.startSaga("order-1");
        ArgumentCaptor<SagaInstance> captor = ArgumentCaptor.forClass(SagaInstance.class);
        verify(repo).save(captor.capture());
        assertThat(captor.getValue().getState()).isEqualTo(SagaState.AWAITING_PAYMENT);
        assertThat(captor.getValue().getOrderId()).isEqualTo("order-1");
    }

    @Test
    void startSaga_duplicateOrderId_logsAndReturnsGracefully() {
        when(repo.save(any())).thenThrow(DataIntegrityViolationException.class);
        assertThatNoException().isThrownBy(() -> service.startSaga("order-1"));
    }

    @Test
    void handlePaymentReply_success_transitionsToCompleted() {
        SagaInstance saga = existingSaga("order-2", SagaState.AWAITING_PAYMENT);
        when(repo.findByOrderId("order-2")).thenReturn(Optional.of(saga));
        // event data is a Map — extractOrderId takes the instanceof Map path, objectMapper not called

        PaymentSuccessEvent event = new PaymentSuccessEvent(this, Map.of("orderId", "order-2"));
        service.handlePaymentReply(event);

        assertThat(saga.getState()).isEqualTo(SagaState.COMPLETED);
        verify(kafkaTemplate, times(2)).send(anyString(), any()); // order + inventory
    }

    @Test
    void handlePaymentReply_failed_transitionsToCompensated() {
        SagaInstance saga = existingSaga("order-3", SagaState.AWAITING_PAYMENT);
        when(repo.findByOrderId("order-3")).thenReturn(Optional.of(saga));

        PaymentFailedEvent event = new PaymentFailedEvent(this, Map.of("orderId", "order-3"));
        service.handlePaymentReply(event);

        assertThat(saga.getState()).isEqualTo(SagaState.COMPENSATED);
        verify(kafkaTemplate, times(1)).send(anyString(), any()); // order only
    }

    @Test
    void handlePaymentReply_alreadyTerminal_isDiscarded() {
        SagaInstance saga = existingSaga("order-4", SagaState.COMPLETED);
        when(repo.findByOrderId("order-4")).thenReturn(Optional.of(saga));

        PaymentSuccessEvent event = new PaymentSuccessEvent(this, Map.of("orderId", "order-4"));
        service.handlePaymentReply(event);

        verify(kafkaTemplate, never()).send(anyString(), any());
    }

    @Test
    void handlePaymentReply_unknownOrderId_isDiscarded() {
        when(repo.findByOrderId("order-x")).thenReturn(Optional.empty());

        PaymentSuccessEvent event = new PaymentSuccessEvent(this, Map.of("orderId", "order-x"));
        service.handlePaymentReply(event);

        verify(kafkaTemplate, never()).send(anyString(), any());
    }

    @Test
    void compensate_sendsToOrderServiceAndTransitionsToCompensated() {
        SagaInstance saga = existingSaga("order-5", SagaState.AWAITING_PAYMENT);

        service.compensate(saga, "order-service.order.canceled-status");

        assertThat(saga.getState()).isEqualTo(SagaState.COMPENSATED);
        verify(kafkaTemplate).send(eq("order-service.order.canceled-status"), any());
    }

    @Test
    void compensate_kafkaFailsAllRetries_transitionsToFailed() {
        SagaInstance saga = existingSaga("order-6", SagaState.AWAITING_PAYMENT);
        when(kafkaTemplate.send(anyString(), any())).thenThrow(new RuntimeException("Kafka down"));

        service.compensate(saga, "order-service.order.canceled-status");

        assertThat(saga.getState()).isEqualTo(SagaState.FAILED);
        // 3 retries attempted (maxRetries=3 set in setUp)
        verify(kafkaTemplate, times(3)).send(anyString(), any());
    }

    private SagaInstance existingSaga(String orderId, SagaState state) {
        return SagaInstance.builder()
                .id("id-" + orderId).orderId(orderId).state(state)
                .createdAt(LocalDateTime.now()).updatedAt(LocalDateTime.now())
                .expiresAt(LocalDateTime.now().plusMinutes(30))
                .build();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd orchestrator-service && mvn test -Dtest=SagaOrchestrationServiceImplTest 2>&1 | tail -10
```

Expected: FAIL — `SagaOrchestrationServiceImpl` does not exist.

- [ ] **Step 3: Create the service interface**

```java
// orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/service/SagaOrchestrationService.java
package org.aibles.ecommerce.orchestrator_service.service;

import org.aibles.ecommerce.common_dto.event.BaseEvent;
import org.aibles.ecommerce.orchestrator_service.entity.SagaInstance;

public interface SagaOrchestrationService {
    void startSaga(String orderId);
    void handlePaymentReply(BaseEvent event);
    /**
     * @param compensationTopic the RESOLVED Kafka topic name (not a properties key).
     *                          Callers must resolve topic keys via kafkaProperties.getTopics()
     *                          before passing here. The scheduler passes the literal topic name.
     */
    void compensate(SagaInstance saga, String compensationTopic);
}
```

- [ ] **Step 4: Create SagaOrchestrationServiceImpl**

```java
// orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/service/impl/SagaOrchestrationServiceImpl.java
package org.aibles.ecommerce.orchestrator_service.service.impl;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentFailed;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentSuccess;
import org.aibles.ecommerce.common_dto.event.*;
import org.aibles.ecommerce.orchestrator_service.config.ApplicationKafkaProperties;
import org.aibles.ecommerce.orchestrator_service.entity.*;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.aibles.ecommerce.orchestrator_service.service.SagaOrchestrationService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

@Slf4j
@Service
public class SagaOrchestrationServiceImpl implements SagaOrchestrationService {

    private final SagaInstanceRepository repo;
    private final KafkaTemplate<String, Object> kafkaTemplate;
    private final ApplicationKafkaProperties kafkaProperties;
    private final ObjectMapper objectMapper;
    private final int maxRetries;
    private final int sagaTtlMinutes;

    public SagaOrchestrationServiceImpl(
            SagaInstanceRepository repo,
            KafkaTemplate<String, Object> kafkaTemplate,
            ApplicationKafkaProperties kafkaProperties,
            ObjectMapper objectMapper,
            @Value("${application.saga.compensation-max-retries:3}") int maxRetries,
            @Value("${application.saga.saga-ttl-minutes:30}") int sagaTtlMinutes) {
        this.repo = repo;
        this.kafkaTemplate = kafkaTemplate;
        this.kafkaProperties = kafkaProperties;
        this.objectMapper = objectMapper;
        this.maxRetries = maxRetries;
        this.sagaTtlMinutes = sagaTtlMinutes;
    }

    @Override
    @Transactional
    public void startSaga(String orderId) {
        log.info("(startSaga) Starting saga for orderId: {}", orderId);
        SagaInstance saga = SagaInstance.builder()
                .id(UUID.randomUUID().toString())
                .orderId(orderId)
                .state(SagaState.AWAITING_PAYMENT)
                .expiresAt(LocalDateTime.now().plusMinutes(sagaTtlMinutes))
                .build();
        try {
            repo.save(saga);
            log.info("(startSaga) Saga created in AWAITING_PAYMENT for orderId: {}", orderId);
        } catch (DataIntegrityViolationException e) {
            log.warn("(startSaga) Saga already exists for orderId: {} — duplicate Order.Created, discarding", orderId);
        }
    }

    @Override
    @Transactional
    public void handlePaymentReply(BaseEvent event) {
        String orderId = extractOrderId(event.getData());
        if (orderId == null) {
            log.warn("(handlePaymentReply) Cannot extract orderId from event data: {}", event.getData());
            return;
        }

        Optional<SagaInstance> optional = repo.findByOrderId(orderId);
        if (optional.isEmpty()) {
            log.warn("(handlePaymentReply) No SagaInstance for orderId: {} — discarding", orderId);
            return;
        }

        SagaInstance saga = optional.get();
        if (saga.getState().isTerminal()) {
            log.warn("(handlePaymentReply) Saga for orderId: {} is already in terminal state {} — discarding", orderId, saga.getState());
            return;
        }

        if (event instanceof PaymentSuccessEvent) {
            handleSuccess(saga, orderId);
        } else if (event instanceof PaymentFailedEvent) {
            compensate(saga, topic("order-service.order.failed-status"));
        } else if (event instanceof PaymentCanceledEvent) {
            compensate(saga, topic("order-service.order.canceled-status"));
        }
    }

    @Override
    @Transactional
    public void compensate(SagaInstance saga, String compensationTopic) {
        log.info("(compensate) Compensating saga orderId: {} via topic: {}", saga.getOrderId(), compensationTopic);
        saga.setState(SagaState.COMPENSATING);
        repo.save(saga);

        String orderId = saga.getOrderId();
        boolean sent = sendWithRetry(compensationTopic, buildPaymentFailed(orderId));
        if (!sent) {
            saga.setState(SagaState.FAILED);
            repo.save(saga);
            log.error("(compensate) Saga FAILED — could not send compensation for orderId: {}", orderId);
            return;
        }

        saga.setState(SagaState.COMPENSATED);
        repo.save(saga);
        log.info("(compensate) Saga COMPENSATED for orderId: {}", orderId);
    }

    private void handleSuccess(SagaInstance saga, String orderId) {
        saga.setState(SagaState.CONFIRMING);
        repo.save(saga);

        PaymentSuccess avro = PaymentSuccess.newBuilder().setOrderId(orderId).build();
        boolean orderSent = sendWithRetry(topic("order-service.order.success-status"), avro);
        boolean inventorySent = sendWithRetry(topic("inventory-service.inventory-product.update-quantity"), avro);

        if (orderSent && inventorySent) {
            saga.setState(SagaState.COMPLETED);
        } else {
            log.error("(handleSuccess) Failed to notify all services for orderId: {} — compensating", orderId);
            saga.setState(SagaState.COMPENSATING);
            sendWithRetry(topic("order-service.order.failed-status"), buildPaymentFailed(orderId));
            saga.setState(SagaState.COMPENSATED);
        }
        repo.save(saga);
    }

    private boolean sendWithRetry(String topicName, Object message) {
        for (int attempt = 1; attempt <= maxRetries; attempt++) {
            try {
                kafkaTemplate.send(topicName, message);
                return true;
            } catch (Exception e) {
                log.warn("(sendWithRetry) Attempt {}/{} failed for topic: {}", attempt, maxRetries, topicName, e);
            }
        }
        return false;
    }

    private String topic(String key) {
        return kafkaProperties.getTopics().get(key);
    }

    private PaymentFailed buildPaymentFailed(String orderId) {
        return PaymentFailed.newBuilder().setOrderId(orderId).build();
    }

    private String extractOrderId(Object data) {
        try {
            if (data instanceof Map) {
                Object id = ((Map<?, ?>) data).get("orderId");
                return id != null ? id.toString() : null;
            }
            String json = objectMapper.writeValueAsString(data);
            return objectMapper.readTree(json).path("orderId").asText(null);
        } catch (Exception e) {
            log.warn("(extractOrderId) Failed to extract orderId from data: {}", data, e);
            return null;
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd orchestrator-service && mvn test -Dtest=SagaOrchestrationServiceImplTest 2>&1 | tail -10
```

Expected: `Tests run: 6, Failures: 0, Errors: 0`

- [ ] **Step 6: Commit**

```bash
git add orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/service/ \
        orchestrator-service/src/test/java/org/aibles/ecommerce/orchestrator_service/service/
git commit -m "feat(orchestrator-service): add SagaOrchestrationService with state machine logic"
```

---

## Task 6: Create SagaTimeoutScheduler

**Files:**
- Create: `orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/scheduler/SagaTimeoutScheduler.java`
- Create: `orchestrator-service/src/test/java/org/aibles/ecommerce/orchestrator_service/scheduler/SagaTimeoutSchedulerTest.java`

- [ ] **Step 1: Write the failing test**

```java
// orchestrator-service/src/test/java/org/aibles/ecommerce/orchestrator_service/scheduler/SagaTimeoutSchedulerTest.java
package org.aibles.ecommerce.orchestrator_service.scheduler;

import org.aibles.ecommerce.orchestrator_service.entity.*;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.aibles.ecommerce.orchestrator_service.service.SagaOrchestrationService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.*;
import org.mockito.junit.jupiter.MockitoExtension;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import java.time.LocalDateTime;
import java.util.List;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class SagaTimeoutSchedulerTest {

    @Mock SagaInstanceRepository repo;
    @Mock SagaOrchestrationService orchestrationService;
    @Mock RedissonClient redissonClient;
    @Mock RLock lock;

    @Test
    void checkExpiredSagas_compensatesExpiredSagas() throws InterruptedException {
        when(redissonClient.getLock("saga-timeout-scheduler-lock")).thenReturn(lock);
        when(lock.tryLock(anyLong(), anyLong(), any())).thenReturn(true);

        SagaInstance expired = SagaInstance.builder()
                .id("saga-1").orderId("order-1").state(SagaState.AWAITING_PAYMENT)
                .createdAt(LocalDateTime.now()).updatedAt(LocalDateTime.now())
                .expiresAt(LocalDateTime.now().minusMinutes(1))
                .build();
        when(repo.findExpiredSagas(any())).thenReturn(List.of(expired));

        SagaTimeoutScheduler scheduler = new SagaTimeoutScheduler(repo, orchestrationService, redissonClient);
        scheduler.checkExpiredSagas();

        verify(orchestrationService).compensate(eq(expired), eq("order-service.order.canceled-status"));
        verify(lock).unlock();
    }

    @Test
    void checkExpiredSagas_skipsIfLockNotAcquired() throws InterruptedException {
        when(redissonClient.getLock("saga-timeout-scheduler-lock")).thenReturn(lock);
        when(lock.tryLock(anyLong(), anyLong(), any())).thenReturn(false);

        SagaTimeoutScheduler scheduler = new SagaTimeoutScheduler(repo, orchestrationService, redissonClient);
        scheduler.checkExpiredSagas();

        verify(orchestrationService, never()).compensate(any(), any());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd orchestrator-service && mvn test -Dtest=SagaTimeoutSchedulerTest 2>&1 | tail -5
```

Expected: FAIL — class not found.

- [ ] **Step 3: Create SagaTimeoutScheduler**

```java
// orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/scheduler/SagaTimeoutScheduler.java
package org.aibles.ecommerce.orchestrator_service.scheduler;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.orchestrator_service.entity.SagaInstance;
import org.aibles.ecommerce.orchestrator_service.repository.SagaInstanceRepository;
import org.aibles.ecommerce.orchestrator_service.service.SagaOrchestrationService;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.util.List;
import java.util.concurrent.TimeUnit;

@Slf4j
@Component
@RequiredArgsConstructor
public class SagaTimeoutScheduler {

    private static final String LOCK_KEY = "saga-timeout-scheduler-lock";

    private final SagaInstanceRepository repo;
    private final SagaOrchestrationService orchestrationService;
    private final RedissonClient redissonClient;

    @Scheduled(fixedDelayString = "${application.saga.timeout-check-interval:60000}")
    public void checkExpiredSagas() {
        RLock lock = redissonClient.getLock(LOCK_KEY);
        boolean locked = false;
        try {
            locked = lock.tryLock(0, 55, TimeUnit.SECONDS);
            if (!locked) {
                log.debug("(checkExpiredSagas) Could not acquire lock — another instance is running");
                return;
            }

            List<SagaInstance> expired = repo.findExpiredSagas(LocalDateTime.now());
            log.info("(checkExpiredSagas) Found {} expired sagas", expired.size());

            for (SagaInstance saga : expired) {
                log.info("(checkExpiredSagas) Timeout compensation for orderId: {}", saga.getOrderId());
                orchestrationService.compensate(saga, "order-service.order.canceled-status");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            log.error("(checkExpiredSagas) Interrupted while acquiring lock", e);
        } finally {
            if (locked) {
                lock.unlock();
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd orchestrator-service && mvn test -Dtest=SagaTimeoutSchedulerTest 2>&1 | tail -5
```

Expected: `Tests run: 2, Failures: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git add orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/scheduler/ \
        orchestrator-service/src/test/java/org/aibles/ecommerce/orchestrator_service/scheduler/
git commit -m "feat(orchestrator-service): add SagaTimeoutScheduler with distributed lock"
```

---

## Task 7: Update MongoEventListener routing

**Files:**
- Modify: `orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/listener/MongoEventListener.java`

**Context:** Currently `MongoEventListener` resolves the event name from `EcommerceEvent` enum, then publishes a Spring `ApplicationEvent` via `eventPublisher`. `EventListenerHandler` handles all 5 event types. After this task, `Payment.*` and `Order.Created` events will route to `SagaOrchestrationService` instead of (or in addition to) `eventPublisher`.

The routing logic: after `EcommerceEvent.resolve()`:
- `ORDER_CREATED` → `sagaOrchestrationService.startSaga(orderId)`
- `PAYMENT_SUCCESS / FAILED / CANCELED` → `sagaOrchestrationService.handlePaymentReply(baseEvent)`
- `PRODUCT_QUANTITY_UPDATED / PRODUCT_UPDATE` → keep publishing Spring event (EventListenerHandler handles these)

- [ ] **Step 1: Update MongoEventListener**

Replace the current `handleChangeStream` method body to add saga routing. The full updated file:

```java
package org.aibles.ecommerce.orchestrator_service.listener;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.event.BaseEvent;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.orchestrator_service.dto.EventDTO;
import org.aibles.ecommerce.orchestrator_service.service.SagaOrchestrationService;
import org.apache.avro.generic.GenericRecord;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.messaging.handler.annotation.Payload;
import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.Optional;
import java.util.Set;

@Slf4j
@Component
public class MongoEventListener {

    private static final Set<String> SAGA_PAYMENT_EVENTS = Set.of(
            EcommerceEvent.PAYMENT_SUCCESS.getValue(),
            EcommerceEvent.PAYMENT_FAILED.getValue(),
            EcommerceEvent.PAYMENT_CANCELED.getValue()
    );

    private final ObjectMapper mapper;
    private final ApplicationEventPublisher eventPublisher;
    private final SagaOrchestrationService sagaOrchestrationService;

    public MongoEventListener(ObjectMapper mapper,
                              ApplicationEventPublisher eventPublisher,
                              SagaOrchestrationService sagaOrchestrationService) {
        this.mapper = mapper;
        this.eventPublisher = eventPublisher;
        this.sagaOrchestrationService = sagaOrchestrationService;
    }

    @KafkaListener(groupId = "${application.kafka.group-id.mongo.event}",
            topics = "${application.kafka.topics.mongo.event}")
    private void handleChangeStream(@Payload final GenericRecord genericRecord,
                                    @Header(KafkaHeaders.OFFSET) final Long offset) throws JsonProcessingException {
        log.info("(handleChangeStream) offset: {}", offset);

        Object fullDocumentObj = genericRecord.get("fullDocument");
        if (fullDocumentObj == null) {
            log.warn("(handleChangeStream) fullDocument is null, skipping");
            return;
        }

        EventDTO eventDTO = mapper.readValue(fullDocumentObj.toString(), EventDTO.class);

        Optional<EcommerceEvent> eventOptional = EcommerceEvent.resolve(eventDTO.getName());
        if (eventOptional.isEmpty()) {
            log.warn("(handleChangeStream) unknown event name: {} — skipping", eventDTO.getName());
            return;
        }

        EcommerceEvent ecommerceEvent = eventOptional.get();
        String eventName = ecommerceEvent.getValue();

        // Route Order.Created to saga orchestrator
        if (EcommerceEvent.ORDER_CREATED.getValue().equals(eventName)) {
            String orderId = extractOrderId(eventDTO.getData());
            if (orderId != null) {
                sagaOrchestrationService.startSaga(orderId);
            }
            return;
        }

        // Route Payment.* to saga orchestrator
        if (SAGA_PAYMENT_EVENTS.contains(eventName)) {
            BaseEvent baseEvent = ecommerceEvent.createEvent(this, eventDTO.getData());
            sagaOrchestrationService.handlePaymentReply(baseEvent);
            return;
        }

        // Flows 2 & 3: stateless routing via EventListenerHandler
        eventPublisher.publishEvent(ecommerceEvent.createEvent(this, eventDTO.getData()));
    }

    private String extractOrderId(Object data) {
        if (data instanceof Map) {
            Object id = ((Map<?, ?>) data).get("orderId");
            return id != null ? id.toString() : null;
        }
        return null;
    }
}
```

- [ ] **Step 2: Verify orchestrator-service compiles**

```bash
cd orchestrator-service && mvn clean compile -DskipTests 2>&1 | tail -5
```

Expected: `BUILD SUCCESS`

- [ ] **Step 3: Commit**

```bash
git add orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/listener/MongoEventListener.java
git commit -m "feat(orchestrator-service): route Order.Created and Payment.* events to SagaOrchestrationService"
```

---

## Task 8: Remove payment handlers from EventListenerHandler

**Files:**
- Modify: `orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/eventhandler/EventListenerHandler.java`

**Context:** `handlePaymentSuccess`, `handlePaymentFailed`, and `handlePaymentCanceled` are now handled by `SagaOrchestrationService`. Remove them. Keep `handleProductQuantityUpdated` and `handleProductUpdate`.

- [ ] **Step 1: Remove the three payment handler methods**

Delete the following three methods entirely from `EventListenerHandler.java`:
- `handlePaymentSuccess(PaymentSuccessEvent event)` (lines ~46–63)
- `handlePaymentFailed(PaymentFailedEvent event)` (lines ~65–81)
- `handlePaymentCanceled(PaymentCanceledEvent event)` (lines ~83–99)

Keep:
- `handleProductQuantityUpdated(ProductQuantityUpdatedEvent event)`
- `handleProductUpdate(ProductUpdateEvent event)`
- `convertEventData`, `publishToTopics` helpers

**Import note:** The file uses a wildcard import `import org.aibles.ecommerce.common_dto.avro_kafka.*;` which covers all Avro types including `PaymentSuccess`, `PaymentFailed`, `PaymentCanceled` AND `ProductQuantityUpdated`, `ProductUpdate`. Do **NOT** remove this wildcard import — removing it would break the remaining handlers. Only delete the three method bodies.

- [ ] **Step 2: Verify compile**

```bash
cd orchestrator-service && mvn clean compile -DskipTests 2>&1 | tail -5
```

Expected: `BUILD SUCCESS`

- [ ] **Step 3: Run all orchestrator tests**

```bash
cd orchestrator-service && mvn test 2>&1 | tail -15
```

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add orchestrator-service/src/main/java/org/aibles/ecommerce/orchestrator_service/eventhandler/EventListenerHandler.java
git commit -m "refactor(orchestrator-service): remove payment event handlers from EventListenerHandler"
```

---

## Task 9: End-to-end smoke test

Before running, ensure:
1. `CREATE DATABASE IF NOT EXISTS ecommerce_orchestrator;` on MySQL master
2. Vault has `spring.datasource.*` and Redis config for orchestrator-service
3. `cd core/common-dto && mvn clean install -DskipTests` to refresh the shared JAR
4. Start all infrastructure: `./start-infrastructure.sh && ./init-vault.sh unseal`

- [ ] **Step 1: Start services in order**
```bash
# 1. eureka-server
# 2. authorization-server
# 3. gateway
# 4. inventory-service (must start before order-service)
# 5. order-service
# 6. payment-service
# 7. orchestrator-service
```

- [ ] **Step 2: Verify SagaInstance table was created**
```bash
docker exec docker-mysql-master-1 mysql -u root -p ecommerce_orchestrator -e "DESCRIBE saga_instance;"
```
Expected: table with columns `id, order_id, state, version, created_at, updated_at, expires_at`

- [ ] **Step 3: Happy path — place an order and complete payment**

1. Login via `/authorization-server/auth/login`
2. Create order: `POST /order-service/orders`
3. Check `saga_instance` table — row with state `AWAITING_PAYMENT` should appear
4. Initiate payment: `POST /payment-service/payments` (returns PayPal redirect URL)
5. Complete PayPal payment (use PayPal sandbox)
6. Check `saga_instance` — state should change to `COMPLETED`
7. Check order status — should be `COMPLETED`

- [ ] **Step 4: Compensation path — cancel payment**

1. Create a new order
2. Check `saga_instance` — state `AWAITING_PAYMENT`
3. Cancel payment via PayPal sandbox
4. Check `saga_instance` — state should change to `COMPENSATED`
5. Check order status — should be `CANCELED`

- [ ] **Step 5: Commit final state**

```bash
git add docs/superpowers/plans/2026-03-22-saga-orchestrator.md
git commit -m "docs: add saga orchestrator implementation plan"
```
