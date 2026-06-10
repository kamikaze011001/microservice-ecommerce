# Stress-Run Fixes: Cart Upsert Race, Payment JTA Saturation, Replication Tuning — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (user chose **inline execution**) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the three defects found in the 2026-06-10 stress run (see `docs/performance-stress-report-2026-06-10.md`): cart duplicate-row corruption, payment-service Atomikos `maxActives=50` saturation, and 15s MySQL replication lag — plus the watch-item config headroom.

**Architecture:** (1) Cart: replace check-then-insert with a DB-enforced unique key + atomic `INSERT ... ON DUPLICATE KEY UPDATE` (sum quantities, price updates to latest); dedup existing corrupted rows. (2) Payment: "call-then-record" — PayPal HTTP calls leave the transaction; a new manually-wired `PaymentRecorder` bean owns short `@Transactional` write+event methods (separate bean because Spring proxy self-invocation would skip `@Transactional`). (3) Infra: WRITESET dependency tracking on the k8s MySQL primary (parity with docker-compose, feeds the replicas' existing `LOGICAL_CLOCK` parallel workers), workers 4→8, `max_connections` 151→300, Mongo CPU 800m→1500m, PayPal RestTemplate timeouts, `max_actives` 50→200 stopgap.

**Tech Stack:** Spring Boot 3.3.6 / Java 17 / Spring Data JPA (Hibernate 6.5, `ddl-auto: update`) / Atomikos JTA / MySQL 8.0.40 GTID replication / kind k8s.

**User decisions (locked):** sum quantities on dedup+upsert · price = latest request · inline execution.

**Key repo conventions that apply:** services are manually wired in `@Configuration` classes (no `@Service`); master repos write, slave repos read; tests are plain JUnit 5 + Mockito with `new Impl(mocks)` (see `order-service/src/test/.../OrderCancelServiceTest`); core/* changes require the cores image rebuild before `make k8s-rebuild` (SKIP_CORES=1 trap).

---

### Task 0: Branch + plan doc

**Files:**
- Create: `docs/superpowers/plans/2026-06-10-stress-fixes-cart-payment-replication.md` (copy of this plan)

- [ ] **Step 0.1:** From current branch `docs/perf-stress-report-2026-06-10` (holds the uncommitted report), create the work branch:
```bash
git checkout -b fix/stress-20260610-cart-payment-replication
git add docs/performance-stress-report-2026-06-10.md
git commit -m "docs: stress-run report 2026-06-10 (cart race, payment JTA cap, replica lag)"
```
- [ ] **Step 0.2:** Copy this plan file to `docs/superpowers/plans/2026-06-10-stress-fixes-cart-payment-replication.md`, commit:
```bash
git add docs/superpowers/plans/2026-06-10-stress-fixes-cart-payment-replication.md
git commit -m "docs: implementation plan for stress-run fixes"
```

---

### Task 1: Cart — atomic upsert (TDD)

**Files:**
- Test (create): `order-service/src/test/java/org/aibles/order_service/service/ShoppingCartServiceTest.java`
- Modify: `order-service/src/main/java/org/aibles/order_service/repository/master/MasterShoppingCartItemRepo.java`
- Modify: `order-service/src/main/java/org/aibles/order_service/repository/master/MasterShoppingCartRepo.java`
- Modify: `order-service/src/main/java/org/aibles/order_service/service/impl/ShoppingCartServiceImpl.java`
- Modify: `order-service/src/main/java/org/aibles/order_service/configuration/OrderServiceConfiguration.java:47` (drop a ctor arg)
- Delete: `order-service/src/main/java/org/aibles/order_service/repository/slave/SlaveShoppingCartItemRepo.java` (only ever used by the old addItem path — verified via grep)

- [ ] **Step 1.1: Write the failing test** (Mockito pattern copied from `OrderCancelServiceTest`):

```java
package org.aibles.order_service.service;

import org.aibles.order_service.dto.request.ShoppingCartAddRequest;
import org.aibles.order_service.repository.master.MasterShoppingCartItemRepo;
import org.aibles.order_service.repository.master.MasterShoppingCartRepo;
import org.aibles.order_service.repository.slave.SlaveShoppingCartRepo;
import org.aibles.order_service.service.impl.ShoppingCartServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ShoppingCartServiceTest {

    private MasterShoppingCartRepo masterShoppingCartRepo;
    private SlaveShoppingCartRepo slaveShoppingCartRepo;
    private MasterShoppingCartItemRepo masterShoppingCartItemRepo;
    private ShoppingCartService sut;

    @BeforeEach
    void setUp() {
        masterShoppingCartRepo = mock(MasterShoppingCartRepo.class);
        slaveShoppingCartRepo = mock(SlaveShoppingCartRepo.class);
        masterShoppingCartItemRepo = mock(MasterShoppingCartItemRepo.class);
        sut = new ShoppingCartServiceImpl(
                masterShoppingCartRepo, slaveShoppingCartRepo, masterShoppingCartItemRepo);
    }

    @Test
    void addItem_usesAtomicUpsertsOnMaster_only() {
        ShoppingCartAddRequest request = new ShoppingCartAddRequest();
        request.setProductId("prod-1");
        request.setQuantity(2L);
        request.setPrice(65.0);

        sut.addItem("user-1", request);

        // cart header upserted on master (no slave existence check)
        verify(masterShoppingCartRepo).upsertCart("user-1");

        // item upserted on master with a generated UUID id
        ArgumentCaptor<String> idCaptor = ArgumentCaptor.forClass(String.class);
        verify(masterShoppingCartItemRepo)
                .upsertItem(idCaptor.capture(), eq("user-1"), eq("prod-1"), eq(2L), eq(65.0));
        assertDoesNotThrow(() -> java.util.UUID.fromString(idCaptor.getValue()));

        // the old read-merge-write path is gone
        verifyNoMoreInteractions(masterShoppingCartItemRepo, masterShoppingCartRepo);
        verifyNoInteractions(slaveShoppingCartRepo);
    }
}
```

(If `ShoppingCartAddRequest` has no setters/builder mismatch, adapt construction to its actual API — it's a Lombok DTO with `productId`, `quantity`, `price` per the log output `ShoppingCartAddRequest(productId=..., quantity=1, price=65.0)`.)

- [ ] **Step 1.2: Run to verify it fails (compile error — methods don't exist):**
```bash
cd order-service && mvn -q test -Dtest=ShoppingCartServiceTest
```
Expected: COMPILATION ERROR on `upsertCart` / `upsertItem` / 3-arg constructor.

- [ ] **Step 1.3: Implement repo upserts.** In `MasterShoppingCartItemRepo` add (keep the existing `updateItem`):

```java
@Modifying
@Query(value = """
        INSERT INTO shopping_cart_item (id, shopping_cart_id, product_id, quantity, price)
        VALUES (:id, :cartId, :productId, :quantity, :price) AS new
        ON DUPLICATE KEY UPDATE quantity = shopping_cart_item.quantity + new.quantity,
                                price = new.price
        """, nativeQuery = true)
void upsertItem(String id, String cartId, String productId, Long quantity, Double price);
```

In `MasterShoppingCartRepo` add:

```java
@Modifying
@Query(value = """
        INSERT INTO shopping_cart (user_id, created_at, updated_at)
        VALUES (:userId, NOW(6), NOW(6))
        ON DUPLICATE KEY UPDATE updated_at = NOW(6)
        """, nativeQuery = true)
void upsertCart(String userId);
```

(MySQL 8.0.19+ `VALUES ... AS new` alias syntax — avoids the deprecated `VALUES()` function. `shopping_cart.user_id` is the PK, so the header upsert needs no new constraint.)

- [ ] **Step 1.4: Rewrite `ShoppingCartServiceImpl.addItem`** (lines 33–59) and drop the slave-item repo:

```java
@Override
@Transactional
public void addItem(String userId, ShoppingCartAddRequest request) {
    log.info("(addItem)userId: {} request: {}", userId, request);

    // Atomic upserts on the MASTER. The old check-then-insert read the slave,
    // which lags under load (15s observed) — concurrent adds both saw "absent"
    // and inserted duplicates. The unique key on (shopping_cart_id, product_id)
    // plus ON DUPLICATE KEY UPDATE makes the merge race-free regardless of lag.
    masterShoppingCartRepo.upsertCart(userId);
    masterShoppingCartItemRepo.upsertItem(
            UUID.randomUUID().toString(),
            userId,
            request.getProductId(),
            request.getQuantity(),
            request.getPrice());
}
```

Remove the `slaveShoppingCartItemRepo` field, its constructor parameter, and its import; add `import java.util.UUID;`. Then:
- `OrderServiceConfiguration.java`: drop the `SlaveShoppingCartItemRepo` parameter from the `shoppingCartService(...)` `@Bean` method (3-arg `new ShoppingCartServiceImpl(...)`).
- Delete `repository/slave/SlaveShoppingCartItemRepo.java`.

- [ ] **Step 1.5: Run tests:**
```bash
cd order-service && mvn -q test -Dtest=ShoppingCartServiceTest && mvn -q test
```
Expected: PASS (full module test run guards the other order tests).

- [ ] **Step 1.6: Commit:**
```bash
git add order-service/
git commit -m "fix(order): race-free cart add via atomic ON DUPLICATE KEY upsert on master"
```

---

### Task 2: Cart — unique constraint (entity + migration SQL)

**Files:**
- Modify: `order-service/src/main/java/org/aibles/order_service/entity/ShoppingCartItem.java`
- Create: `order-service/src/main/resources/db/migration/V2__shopping_cart_item_dedup_unique.sql`

- [ ] **Step 2.1:** Add the unique constraint to the entity (fresh environments get it via `ddl-auto: update` at table-create time):

```java
@Table(uniqueConstraints = @UniqueConstraint(
        name = "uq_cart_product",
        columnNames = {"shopping_cart_id", "product_id"}))
```
on the `ShoppingCartItem` class (add `jakarta.persistence.Table`/`UniqueConstraint` imports).

- [ ] **Step 2.2:** Create the migration SQL — Hibernate `update` does NOT add constraints to existing tables, so the live DB gets this applied manually in Task 7. Dedup must run first (the table currently HAS duplicates) or the ALTER fails:

```sql
-- V2: dedup shopping_cart_item and enforce one row per (cart, product).
-- Context: docs/performance-stress-report-2026-06-10.md problem P1.
-- 1) Merge duplicate quantities into the keeper row (lowest id), latest price wins is
--    not reconstructible post-hoc, keeper's price is kept.
UPDATE shopping_cart_item sci
JOIN (
    SELECT shopping_cart_id, product_id, MIN(id) AS keep_id, SUM(quantity) AS total_qty
    FROM shopping_cart_item
    GROUP BY shopping_cart_id, product_id
    HAVING COUNT(*) > 1
) d ON sci.id = d.keep_id
SET sci.quantity = d.total_qty;

-- 2) Drop the non-keeper duplicates.
DELETE sci FROM shopping_cart_item sci
JOIN (
    SELECT shopping_cart_id, product_id, MIN(id) AS keep_id
    FROM shopping_cart_item
    GROUP BY shopping_cart_id, product_id
    HAVING COUNT(*) > 1
) d ON sci.shopping_cart_id = d.shopping_cart_id
   AND sci.product_id = d.product_id
   AND sci.id <> d.keep_id;

-- 3) Enforce.
ALTER TABLE shopping_cart_item
    ADD UNIQUE KEY uq_cart_product (shopping_cart_id, product_id);
```

- [ ] **Step 2.3:** Compile check + commit:
```bash
cd order-service && mvn -q compile
git add order-service/
git commit -m "fix(order): unique key (shopping_cart_id, product_id) + dedup migration"
```

---

### Task 3: Payment — call-then-record (TDD)

**Files:**
- Test (create): `payment-service/src/test/java/org/aibles/payment_service/service/PaymentServiceImplTest.java`
- Test (create): `payment-service/src/test/java/org/aibles/payment_service/service/TransactionBoundaryTest.java`
- Create: `payment-service/src/main/java/org/aibles/payment_service/service/PaymentRecorder.java`
- Modify: `payment-service/src/main/java/org/aibles/payment_service/service/PaymentServiceImpl.java`
- Modify: `payment-service/src/main/java/org/aibles/payment_service/configuration/PaymentServiceConfiguration.java`

- [ ] **Step 3.1:** payment-service has **no `src/test` at all**. Check `payment-service/pom.xml` for `spring-boot-starter-test`; if absent add:
```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-test</artifactId>
    <scope>test</scope>
</dependency>
```

- [ ] **Step 3.2: Write the failing tests.**

`TransactionBoundaryTest.java` — the regression guard that encodes the whole point of this fix:

```java
package org.aibles.payment_service.service;

import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Guards the call-then-record boundary: PayPal HTTP calls live in
 * PaymentServiceImpl and must NOT run inside a JTA transaction (Atomikos
 * maxActives=50 saturated when ~1.3s HTTP calls held tx slots — see
 * docs/performance-stress-report-2026-06-10.md P2). All DB writes live in
 * PaymentRecorder behind short @Transactional methods.
 */
class TransactionBoundaryTest {

    @Test
    void paymentServiceImpl_hasNoTransactionalMethods() {
        for (Method m : PaymentServiceImpl.class.getDeclaredMethods()) {
            assertNull(m.getAnnotation(Transactional.class),
                    "PaymentServiceImpl." + m.getName() + " must not be @Transactional"
                    + " (it performs HTTP I/O); writes belong in PaymentRecorder");
        }
        assertNull(PaymentServiceImpl.class.getAnnotation(Transactional.class));
    }

    @Test
    void paymentRecorder_writeMethodsAreTransactional() {
        Set<String> writeMethods = Set.of("recordPurchase", "recordSuccess", "recordCancel", "recordFailure");
        for (Method m : PaymentRecorder.class.getDeclaredMethods()) {
            if (writeMethods.contains(m.getName())) {
                assertNotNull(m.getAnnotation(Transactional.class),
                        "PaymentRecorder." + m.getName() + " must be @Transactional");
            }
        }
    }
}
```

`PaymentServiceImplTest.java` — orchestration behavior with mocks:

```java
package org.aibles.payment_service.service;

import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalCaptureResponse;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderDetail;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderSimple;
import org.aibles.ecommerce.core_paypal.service.PaypalService;
import org.aibles.payment_service.entity.Payment;
import org.aibles.payment_service.repository.master.MasterPaymentRepo;
import org.aibles.payment_service.repository.slave.SlavePaymentRepo;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class PaymentServiceImplTest {

    private PaypalService paypalService;
    private PendingOrderCacheRepository pendingOrderCacheRepository;
    private MasterPaymentRepo masterPaymentRepo;
    private SlavePaymentRepo slavePaymentRepo;
    private PaymentRecorder paymentRecorder;
    private PaymentService sut;

    @BeforeEach
    void setUp() {
        paypalService = mock(PaypalService.class);
        pendingOrderCacheRepository = mock(PendingOrderCacheRepository.class);
        masterPaymentRepo = mock(MasterPaymentRepo.class);
        slavePaymentRepo = mock(SlavePaymentRepo.class);
        paymentRecorder = mock(PaymentRecorder.class);
        sut = new PaymentServiceImpl(paypalService, pendingOrderCacheRepository,
                masterPaymentRepo, slavePaymentRepo, paymentRecorder);
    }

    @Test
    void purchase_callsPaypalThenRecords() {
        when(pendingOrderCacheRepository.getOrderPrice("o-1")).thenReturn(Optional.of(99.0));
        PaypalOrderSimple order = new PaypalOrderSimple();
        order.setId("tok-1");
        when(paypalService.createOrder(anyList())).thenReturn(order);

        sut.purchase("o-1");

        var inOrder = inOrder(paypalService, paymentRecorder);
        inOrder.verify(paypalService).createOrder(anyList());
        inOrder.verify(paymentRecorder).recordPurchase("o-1", 99.0, "tok-1");
        verifyNoInteractions(masterPaymentRepo); // impl no longer writes directly
    }

    @Test
    void handleSuccessPayment_capturesThenRecordsSuccess() {
        PaypalCaptureResponse capture = mock(PaypalCaptureResponse.class, RETURNS_DEEP_STUBS);
        when(capture.getPurchaseUnits().get(0).getPayments().getCaptures().get(0).getId())
                .thenReturn("cap-1");
        when(paypalService.captureOrder("tok-1")).thenReturn(capture);
        PaypalOrderDetail detail = mock(PaypalOrderDetail.class, RETURNS_DEEP_STUBS);
        when(detail.getPurchaseUnits().get(0).getCustomId()).thenReturn("o-1");
        when(paypalService.getOrderDetails("tok-1")).thenReturn(detail);
        when(masterPaymentRepo.findByOrderId("o-1"))
                .thenReturn(Optional.of(Payment.builder().orderId("o-1").build()));

        String orderId = sut.handleSuccessPayment("tok-1");

        assertEquals("o-1", orderId);
        verify(paymentRecorder).recordSuccess("o-1", "cap-1");
    }
}
```

(Adjust DTO construction to actual Lombok APIs if a setter differs; deep stubs avoid hand-building the nested PayPal DTOs.)

- [ ] **Step 3.3: Run to verify failure:**
```bash
cd payment-service && mvn -q test
```
Expected: COMPILATION ERROR (`PaymentRecorder` doesn't exist, constructor mismatch).

- [ ] **Step 3.4: Create `PaymentRecorder`** — all DB writes + their event publications move here verbatim from `PaymentServiceImpl` (events stay inside the tx, same as before):

```java
package org.aibles.payment_service.service;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentFailed;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentSuccess;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.payment_service.constant.PaymentStatus;
import org.aibles.payment_service.constant.PaymentType;
import org.aibles.payment_service.entity.Payment;
import org.aibles.payment_service.repository.master.MasterPaymentRepo;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.transaction.annotation.Transactional;

/**
 * Short transactional writes for the payment lifecycle. Lives in its own bean
 * (not PaymentServiceImpl) so @Transactional applies through the Spring proxy —
 * and so no PayPal HTTP call can ever run inside a JTA transaction again
 * (Atomikos maxActives saturation, stress run 2026-06-10).
 */
@Slf4j
public class PaymentRecorder {

    private final MasterPaymentRepo masterPaymentRepo;
    private final ApplicationEventPublisher eventPublisher;

    public PaymentRecorder(MasterPaymentRepo masterPaymentRepo, ApplicationEventPublisher eventPublisher) {
        this.masterPaymentRepo = masterPaymentRepo;
        this.eventPublisher = eventPublisher;
    }

    @Transactional
    public void recordPurchase(String orderId, double totalPrice, String paypalToken) {
        // Upsert: reuse the existing Payment row for this order if one exists (the
        // user cancelled a prior attempt and is retrying). The whole lifecycle
        // assumes ONE Payment per order. Master read for read-your-writes.
        Payment payment = masterPaymentRepo.findByOrderId(orderId)
                .map(existing -> {
                    existing.setType(PaymentType.PURCHASE);
                    existing.setStatus(PaymentStatus.PROCESSING);
                    existing.setToken(paypalToken);
                    existing.setTotalPrice(totalPrice);
                    existing.setCaptureId(null);
                    return existing;
                })
                .orElseGet(() -> Payment.builder()
                        .type(PaymentType.PURCHASE)
                        .orderId(orderId)
                        .status(PaymentStatus.PROCESSING)
                        .token(paypalToken)
                        .totalPrice(totalPrice)
                        .build());
        masterPaymentRepo.save(payment);
    }

    @Transactional
    public void recordSuccess(String orderId, String captureId) {
        masterPaymentRepo.markSuccess(orderId, PaymentStatus.SUCCESS, captureId);
        eventPublisher.publishEvent(new MongoSavedEvent(this,
                EcommerceEvent.PAYMENT_SUCCESS.getValue(),
                PaymentSuccess.newBuilder().setOrderId(orderId).build()));
    }

    @Transactional
    public void recordCancel(String orderId) {
        masterPaymentRepo.updateStatus(orderId, PaymentStatus.CANCELED);
        eventPublisher.publishEvent(new MongoSavedEvent(this,
                EcommerceEvent.PAYMENT_CANCELED.getValue(),
                PaymentCanceled.newBuilder().setOrderId(orderId).build()));
    }

    @Transactional
    public void recordFailure(String orderId) {
        masterPaymentRepo.updateStatus(orderId, PaymentStatus.FAILED);
        eventPublisher.publishEvent(new MongoSavedEvent(this,
                EcommerceEvent.PAYMENT_FAILED.getValue(),
                PaymentFailed.newBuilder().setOrderId(orderId).build()));
    }
}
```

- [ ] **Step 3.5: Refactor `PaymentServiceImpl`.** Remove `@Transactional` from `purchase`, `handleSuccessPayment`, `handleCancelPayment`; replace `eventPublisher` + write-paths with `paymentRecorder` calls. Constructor becomes `(PaypalService, PendingOrderCacheRepository, MasterPaymentRepo, SlavePaymentRepo, PaymentRecorder)` — `ApplicationEventPublisher` moves to the recorder; `masterPaymentRepo` stays for the `findByToken`/`findByOrderId` reads (Spring Data wraps each repo call in its own short tx). The method bodies keep their current control flow exactly; the substitutions are:

  - `purchase`: catch-block body → `paymentRecorder.recordFailure(orderId); return BaseResponse.from(e.getStatus(), e.getCode(), e.getMessage());` · lines 90–107 (upsert + save) → `paymentRecorder.recordPurchase(orderId, totalPrice, paypalOrderSimple.getId());`
  - `handleSuccessPayment`: the two `handleFailedPayment(...)` error paths → `paymentRecorder.recordFailure(...)` · `markSuccess` + `PaymentSuccess` event block → `paymentRecorder.recordSuccess(payment.getOrderId(), captureId);`
  - `handleCancelPayment`: error paths → `paymentRecorder.recordFailure(...)` · `updateStatus(CANCELED)` + event block → `paymentRecorder.recordCancel(orderId);`
  - Delete the now-empty private `handleFailedPayment` and unused imports (`Transactional` stays imported only if still used — it won't be; remove it so the boundary test reads clean).

- [ ] **Step 3.6: Wire the bean.** In `PaymentServiceConfiguration`:

```java
@Bean
public PaymentRecorder paymentRecorder(MasterPaymentRepo masterPaymentRepo,
                                       ApplicationEventPublisher eventPublisher) {
    return new PaymentRecorder(masterPaymentRepo, eventPublisher);
}

@Bean
public PaymentService paymentService(PaypalService paypalService,
                                     PendingOrderCacheRepository pendingOrderCacheRepository,
                                     MasterPaymentRepo masterPaymentRepo,
                                     SlavePaymentRepo slavePaymentRepo,
                                     PaymentRecorder paymentRecorder) {
    return new PaymentServiceImpl(paypalService, pendingOrderCacheRepository,
            masterPaymentRepo, slavePaymentRepo, paymentRecorder);
}
```

- [ ] **Step 3.7: Run tests:**
```bash
cd payment-service && mvn -q test
```
Expected: PASS (both test classes).

- [ ] **Step 3.8: Commit:**
```bash
git add payment-service/
git commit -m "fix(payment): call-then-record — PayPal HTTP leaves the JTA transaction"
```

---

### Task 4: PayPal timeouts + Atomikos headroom

**Files:**
- Modify: `core/core-paypal/src/main/java/org/aibles/ecommerce/core_paypal/configuration/PaypalRestTemplateConfiguration.java`
- Modify: `payment-service/src/main/resources/transactions.properties`

- [ ] **Step 4.1:** The PayPal `RestTemplate` currently has **no timeouts** (JDK default = infinite; a stalled PayPal call parks a Tomcat thread forever). Add:

```java
@Bean
public RestTemplate paypalRestTemplate() {
    SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
    requestFactory.setConnectTimeout(3_000);
    requestFactory.setReadTimeout(10_000);
    RestTemplate restTemplate = new RestTemplate(requestFactory);
    restTemplate.setErrorHandler(errorHandler);
    return restTemplate;
}
```
(Timeout failures surface as `ResourceAccessException` — confirm the existing `PaypalRestTemplateException` error-handler path still produces the `PaymentFailed` flow; the `purchase` catch clause may need `ResourceAccessException` added or a try/catch widened to `RestClientException`. Check `PaypalServiceImpl`'s exception translation while in there and keep the catch types consistent.)

- [ ] **Step 4.2:** Stopgap tx headroom — `payment-service/src/main/resources/transactions.properties` (Atomikos reads this from the classpath since the tx manager is manually constructed):

```properties
com.atomikos.icatch.log_base_name = payment-service
com.atomikos.icatch.max_actives = 200
```

- [ ] **Step 4.3:** Build both modules, commit:
```bash
cd core/core-paypal && mvn -q install -DskipTests && cd ../../payment-service && mvn -q test
git add core/core-paypal/ payment-service/
git commit -m "fix(paypal): RestTemplate timeouts (3s/10s); raise Atomikos max_actives to 200"
```

---

### Task 5: Infra config — replication tuning + headroom

**Files:**
- Modify: `k8s/infra/manifests/mysql.yaml` (primary args)
- Modify: `k8s/infra/manifests/mysql-replica.yaml` (worker count)
- Modify: `k8s/infra/manifests/mongodb.yaml` (CPU limit, `mongodb` container ~line 121)

- [ ] **Step 5.1:** Primary `args` — add (parity with `docker/mysql.yml`, which already has all of these; WRITESET dependency tracking is what lets the replicas' `LOGICAL_CLOCK` workers actually parallelize):
```yaml
- --max-connections=300
- --binlog-transaction-dependency-tracking=WRITESET
- --transaction-write-set-extraction=XXHASH64
- --binlog-group-commit-sync-delay=1000
- --binlog-group-commit-sync-no-delay-count=10
```

- [ ] **Step 5.2:** Replica `args` — `--replica-parallel-workers=4` → `--replica-parallel-workers=8` (docker parity).

- [ ] **Step 5.3:** `mongodb.yaml` `mongodb` container: `limits.cpu: 800m` → `1500m` (throttled ~12% during the run; it's on the saga CDC path — the 33 unsettled flows).

- [ ] **Step 5.4: Commit:**
```bash
git add k8s/infra/manifests/
git commit -m "perf(infra): WRITESET binlog tracking + 8 replica workers, max_connections=300, mongo CPU 1.5"
```

---

### Task 6: Build & deploy to the kind cluster

Code changed in `core/core-paypal` ⇒ the cores image MUST be rebuilt first (`make k8s-rebuild` uses `SKIP_CORES=1` and would bake stale core JARs — known trap).

- [ ] **Step 6.1:** Rebuild cores, then the two services:
```bash
SVC=cores k8s/images/build.sh
make k8s-rebuild svc=order-service
make k8s-rebuild svc=payment-service
```
- [ ] **Step 6.2:** Apply infra (idempotent; restarts MySQL pods with new args — replication re-verifies itself in install.sh):
```bash
make k8s-infra
```
- [ ] **Step 6.3:** Wait for everything healthy:
```bash
kubectl -n infra get pods -w   # mysql-0, mysql-replica-0/1, mongodb-0 back to Running/Ready
kubectl -n apps get pods       # order-service, payment-service new ReplicaSets Ready
```
Verify replication after the MySQL restarts:
```bash
kubectl -n infra exec mysql-replica-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"' | grep -E "Replica_(IO|SQL)_Running|Seconds_Behind"
```
Expected: both `Yes`, `Seconds_Behind_Source: 0`.

---

### Task 7: Apply the dedup + unique key to the live DB

The running `ecommerce_dev` still holds the corrupted duplicate rows; Hibernate won't add the constraint to an existing table.

- [ ] **Step 7.1:** Apply `V2__shopping_cart_item_dedup_unique.sql` against the primary (this `kubectl exec` into MySQL needs user approval — it was auto-denied in read-only analysis earlier):
```bash
kubectl -n infra exec -i mysql-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" ecommerce_dev' \
  < order-service/src/main/resources/db/migration/V2__shopping_cart_item_dedup_unique.sql
```
- [ ] **Step 7.2:** Verify:
```bash
kubectl -n infra exec mysql-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" ecommerce_dev -e \
  "SELECT COUNT(*) AS dups FROM (SELECT 1 FROM shopping_cart_item GROUP BY shopping_cart_id, product_id HAVING COUNT(*)>1) d; SHOW INDEX FROM shopping_cart_item WHERE Key_name=\"uq_cart_product\";"'
```
Expected: `dups = 0` and the index listed.

---

### Task 8: Verify end-to-end

- [ ] **Step 8.1 — functional smoke (cart merge):** through the gateway (`http://localhost:8080` or the ingress), login as a seeded user, `POST /order-service/v1/shopping-carts:add-item` twice with the same product (`quantity: 1` each), then `GET` the cart. Expected: **one** line with `quantity: 2` — and a third add must not 500.
- [ ] **Step 8.2 — payment flow smoke:** run one full order→pay round through mock-paypal (decision=approve). Expected: 201 order, payment SUCCESS, no errors in `kubectl -n apps logs deploy/payment-service`.
- [ ] **Step 8.3 — k6 stress re-run** (same profile as the 2026-06-10 run):
```bash
make k8s-storefront-stress
make k8s-storefront-logs
```
Pass criteria vs the baseline report:
  - `cart 200` check: **100%** (was 98%, 279 failures) — zero `NonUniqueResultException` in order-service logs
  - `payment 200` / `has links`: **100%** (was 75 failures) — zero `Max number of active transactions` in payment-service logs
  - replica lag during peak: `max_over_time(mysql_slave_status_seconds_behind_master[15m])` **≤ 2s** (was 15s) via vmsingle (`kubectl -n monitoring port-forward svc/vmsingle 18428:8428`)
  - payment p95 at peak: < 500ms (was 957ms; the tx no longer queues behind PayPal)
  - `flow settled`: 100% (was 33 failures) — confirms the Mongo CPU bump
- [ ] **Step 8.4 — close out:** append a short "Fixes applied + re-run results" section to `docs/performance-stress-report-2026-06-10.md` with the new k6 numbers; commit:
```bash
git add docs/performance-stress-report-2026-06-10.md
git commit -m "docs: stress report addendum — fixes verified by re-run"
```
Then offer the user a PR (user-triggered per repo convention).

---

## Out of scope (documented, deliberately skipped)

- **Replica round-robin imbalance** (515 vs 794 QPS): per-JVM `AtomicInteger` in `SlaveDatasourceRouting` with no cross-pod coordination — harmless at current load; revisit if a replica saturates.
- **vmalert/alerting for replication lag**: no alerting stack exists at all; adding one is its own project. The lag panel already exists in `k8s/infra/dashboards/mysql.json`.
- **Gateway GC profile**: symptom of the payment tail; expected to improve via Task 3. Re-check allocation/promotion in the Task 8 re-run before considering a heap bump.

## Self-review notes

- Spec coverage: P1 → Tasks 1/2/7 · P2 → Tasks 3/4 · P3 → Task 5 · watch items (Mongo CPU, max_connections) → Task 5 · verification → Task 8. Replica imbalance + alerting explicitly out-of-scope.
- Type consistency: `PaymentRecorder` method names match between Task 3 code, tests, and impl substitutions; cart repo methods `upsertCart`/`upsertItem` consistent between test and impl.
- Known flex points called out inline: DTO setter shapes in tests, `ResourceAccessException` handling in Step 4.1.
