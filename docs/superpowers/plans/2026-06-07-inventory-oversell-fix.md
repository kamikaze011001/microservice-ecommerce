# Inventory Oversell Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the stock-oversell race so `SUM(product_quantity_history)` for any product can never go negative under concurrent load — proven by the `k8s/apps/base/k6-stress/oversell-boundary-flow.js` boundary test returning `final_stock = 0` instead of `-1`.

**Architecture:** Two independent layers. Layer 1 (primary fix): replace the snapshot-based `QUEUE_PRODUCT_KEY` reserved-counter with a new `AVAILABLE_PRODUCT_KEY` counter that the Lua script checks and decrements atomically — no external snapshot, no TOCTOU. Layer 2 (DB floor): add a materialized `stock` column to `inventory_product` and use an atomic conditional `UPDATE … WHERE stock >= :n` at payment-success commit so the DB cannot go negative either. On boot, the seeder derives `available:{pid}` from `stock` for Redis recovery.

**Tech Stack:** Spring Boot 3.3.6, Spring Data Redis, Redis Lua scripting (`DECRBY`), Flyway (existing V1 migration pattern), JPA `@Modifying @Query`, Mockito (unit tests — no embedded infra required in CI), k6 (boundary regression in k8s).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `core/core-redis/src/main/java/org/aibles/ecommerce/core_redis/constant/RedisConstant.java` | Modify | Add `AVAILABLE_PRODUCT_KEY = "productAvailable:"` constant |
| `core/core-order-cache/src/main/java/org/aibles/ecommerce/core_order_cache/repository/PendingOrderCacheRepository.java` | Modify | Add `checkAndReserveAvailableAtomic` method signature |
| `core/core-order-cache/src/main/java/org/aibles/ecommerce/core_order_cache/repository/impl/PendingOrderCacheRepositoryImpl.java` | Modify | Add `CHECK_AND_RESERVE_AVAILABLE_LUA_SCRIPT` + `checkAndReserveAvailableAtomic` impl |
| `core/core-order-cache/src/test/java/org/aibles/ecommerce/core_order_cache/repository/impl/CheckAndReserveAvailableAtomicTest.java` | Create | Unit tests for the new Lua method |
| `inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/entity/InventoryProduct.java` | Modify | Add `private Long stock = 0L;` field |
| `inventory-service/src/main/resources/db/migration/V2__add_stock_to_inventory_product.sql` | Create | Flyway migration: add `stock` column, backfill from ledger |
| `inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/repository/master/MasterInventoryProductRepository.java` | Modify | Add `decrementStockIfSufficient` (conditional floor) + `adjustStock` (admin) |
| `inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/configuration/AvailableStockSeeder.java` | Create | `ApplicationRunner` that seeds `available:{pid}` from `inventory_product.stock` on boot |
| `inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/configuration/InventoryServiceConfiguration.java` | Modify | Add `@Bean AvailableStockSeeder availableStockSeeder(...)` |
| `inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/service/InventoryServiceImpl.java` | Modify | `processInventoryUpdate`: remove Redis `decr`, add DB conditional floor; `list()`: revert to slave read; `update()`: sync `stock` + `available` |
| `inventory-service/src/test/java/org/aibles/ecommerce/inventory_service/configuration/AvailableStockSeederTest.java` | Create | Unit tests for the seeder |
| `inventory-service/src/test/java/org/aibles/ecommerce/inventory_service/service/InventoryCommitPathTest.java` | Create | Unit tests for the new commit path (no Redis decr, DB floor called) |
| `order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java` | Modify | Reserve: call `checkAndReserveAvailableAtomic`; rollback + cancel/fail: `incr(AVAILABLE_PRODUCT_KEY...)` |
| `order-service/src/test/java/org/aibles/order_service/service/OrderReserveAvailableTest.java` | Create | Unit tests verifying new reserve + rollback paths |
| `order-service/src/main/java/org/aibles/order_service/scheduler/ExpiredOrderCleanupJob.java` | Modify | `rollbackProductReservations`: `decr(QUEUE_PRODUCT_KEY...)` → `incr(AVAILABLE_PRODUCT_KEY...)` |
| `order-service/src/test/java/org/aibles/order_service/scheduler/ExpiredOrderCleanupJobTest.java` | Create | Unit tests for cleanup job release path |

---

## Task 1: Add `AVAILABLE_PRODUCT_KEY` constant to `core-redis`

**Files:**
- Modify: `core/core-redis/src/main/java/org/aibles/ecommerce/core_redis/constant/RedisConstant.java`

- [ ] **Step 1: Write a failing test asserting the constant exists and has the correct value**

Create `core/core-redis/src/test/java/org/aibles/ecommerce/core_redis/constant/RedisConstantTest.java`:

```java
package org.aibles.ecommerce.core_redis.constant;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class RedisConstantTest {

    @Test
    void availableProductKey_hasCorrectPrefix() {
        assertThat(RedisConstant.AVAILABLE_PRODUCT_KEY).isEqualTo("productAvailable:");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /path/to/microservice-ecommerce/core/core-redis
mvn test -Dtest=RedisConstantTest -q
```

Expected: FAIL with `NoSuchFieldError` or compilation error.

- [ ] **Step 3: Add the constant**

Open `core/core-redis/src/main/java/org/aibles/ecommerce/core_redis/constant/RedisConstant.java` and add the new constant:

```java
package org.aibles.ecommerce.core_redis.constant;

public class RedisConstant {

    private RedisConstant() {}

    public static final String QUEUE_PRODUCT_KEY = "productQuantityQueue:";

    public static final String LOCK_QUEUE_PRODUCT_KEY = "lock:productQueue:";

    public static final String AVAILABLE_PRODUCT_KEY = "productAvailable:";
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mvn test -Dtest=RedisConstantTest -q
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/core-redis/src/main/java/org/aibles/ecommerce/core_redis/constant/RedisConstant.java \
        core/core-redis/src/test/java/org/aibles/ecommerce/core_redis/constant/RedisConstantTest.java
git commit -m "feat(core-redis): add AVAILABLE_PRODUCT_KEY constant for available-stock counter"
```

---

## Task 2: Add new Lua `checkAndReserveAvailableAtomic` to `core-order-cache`

**Files:**
- Modify: `core/core-order-cache/src/main/java/org/aibles/ecommerce/core_order_cache/repository/PendingOrderCacheRepository.java`
- Modify: `core/core-order-cache/src/main/java/org/aibles/ecommerce/core_order_cache/repository/impl/PendingOrderCacheRepositoryImpl.java`
- Create: `core/core-order-cache/src/test/java/org/aibles/ecommerce/core_order_cache/repository/impl/CheckAndReserveAvailableAtomicTest.java`

- [ ] **Step 1: Write the failing tests**

Create the test class (the `src/test/java` directory needs to be created if it doesn't exist):

```java
package org.aibles.ecommerce.core_order_cache.repository.impl;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.connection.RedisConnection;
import org.springframework.data.redis.connection.RedisScriptingCommands;
import org.springframework.data.redis.connection.ReturnType;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.RedisTemplate;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class CheckAndReserveAvailableAtomicTest {

    private RedisTemplate<String, Object> redisTemplate;
    private PendingOrderCacheRepositoryImpl repo;

    @BeforeEach
    void setUp() {
        redisTemplate = mock(RedisTemplate.class);
        ObjectMapper objectMapper = new ObjectMapper();
        repo = new PendingOrderCacheRepositoryImpl(redisTemplate, objectMapper);
    }

    @Test
    void emptyProductQuantities_returnsTrue_withoutCallingRedis() {
        boolean result = repo.checkAndReserveAvailableAtomic("productAvailable:", Map.of());

        assertThat(result).isTrue();
        verify(redisTemplate, never()).execute(any(RedisCallback.class));
    }

    @Test
    void luaReturns1_returnsTrue() {
        RedisScriptingCommands scriptingCommands = mock(RedisScriptingCommands.class);
        when(scriptingCommands.eval(any(byte[].class), eq(ReturnType.INTEGER), eq(0), any(byte[][].class)))
                .thenReturn(1L);

        RedisConnection connection = mock(RedisConnection.class);
        when(connection.scriptingCommands()).thenReturn(scriptingCommands);

        when(redisTemplate.execute(any(RedisCallback.class))).thenAnswer(inv -> {
            RedisCallback<?> cb = inv.getArgument(0);
            return cb.doInRedis(connection);
        });

        Map<String, Long> quantities = new LinkedHashMap<>();
        quantities.put("prod-1", 3L);

        boolean result = repo.checkAndReserveAvailableAtomic("productAvailable:", quantities);

        assertThat(result).isTrue();
    }

    @Test
    void luaReturns0_returnsFalse() {
        RedisScriptingCommands scriptingCommands = mock(RedisScriptingCommands.class);
        when(scriptingCommands.eval(any(byte[].class), eq(ReturnType.INTEGER), eq(0), any(byte[][].class)))
                .thenReturn(0L);

        RedisConnection connection = mock(RedisConnection.class);
        when(connection.scriptingCommands()).thenReturn(scriptingCommands);

        when(redisTemplate.execute(any(RedisCallback.class))).thenAnswer(inv -> {
            RedisCallback<?> cb = inv.getArgument(0);
            return cb.doInRedis(connection);
        });

        Map<String, Long> quantities = Map.of("prod-1", 5L);

        boolean result = repo.checkAndReserveAvailableAtomic("productAvailable:", quantities);

        assertThat(result).isFalse();
    }

    @Test
    void luaReturnsNull_returnsFalse() {
        when(redisTemplate.execute(any(RedisCallback.class))).thenReturn(null);

        boolean result = repo.checkAndReserveAvailableAtomic("productAvailable:", Map.of("prod-1", 1L));

        assertThat(result).isFalse();
    }

    @Test
    void redisThrowsException_returnsFalse() {
        when(redisTemplate.execute(any(RedisCallback.class)))
                .thenThrow(new RuntimeException("Redis connection refused"));

        boolean result = repo.checkAndReserveAvailableAtomic("productAvailable:", Map.of("prod-1", 1L));

        assertThat(result).isFalse();
    }

    @Test
    void luaScript_containsGuardAgainstNegative() {
        // Verify the Lua script checks `available < quantities[i]` before decrementing.
        // This is the critical safety property: the script must reject if insufficient stock.
        String scriptField = captureScript();

        assertThat(scriptField).contains("available < quantities[i]");
        assertThat(scriptField).contains("DECRBY");
        assertThat(scriptField).doesNotContain("INCRBY"); // must not increment
    }

    @Test
    void multipleProducts_argsEncodedInCorrectOrder() {
        RedisScriptingCommands scriptingCommands = mock(RedisScriptingCommands.class);
        when(scriptingCommands.eval(any(byte[].class), eq(ReturnType.INTEGER), eq(0), any(byte[][].class)))
                .thenReturn(1L);

        RedisConnection connection = mock(RedisConnection.class);
        when(connection.scriptingCommands()).thenReturn(scriptingCommands);

        when(redisTemplate.execute(any(RedisCallback.class))).thenAnswer(inv -> {
            RedisCallback<?> cb = inv.getArgument(0);
            return cb.doInRedis(connection);
        });

        // LinkedHashMap preserves insertion order → deterministic arg positions
        Map<String, Long> quantities = new LinkedHashMap<>();
        quantities.put("prod-A", 2L);
        quantities.put("prod-B", 5L);

        repo.checkAndReserveAvailableAtomic("productAvailable:", quantities);

        // Capture the byte[][] args passed to eval
        org.mockito.ArgumentCaptor<byte[][]> argsCaptor =
                org.mockito.ArgumentCaptor.forClass(byte[][].class);
        verify(scriptingCommands).eval(any(byte[].class), eq(ReturnType.INTEGER), eq(0), argsCaptor.capture());

        byte[][] argBytes = argsCaptor.getValue();
        // ARGV[1] = keyPrefix, ARGV[2] = numProducts, ARGV[3..4] = productIds, ARGV[5..6] = quantities
        assertThat(new String(argBytes[0])).isEqualTo("productAvailable:");
        assertThat(new String(argBytes[1])).isEqualTo("2");
        // productIds first
        assertThat(new String(argBytes[2])).isEqualTo("prod-A");
        assertThat(new String(argBytes[3])).isEqualTo("prod-B");
        // quantities second
        assertThat(new String(argBytes[4])).isEqualTo("2");
        assertThat(new String(argBytes[5])).isEqualTo("5");
    }

    /** Reads the private script field via reflection for the Lua content assertion. */
    private String captureScript() {
        try {
            java.lang.reflect.Field f = PendingOrderCacheRepositoryImpl.class
                    .getDeclaredField("CHECK_AND_RESERVE_AVAILABLE_LUA_SCRIPT");
            f.setAccessible(true);
            return (String) f.get(null);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /path/to/microservice-ecommerce/core/core-order-cache
mvn test -Dtest=CheckAndReserveAvailableAtomicTest -q
```

Expected: FAIL — `checkAndReserveAvailableAtomic` method does not exist yet.

- [ ] **Step 3: Add the method signature to the interface**

Open `core/core-order-cache/src/main/java/org/aibles/ecommerce/core_order_cache/repository/PendingOrderCacheRepository.java` and add the new method (keep the existing `checkAndReserveAtomic` unchanged):

```java
package org.aibles.ecommerce.core_order_cache.repository;

import java.util.Map;
import java.util.Optional;

public interface PendingOrderCacheRepository {

    /**
     * Atomically checks available inventory and reserves products if sufficient quantity exists.
     * This operation uses a Lua script to ensure atomicity and prevent race conditions.
     *
     * @param keyPrefix The prefix for Redis keys (e.g., "queue:product:")
     * @param productQuantities Map of product ID to quantity to reserve
     * @param maxInventory Map of product ID to maximum available inventory
     * @return true if all products were successfully reserved, false if any product has insufficient inventory
     */
    boolean checkAndReserveAtomic(String keyPrefix, Map<String, Long> productQuantities, Map<String, Long> maxInventory);

    /**
     * Atomically checks and decrements the `available` counter for each product.
     * The counter itself is the source of truth — no external maxInventory snapshot is needed.
     * All-or-nothing: if any product has available < requested, returns false and nothing is decremented.
     *
     * @param keyPrefix The prefix for Redis keys (e.g., "productAvailable:")
     * @param productQuantities Map of product ID to quantity to reserve
     * @return true if all products were successfully reserved, false if any product has insufficient stock
     */
    boolean checkAndReserveAvailableAtomic(String keyPrefix, Map<String, Long> productQuantities);

    /**
     * Adds an order to the pending orders ZSET for TTL-based cleanup.
     * The order is stored with its expiration timestamp as the score.
     * Stores both order price and product quantities in JSON format.
     *
     * @param orderId Order ID
     * @param orderPrice Total order price
     * @param productQuantities Map of product ID to reserved quantity
     * @param expiryTimestampMillis Expiration timestamp in milliseconds (epoch time)
     */
    void addToPendingOrders(String orderId, double orderPrice, Map<String, Long> productQuantities, long expiryTimestampMillis);

    /**
     * Retrieves all expired orders from the pending orders ZSET.
     * Returns orders with score (expiry timestamp) less than the current timestamp.
     *
     * @param currentTimestampMillis Current timestamp in milliseconds (epoch time)
     * @return Map of order ID to product quantities for expired orders
     */
    Map<String, Map<String, Long>> getExpiredOrders(long currentTimestampMillis);

    /**
     * Removes an order from the pending orders ZSET.
     * Called when an order is successfully paid or explicitly canceled.
     *
     * @param orderId Order ID to remove
     */
    void removeFromPendingOrders(String orderId);

    /**
     * Retrieves the product quantities for a specific order from the pending orders ZSET.
     *
     * @param orderId Order ID
     * @return Optional containing the map of product ID to quantity, or empty if order not found
     */
    Optional<Map<String, Long>> getProductQuantitiesForOrder(String orderId);

    /**
     * Retrieves the order price for a specific order from the pending orders ZSET.
     *
     * @param orderId Order ID
     * @return Optional containing the order price, or empty if order not found
     */
    Optional<Double> getOrderPrice(String orderId);
}
```

- [ ] **Step 4: Add the Lua script constant and `checkAndReserveAvailableAtomic` implementation**

Open `core/core-order-cache/src/main/java/org/aibles/ecommerce/core_order_cache/repository/impl/PendingOrderCacheRepositoryImpl.java` and add the constant and method after the existing `CHECK_AND_RESERVE_LUA_SCRIPT` field and `checkAndReserveAtomic` method. Add these two members to the class (keep all existing members intact):

```java
    /**
     * Lua script for self-contained atomic check-and-reserve of the `available` counter.
     * NO external maxInventory snapshot is accepted — the counter IS the authority.
     *
     * Script logic:
     * 1. Parse productIds and quantities from ARGV (no maxInventory array)
     * 2. Phase 1 (check): for each product, if available < requested → return 0 (abort)
     * 3. Phase 2 (decrement): all checks passed → DECRBY each product's available counter
     * 4. Return 1 (success)
     *
     * All-or-nothing: if Phase 1 fails for any product, nothing is modified.
     */
    private static final String CHECK_AND_RESERVE_AVAILABLE_LUA_SCRIPT =
            "local keyPrefix = ARGV[1]\n" +
            "local numProducts = tonumber(ARGV[2])\n" +
            "local argOffset = 3\n" +
            "\n" +
            "local productIds = {}\n" +
            "local quantities = {}\n" +
            "\n" +
            "for i = 1, numProducts do\n" +
            "    productIds[i] = ARGV[argOffset]\n" +
            "    argOffset = argOffset + 1\n" +
            "end\n" +
            "\n" +
            "for i = 1, numProducts do\n" +
            "    quantities[i] = tonumber(ARGV[argOffset])\n" +
            "    argOffset = argOffset + 1\n" +
            "end\n" +
            "\n" +
            "-- Phase 1: Check available for all products (no external snapshot)\n" +
            "for i = 1, numProducts do\n" +
            "    local key = keyPrefix .. productIds[i]\n" +
            "    local available = tonumber(redis.call('GET', key)) or 0\n" +
            "    if available < quantities[i] then\n" +
            "        return 0  -- Insufficient available, abort all-or-nothing\n" +
            "    end\n" +
            "end\n" +
            "\n" +
            "-- Phase 2: All checks passed, decrement all available counters\n" +
            "for i = 1, numProducts do\n" +
            "    local key = keyPrefix .. productIds[i]\n" +
            "    redis.call('DECRBY', key, quantities[i])\n" +
            "end\n" +
            "\n" +
            "return 1  -- Success\n";

    @Override
    public boolean checkAndReserveAvailableAtomic(String keyPrefix, Map<String, Long> productQuantities) {
        log.info("(checkAndReserveAvailableAtomic) Executing atomic available check-and-reserve for {} products with keyPrefix: {}",
                productQuantities.size(), keyPrefix);

        if (productQuantities.isEmpty()) {
            log.warn("(checkAndReserveAvailableAtomic) Empty product quantities map, nothing to reserve");
            return true;
        }

        // Build ARGV: keyPrefix, numProducts, productIds..., quantities...
        List<String> args = new ArrayList<>();
        args.add(keyPrefix);                                       // ARGV[1]
        args.add(String.valueOf(productQuantities.size()));        // ARGV[2]

        List<String> productIds = new ArrayList<>(productQuantities.keySet());
        args.addAll(productIds);                                   // ARGV[3..n]

        for (String productId : productIds) {
            args.add(String.valueOf(productQuantities.get(productId))); // ARGV[n+1..2n]
        }

        try {
            Long result = redisTemplate.execute((RedisCallback<Long>) connection -> {
                byte[][] argBytes = args.stream()
                        .map(arg -> arg.getBytes(StandardCharsets.UTF_8))
                        .toArray(byte[][]::new);

                return connection.scriptingCommands().eval(
                        CHECK_AND_RESERVE_AVAILABLE_LUA_SCRIPT.getBytes(StandardCharsets.UTF_8),
                        ReturnType.INTEGER,
                        0,
                        argBytes
                );
            });

            boolean success = result != null && result == 1L;
            if (success) {
                log.info("(checkAndReserveAvailableAtomic) Successfully reserved available inventory for products: {}", productIds);
            } else {
                log.warn("(checkAndReserveAvailableAtomic) Failed to reserve — insufficient available stock for products: {}", productIds);
            }
            return success;
        } catch (Exception e) {
            log.error("(checkAndReserveAvailableAtomic) Exception while executing Lua script", e);
            return false;
        }
    }
```

The full updated `PendingOrderCacheRepositoryImpl.java` keeps all existing fields, constructors, and methods intact and appends these two members in order (constant then method).

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /path/to/microservice-ecommerce/core/core-order-cache
mvn test -Dtest=CheckAndReserveAvailableAtomicTest -q
```

Expected: all 6 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add core/core-order-cache/src/main/java/org/aibles/ecommerce/core_order_cache/repository/PendingOrderCacheRepository.java \
        core/core-order-cache/src/main/java/org/aibles/ecommerce/core_order_cache/repository/impl/PendingOrderCacheRepositoryImpl.java \
        core/core-order-cache/src/test/java/org/aibles/ecommerce/core_order_cache/repository/impl/CheckAndReserveAvailableAtomicTest.java
git commit -m "feat(core-order-cache): add checkAndReserveAvailableAtomic — self-contained Lua with DECRBY available counter"
```

---

## Task 3: Add `stock` field to `InventoryProduct` entity

**Files:**
- Modify: `inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/entity/InventoryProduct.java`

- [ ] **Step 1: Write a failing test asserting the field exists**

Create `inventory-service/src/test/java/org/aibles/ecommerce/inventory_service/entity/InventoryProductStockFieldTest.java`:

```java
package org.aibles.ecommerce.inventory_service.entity;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class InventoryProductStockFieldTest {

    @Test
    void inventoryProduct_hasStockField_defaultZero() {
        InventoryProduct product = new InventoryProduct();
        assertThat(product.getStock()).isNotNull();
        assertThat(product.getStock()).isEqualTo(0L);
    }

    @Test
    void inventoryProduct_stockCanBeSet() {
        InventoryProduct product = new InventoryProduct();
        product.setStock(60L);
        assertThat(product.getStock()).isEqualTo(60L);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /path/to/microservice-ecommerce/inventory-service
mvn test -Dtest=InventoryProductStockFieldTest -q
```

Expected: FAIL — `getStock()` / `setStock()` do not exist.

- [ ] **Step 3: Add the `stock` field to `InventoryProduct`**

```java
package org.aibles.ecommerce.inventory_service.entity;

import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductUpdate;

@Entity
@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class InventoryProduct {

    @Id
    private String id;

    private String name;

    private Double price;

    private String imageUrl;

    /**
     * Materialized available stock count. Authoritative committed stock:
     * decremented atomically at payment-success commit via a conditional
     * UPDATE (stock >= :n guard). Seeded on boot into Redis available counter.
     */
    @Builder.Default
    private Long stock = 0L;

    public static InventoryProduct from(final ProductUpdate productUpdate) {
        InventoryProduct inventoryProduct = new InventoryProduct();
        inventoryProduct.setId(productUpdate.getId().toString());
        inventoryProduct.setName(productUpdate.getName().toString());
        inventoryProduct.setPrice(productUpdate.getPrice());
        inventoryProduct.setImageUrl(productUpdate.getImageUrl() != null
                ? productUpdate.getImageUrl().toString()
                : null);
        inventoryProduct.setStock(0L);
        return inventoryProduct;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mvn test -Dtest=InventoryProductStockFieldTest -q
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/entity/InventoryProduct.java \
        inventory-service/src/test/java/org/aibles/ecommerce/inventory_service/entity/InventoryProductStockFieldTest.java
git commit -m "feat(inventory-service): add stock field to InventoryProduct entity (materialized committed count)"
```

---

## Task 4: Flyway migration — add `stock` column to `inventory_product`

**Files:**
- Create: `inventory-service/src/main/resources/db/migration/V2__add_stock_to_inventory_product.sql`

**Context:** `MasterDatasourceConfiguration.java` sets `hibernate.hbm2ddl.auto=update` AND Spring Boot auto-detects Flyway from the existing `V1__inventory_product_image_url.sql`. Flyway runs first, then Hibernate update reconciles. The migration adds the column AND backfills `stock` from the existing `product_quantity_history` ledger for live systems.

- [ ] **Step 1: Create the migration file**

```sql
-- V2: Add materialized `stock` column to inventory_product.
-- This column is the authoritative committed-stock floor:
--   - DECREMENTED atomically at payment-success via UPDATE ... WHERE stock >= :n
--   - INCREMENTED at admin restock
--   - SEEDED into Redis available:{pid} on inventory-service boot
--
-- Backfill: existing rows get SUM(product_quantity_history.quantity) or 0
-- so the column is immediately valid for the boot seeder on first deploy.

ALTER TABLE inventory_product
    ADD COLUMN stock BIGINT NOT NULL DEFAULT 0;

UPDATE inventory_product ip
SET ip.stock = GREATEST(0, COALESCE(
    (SELECT SUM(pqh.quantity)
     FROM product_quantity_history pqh
     WHERE pqh.product_id = ip.id),
    0
));
```

- [ ] **Step 2: Verify migration version sequence**

```bash
ls /path/to/microservice-ecommerce/inventory-service/src/main/resources/db/migration/
```

Expected output: `V1__inventory_product_image_url.sql  V2__add_stock_to_inventory_product.sql`

- [ ] **Step 3: Commit**

```bash
git add inventory-service/src/main/resources/db/migration/V2__add_stock_to_inventory_product.sql
git commit -m "feat(inventory-service): Flyway V2 migration — add stock column, backfill from quantity history"
```

---

## Task 5: Add `decrementStockIfSufficient` and `adjustStock` to `MasterInventoryProductRepository`

**Files:**
- Modify: `inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/repository/master/MasterInventoryProductRepository.java`

- [ ] **Step 1: Write failing tests that call the new methods via mock**

Create `inventory-service/src/test/java/org/aibles/ecommerce/inventory_service/repository/master/MasterInventoryProductRepositoryContractTest.java`:

```java
package org.aibles.ecommerce.inventory_service.repository.master;

import org.junit.jupiter.api.Test;
import static org.mockito.Mockito.*;

/**
 * Contract test — verifies the method signatures exist on the interface/class.
 * Real DB behavior is verified by the k8s boundary regression test.
 */
class MasterInventoryProductRepositoryContractTest {

    @Test
    void decrementStockIfSufficient_methodExists_andReturnsInt() {
        MasterInventoryProductRepository repo = mock(MasterInventoryProductRepository.class);
        when(repo.decrementStockIfSufficient("prod-1", 5L)).thenReturn(1);

        int result = repo.decrementStockIfSufficient("prod-1", 5L);

        verify(repo).decrementStockIfSufficient("prod-1", 5L);
        org.assertj.core.api.Assertions.assertThat(result).isEqualTo(1);
    }

    @Test
    void decrementStockIfSufficient_returns0_whenStockInsufficient() {
        MasterInventoryProductRepository repo = mock(MasterInventoryProductRepository.class);
        when(repo.decrementStockIfSufficient("prod-1", 999L)).thenReturn(0);

        int result = repo.decrementStockIfSufficient("prod-1", 999L);

        org.assertj.core.api.Assertions.assertThat(result).isEqualTo(0);
    }

    @Test
    void adjustStock_methodExists() {
        MasterInventoryProductRepository repo = mock(MasterInventoryProductRepository.class);

        repo.adjustStock("prod-1", 10L);

        verify(repo).adjustStock("prod-1", 10L);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /path/to/microservice-ecommerce/inventory-service
mvn test -Dtest=MasterInventoryProductRepositoryContractTest -q
```

Expected: FAIL — `decrementStockIfSufficient` and `adjustStock` do not exist.

- [ ] **Step 3: Add the two query methods to `MasterInventoryProductRepository`**

```java
package org.aibles.ecommerce.inventory_service.repository.master;

import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface MasterInventoryProductRepository extends JpaRepository<InventoryProduct, String> {

    List<InventoryProduct> findByIdIn(List<String> ids);

    /**
     * Atomically decrements `stock` by `n` ONLY if `stock >= n`.
     * Returns 1 (row updated) on success, 0 if the decrement would go below 0.
     * Use at payment-success commit to enforce the DB floor: 0 rows updated
     * means a would-be oversell was blocked — log an alert and skip the ledger write.
     */
    @Modifying
    @Query("UPDATE InventoryProduct ip SET ip.stock = ip.stock - :n WHERE ip.id = :id AND ip.stock >= :n")
    int decrementStockIfSufficient(@Param("id") String id, @Param("n") long n);

    /**
     * Unconditionally adjusts `stock` by `delta` (positive = restock, negative = admin correction).
     * Use for admin stock updates where the operator accepts responsibility.
     * For payment-success commit use decrementStockIfSufficient() instead.
     */
    @Modifying
    @Query("UPDATE InventoryProduct ip SET ip.stock = ip.stock + :delta WHERE ip.id = :id")
    void adjustStock(@Param("id") String id, @Param("delta") long delta);
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mvn test -Dtest=MasterInventoryProductRepositoryContractTest -q
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/repository/master/MasterInventoryProductRepository.java \
        inventory-service/src/test/java/org/aibles/ecommerce/inventory_service/repository/master/MasterInventoryProductRepositoryContractTest.java
git commit -m "feat(inventory-service): add decrementStockIfSufficient + adjustStock to MasterInventoryProductRepository"
```

---

## Task 6: Create `AvailableStockSeeder` and wire it in `InventoryServiceConfiguration`

**Files:**
- Create: `inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/configuration/AvailableStockSeeder.java`
- Modify: `inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/configuration/InventoryServiceConfiguration.java`
- Create: `inventory-service/src/test/java/org/aibles/ecommerce/inventory_service/configuration/AvailableStockSeederTest.java`

- [ ] **Step 1: Write failing tests for the seeder**

```java
package org.aibles.ecommerce.inventory_service.configuration;

import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveInventoryProductRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.DefaultApplicationArguments;

import java.util.List;

import static org.mockito.Mockito.*;

class AvailableStockSeederTest {

    private SlaveInventoryProductRepository slaveInventoryProductRepository;
    private RedisRepository redisRepository;
    private AvailableStockSeeder seeder;

    @BeforeEach
    void setUp() {
        slaveInventoryProductRepository = mock(SlaveInventoryProductRepository.class);
        redisRepository = mock(RedisRepository.class);
        seeder = new AvailableStockSeeder(slaveInventoryProductRepository, redisRepository);
    }

    @Test
    void run_seedsAvailableCounterForEachProduct() throws Exception {
        InventoryProduct p1 = new InventoryProduct();
        p1.setId("prod-1");
        p1.setStock(60L);

        InventoryProduct p2 = new InventoryProduct();
        p2.setId("prod-2");
        p2.setStock(15L);

        when(slaveInventoryProductRepository.findAll()).thenReturn(List.of(p1, p2));

        seeder.run(new DefaultApplicationArguments());

        // For each product: delete existing key, then incr by stock value
        verify(redisRepository).delete(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1");
        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1", 60L);

        verify(redisRepository).delete(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-2");
        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-2", 15L);
    }

    @Test
    void run_skipsIncrForZeroStockProduct() throws Exception {
        InventoryProduct p = new InventoryProduct();
        p.setId("prod-zero");
        p.setStock(0L);

        when(slaveInventoryProductRepository.findAll()).thenReturn(List.of(p));

        seeder.run(new DefaultApplicationArguments());

        // delete always runs to clear stale Redis value
        verify(redisRepository).delete(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-zero");
        // incr must NOT be called for zero-stock product (INCRBY 0 is a no-op but still misleading)
        verify(redisRepository, never()).incr(eq(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-zero"), anyLong());
    }

    @Test
    void run_clampsNegativeStockToZero() throws Exception {
        InventoryProduct p = new InventoryProduct();
        p.setId("prod-negative");
        p.setStock(-5L);  // pre-fix oversell artefact

        when(slaveInventoryProductRepository.findAll()).thenReturn(List.of(p));

        seeder.run(new DefaultApplicationArguments());

        // negative stock → treated as 0 → only delete, no incr
        verify(redisRepository).delete(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-negative");
        verify(redisRepository, never()).incr(eq(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-negative"), anyLong());
    }

    @Test
    void run_handlesNullStockGracefully() throws Exception {
        InventoryProduct p = new InventoryProduct();
        p.setId("prod-null-stock");
        p.setStock(null);

        when(slaveInventoryProductRepository.findAll()).thenReturn(List.of(p));

        seeder.run(new DefaultApplicationArguments());

        verify(redisRepository).delete(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-null-stock");
        verify(redisRepository, never()).incr(any(), anyLong());
    }

    @Test
    void run_handlesEmptyProductList() throws Exception {
        when(slaveInventoryProductRepository.findAll()).thenReturn(List.of());

        seeder.run(new DefaultApplicationArguments());

        verifyNoInteractions(redisRepository);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /path/to/microservice-ecommerce/inventory-service
mvn test -Dtest=AvailableStockSeederTest -q
```

Expected: FAIL — `AvailableStockSeeder` class does not exist.

- [ ] **Step 3: Create `AvailableStockSeeder`**

```java
package org.aibles.ecommerce.inventory_service.configuration;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveInventoryProductRepository;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;

import java.util.List;

/**
 * Seeds the Redis `available:{productId}` counters from the authoritative
 * `inventory_product.stock` column on inventory-service startup.
 *
 * On Redis loss/restart, this runner reseeds all counters from the DB floor,
 * restoring reservation capability without manual intervention.
 *
 * Wired as a manual @Bean in InventoryServiceConfiguration (no @Component).
 */
@Slf4j
public class AvailableStockSeeder implements ApplicationRunner {

    private final SlaveInventoryProductRepository slaveInventoryProductRepository;
    private final RedisRepository redisRepository;

    public AvailableStockSeeder(SlaveInventoryProductRepository slaveInventoryProductRepository,
                                RedisRepository redisRepository) {
        this.slaveInventoryProductRepository = slaveInventoryProductRepository;
        this.redisRepository = redisRepository;
    }

    @Override
    public void run(ApplicationArguments args) throws Exception {
        log.info("(AvailableStockSeeder) Seeding productAvailable counters from inventory_product.stock");

        List<InventoryProduct> products = slaveInventoryProductRepository.findAll();

        for (InventoryProduct product : products) {
            long stock = product.getStock() != null ? Math.max(0L, product.getStock()) : 0L;
            String key = RedisConstant.AVAILABLE_PRODUCT_KEY + product.getId();

            // Clear any stale value before setting fresh (handles Redis restart + partial state)
            redisRepository.delete(key);

            if (stock > 0) {
                redisRepository.incr(key, stock);
            }
        }

        log.info("(AvailableStockSeeder) Seeded available counters for {} products", products.size());
    }
}
```

- [ ] **Step 4: Wire the seeder bean in `InventoryServiceConfiguration`**

Add one `@Bean` method to `InventoryServiceConfiguration.java`. Keep all existing beans unchanged:

```java
package org.aibles.ecommerce.inventory_service.configuration;

import org.aibles.ecommerce.core_exception_api.configuration.EnableCoreExceptionApi;
import org.aibles.ecommerce.core_order_cache.configuration.EnableOrderCache;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.configuration.EnableCoreRedis;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.core_routing_db.configuration.EnableDatasourceRouting;
import org.aibles.ecommerce.inventory_service.repository.ProcessedPaymentEventRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterProductQuantityHistoryRepo;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveProductQuantityHistoryRepo;
import org.aibles.ecommerce.inventory_service.service.InventoryService;
import org.aibles.ecommerce.inventory_service.service.InventoryServiceImpl;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;
import org.springframework.data.mongodb.config.EnableMongoAuditing;
import org.springframework.scheduling.annotation.EnableAsync;

@Configuration
@EnableDatasourceRouting
@EnableCoreExceptionApi
@EnableAsync
@EnableMongoAuditing
@EnableCoreRedis
@EnableOrderCache
@EnableJpaAuditing
public class InventoryServiceConfiguration {

    @Bean
    public InventoryService inventoryService(MasterInventoryProductRepository masterInventoryProductRepository,
                                             SlaveInventoryProductRepository slaveInventoryProductRepository,
                                             MasterProductQuantityHistoryRepo masterProductQuantityHistoryRepo,
                                             SlaveProductQuantityHistoryRepo slaveProductQuantityHistoryRepo,
                                             ApplicationEventPublisher applicationEventPublisher,
                                             RedisRepository redisRepository,
                                             PendingOrderCacheRepository pendingOrderCacheRepository,
                                             RedissonClient redissonClient,
                                             ProcessedPaymentEventRepository processedPaymentEventRepository) {
        return new InventoryServiceImpl(masterInventoryProductRepository,
                slaveInventoryProductRepository,
                masterProductQuantityHistoryRepo,
                slaveProductQuantityHistoryRepo,
                applicationEventPublisher,
                redisRepository,
                pendingOrderCacheRepository,
                redissonClient,
                processedPaymentEventRepository);
    }

    @Bean
    public AvailableStockSeeder availableStockSeeder(
            SlaveInventoryProductRepository slaveInventoryProductRepository,
            RedisRepository redisRepository) {
        return new AvailableStockSeeder(slaveInventoryProductRepository, redisRepository);
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mvn test -Dtest=AvailableStockSeederTest -q
```

Expected: all 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/configuration/AvailableStockSeeder.java \
        inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/configuration/InventoryServiceConfiguration.java \
        inventory-service/src/test/java/org/aibles/ecommerce/inventory_service/configuration/AvailableStockSeederTest.java
git commit -m "feat(inventory-service): add AvailableStockSeeder — seeds productAvailable Redis counters from DB stock on boot"
```

---

## Task 7: Update `InventoryServiceImpl` — fix commit path, revert list() to slave, sync update()

This is the core Layer 1 + Layer 2 change in inventory-service. Three methods change:

1. `processInventoryUpdate` (commit path): **remove** `redisRepository.decr(QUEUE_PRODUCT_KEY + ...)`, **add** `masterInventoryProductRepository.decrementStockIfSufficient(pid, qty)` with floor-alert.
2. `list()` (gRPC browse read): revert from `masterProductQuantityHistoryRepo` back to `slaveProductQuantityHistoryRepo`.
3. `update()` (admin restock): add `adjustStock` on DB and sync Redis `available` counter.

**Files:**
- Modify: `inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/service/InventoryServiceImpl.java`
- Create: `inventory-service/src/test/java/org/aibles/ecommerce/inventory_service/service/InventoryCommitPathTest.java`

- [ ] **Step 1: Write failing tests for the new commit path**

```java
package org.aibles.ecommerce.inventory_service.service;

import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.inventory_service.constant.PaymentEventType;
import org.aibles.ecommerce.inventory_service.entity.ProcessedPaymentEvent;
import org.aibles.ecommerce.inventory_service.repository.ProcessedPaymentEventRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterProductQuantityHistoryRepo;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveProductQuantityHistoryRepo;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.dao.DuplicateKeyException;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.TimeUnit;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class InventoryCommitPathTest {

    private MasterInventoryProductRepository masterInventoryProductRepository;
    private SlaveInventoryProductRepository slaveInventoryProductRepository;
    private MasterProductQuantityHistoryRepo masterProductQuantityHistoryRepo;
    private SlaveProductQuantityHistoryRepo slaveProductQuantityHistoryRepo;
    private ApplicationEventPublisher applicationEventPublisher;
    private RedisRepository redisRepository;
    private PendingOrderCacheRepository pendingOrderCacheRepository;
    private RedissonClient redissonClient;
    private ProcessedPaymentEventRepository processedPaymentEventRepository;

    private InventoryServiceImpl inventoryService;

    @BeforeEach
    void setUp() {
        masterInventoryProductRepository = mock(MasterInventoryProductRepository.class);
        slaveInventoryProductRepository = mock(SlaveInventoryProductRepository.class);
        masterProductQuantityHistoryRepo = mock(MasterProductQuantityHistoryRepo.class);
        slaveProductQuantityHistoryRepo = mock(SlaveProductQuantityHistoryRepo.class);
        applicationEventPublisher = mock(ApplicationEventPublisher.class);
        redisRepository = mock(RedisRepository.class);
        pendingOrderCacheRepository = mock(PendingOrderCacheRepository.class);
        redissonClient = mock(RedissonClient.class);
        processedPaymentEventRepository = mock(ProcessedPaymentEventRepository.class);

        inventoryService = new InventoryServiceImpl(
                masterInventoryProductRepository,
                slaveInventoryProductRepository,
                masterProductQuantityHistoryRepo,
                slaveProductQuantityHistoryRepo,
                applicationEventPublisher,
                redisRepository,
                pendingOrderCacheRepository,
                redissonClient,
                processedPaymentEventRepository
        );

        // Default lock stub
        RLock lock = mock(RLock.class);
        when(redissonClient.getFairLock(anyString())).thenReturn(lock);
        try {
            when(lock.tryLock(anyLong(), anyLong(), any(TimeUnit.class))).thenReturn(true);
        } catch (InterruptedException ignored) {}
        when(lock.isHeldByCurrentThread()).thenReturn(true);
    }

    @Test
    void handleSuccessPayment_doesNotDecrRedisQueueCounter() {
        // Arrange
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-1"))
                .thenReturn(Optional.of(Map.of("prod-1", 3L)));
        when(masterInventoryProductRepository.decrementStockIfSufficient("prod-1", 3L))
                .thenReturn(1);

        // Act
        inventoryService.handleSuccessPayment("order-1");

        // Assert — MUST NOT call decr on QUEUE_PRODUCT_KEY (old pattern)
        verify(redisRepository, never()).decr(
                eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-1"), anyLong());
        // MUST NOT call incr/decr on AVAILABLE_PRODUCT_KEY at commit time either
        verify(redisRepository, never()).decr(
                eq(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1"), anyLong());
        verify(redisRepository, never()).incr(
                eq(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1"), anyLong());
    }

    @Test
    void handleSuccessPayment_callsDecrementStockIfSufficient_forEachProduct() {
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-2"))
                .thenReturn(Optional.of(Map.of("prod-A", 2L, "prod-B", 5L)));
        when(masterInventoryProductRepository.decrementStockIfSufficient("prod-A", 2L)).thenReturn(1);
        when(masterInventoryProductRepository.decrementStockIfSufficient("prod-B", 5L)).thenReturn(1);

        inventoryService.handleSuccessPayment("order-2");

        verify(masterInventoryProductRepository).decrementStockIfSufficient("prod-A", 2L);
        verify(masterInventoryProductRepository).decrementStockIfSufficient("prod-B", 5L);
    }

    @Test
    void handleSuccessPayment_dbFloorReturnsZero_logsAlertAndSkipsLedgerWrite() {
        // Arrange — stock already 0 (DB floor would be violated)
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-3"))
                .thenReturn(Optional.of(Map.of("prod-depleted", 1L)));
        when(masterInventoryProductRepository.decrementStockIfSufficient("prod-depleted", 1L))
                .thenReturn(0); // DB floor triggered

        // Act — must not throw
        inventoryService.handleSuccessPayment("order-3");

        // Assert — ledger row must NOT be saved for a would-be oversell
        verify(masterProductQuantityHistoryRepo, never()).save(any());
    }

    @Test
    void handleSuccessPayment_alreadyProcessed_skipsEverything() {
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenThrow(new DuplicateKeyException("duplicate"));

        inventoryService.handleSuccessPayment("order-dup");

        verifyNoInteractions(pendingOrderCacheRepository);
        verifyNoInteractions(masterInventoryProductRepository);
        verifyNoInteractions(redisRepository);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /path/to/microservice-ecommerce/inventory-service
mvn test -Dtest=InventoryCommitPathTest -q
```

Expected: tests 1 and 3 FAIL (current impl calls `decr` and always writes the ledger row).

- [ ] **Step 3: Rewrite `processInventoryUpdate` in `InventoryServiceImpl`**

Replace the existing `processInventoryUpdate` private method with:

```java
    /**
     * Processes inventory update for a successful payment.
     * Layer 1: does NOT touch Redis available counter (the unit was already removed at reserve time).
     * Layer 2: decrements inventory_product.stock with an atomic conditional floor (stock >= n).
     *          If 0 rows updated → would-be oversell blocked; log alert, skip ledger row.
     * Keeps the product_quantity_history ledger write for history/compat when DB floor passes.
     */
    private void processInventoryUpdate(String orderId) {
        log.info("(processInventoryUpdate) Processing inventory update for order: {}", orderId);

        Optional<Map<String, Long>> productQuantityFromOrderOptional =
                pendingOrderCacheRepository.getProductQuantitiesForOrder(orderId);
        if (productQuantityFromOrderOptional.isEmpty()) {
            log.warn("(processInventoryUpdate) orderId: {} is invalid or already processed", orderId);
            return;
        }

        Map<String, Long> productQuantityFromOrder = productQuantityFromOrderOptional.get();

        if (productQuantityFromOrder.isEmpty()) {
            log.warn("(processInventoryUpdate) orderId: {} has no products", orderId);
            return;
        }

        List<String> productIds = new ArrayList<>(productQuantityFromOrder.keySet());
        Collections.sort(productIds);
        Map<String, RLock> locks = new HashMap<>();

        try {
            for (String productId : productIds) {
                locks.put(productId, acquireLockWithRetry(RedisConstant.LOCK_QUEUE_PRODUCT_KEY + productId));
            }

            ProductQuantityUpdated productQuantityUpdated;
            MongoSavedEvent mongoSavedEvent;

            for (Map.Entry<String, Long> entry : productQuantityFromOrder.entrySet()) {
                String productId = entry.getKey();
                long qty = entry.getValue();

                // Layer 2: atomic conditional DB decrement (floor at 0)
                int rows = masterInventoryProductRepository.decrementStockIfSufficient(productId, qty);

                if (rows == 0) {
                    // DB floor triggered: this commit would have caused an oversell.
                    // Log an error-level alert — this must never happen in normal operation.
                    log.error("(processInventoryUpdate) DB floor blocked would-be oversell — " +
                              "productId={} requestedDecrement={} currentStock<qty; skipping ledger write",
                              productId, qty);
                    // Skip the ledger row for this product to keep SUM(history) consistent
                    continue;
                }

                // Layer 1 (commit path): do NOT touch Redis available counter.
                // The unit was removed from available at reserve time. No Redis change here.

                // Ledger row for history/compat (only when DB floor passes)
                ProductQuantityHistory productQuantityHistory = new ProductQuantityHistory();
                productQuantityHistory.setProductId(productId);
                productQuantityHistory.setQuantity(qty * -1);
                masterProductQuantityHistoryRepo.save(productQuantityHistory);

                // Publish inventory update event
                productQuantityUpdated = ProductQuantityUpdated.newBuilder()
                        .setProductId(productId)
                        .setQuantity(qty * -1)
                        .build();
                mongoSavedEvent = new MongoSavedEvent(this,
                        EcommerceEvent.PRODUCT_QUANTITY_UPDATED.getValue(),
                        productQuantityUpdated);
                applicationEventPublisher.publishEvent(mongoSavedEvent);
            }

            // Remove order from pending orders (cleanup)
            pendingOrderCacheRepository.removeFromPendingOrders(orderId);
            log.info("(processInventoryUpdate) Successfully processed inventory and cleaned up order: {}", orderId);

        } catch (Exception e) {
            log.error("(processInventoryUpdate) Error processing inventory for orderId: {}", orderId, e);
            throw new InternalErrorException();
        } finally {
            releaseLockInReverse(productIds, locks);
        }
    }
```

- [ ] **Step 4: Revert `list()` to use slave repo**

In `InventoryServiceImpl.list()`, change the SUM read from `masterProductQuantityHistoryRepo` back to `slaveProductQuantityHistoryRepo`:

```java
    @Override
    @Transactional(readOnly = true)
    public InventoryProductIdsResponse list(InventoryProductIdsRequest request) {
        log.info("(list)request: {}", request);
        List<InventoryProduct> inventoryProducts = masterInventoryProductRepository.findByIdIn(request.getIds());
        // Browse/display reads tolerate slave staleness — reservation no longer uses this SUM
        // (the AVAILABLE_PRODUCT_KEY Redis counter is now the reservation authority).
        // Reverted to slave per the oversell fix design (locked decision #2).
        List<ProductQuantitySummary> quantitySummaries =
                slaveProductQuantityHistoryRepo.sumQuantitiesByProductIds(request.getIds());

        Map<String, Long> productQuantityMap = quantitySummaries.stream().collect(
                Collectors.toMap(ProductQuantitySummary::getProductId, ProductQuantitySummary::getTotalQuantity)
        );

        List<InventoryProductResponse> inventoryProductResponses = new ArrayList<>();
        for (InventoryProduct inventoryProduct : inventoryProducts) {
            InventoryProductResponse inventoryProductResponse = InventoryProductResponse.builder()
                    .id(inventoryProduct.getId())
                    .name(inventoryProduct.getName())
                    .price(inventoryProduct.getPrice())
                    .quantity(productQuantityMap.get(inventoryProduct.getId()) != null ?
                            productQuantityMap.get(inventoryProduct.getId()) : 0L)
                    .imageUrl(inventoryProduct.getImageUrl())
                    .build();
            inventoryProductResponses.add(inventoryProductResponse);
        }
        return new InventoryProductIdsResponse(inventoryProductResponses);
    }
```

- [ ] **Step 5: Update `update()` to sync `stock` column and Redis `available` counter**

Replace the existing `update()` method with:

```java
    @Override
    @Transactional
    public void update(String id, Long quantity, Boolean isAdd) {
        log.info("(update)id: {}, quantity: {}, isAdd: {}", id, quantity, isAdd);
        if (!slaveInventoryProductRepository.existsById(id)) {
            log.warn("(update)id: {} is invalid", id);
            throw new NotFoundException();
        }

        long actualQuantity = Boolean.TRUE.equals(isAdd) ? quantity : -quantity;

        // Ledger row (history/compat — keep as-is)
        ProductQuantityHistory productQuantityHistory = new ProductQuantityHistory();
        productQuantityHistory.setProductId(id);
        productQuantityHistory.setQuantity(actualQuantity);
        masterProductQuantityHistoryRepo.save(productQuantityHistory);

        // Sync materialized stock column (admin ops: use adjustStock, operator accepts responsibility)
        masterInventoryProductRepository.adjustStock(id, actualQuantity);

        // Sync Redis available counter
        if (actualQuantity > 0) {
            redisRepository.incr(RedisConstant.AVAILABLE_PRODUCT_KEY + id, actualQuantity);
        } else if (actualQuantity < 0) {
            redisRepository.decr(RedisConstant.AVAILABLE_PRODUCT_KEY + id, Math.abs(actualQuantity));
        }

        ProductQuantityUpdated eventData = ProductQuantityUpdated.newBuilder()
                .setProductId(id)
                .setQuantity(actualQuantity)
                .build();

        MongoSavedEvent mongoSavedEvent = new MongoSavedEvent(this,
                EcommerceEvent.PRODUCT_QUANTITY_UPDATED.getValue(),
                eventData);
        applicationEventPublisher.publishEvent(mongoSavedEvent);
    }
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
mvn test -Dtest=InventoryCommitPathTest -q
```

Expected: all 4 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add inventory-service/src/main/java/org/aibles/ecommerce/inventory_service/service/InventoryServiceImpl.java \
        inventory-service/src/test/java/org/aibles/ecommerce/inventory_service/service/InventoryCommitPathTest.java
git commit -m "fix(inventory-service): commit path removes Redis decr, adds DB floor; list() reverts to slave; update() syncs stock+available"
```

---

## Task 8: Update `OrderServiceImpl` — switch to `checkAndReserveAvailableAtomic`, fix all release paths

Three locations change in `OrderServiceImpl.java`:

1. `validateAndReserveInventoryAtomic`: drop `maxInventoryMap`, call `checkAndReserveAvailableAtomic(AVAILABLE_PRODUCT_KEY, ...)`.
2. `rollbackInventoryReservation`: `decr(QUEUE_PRODUCT_KEY...)` → `incr(AVAILABLE_PRODUCT_KEY...)`.
3. `updateInventoryCacheWithLocks` (cancel/fail path): `decr(QUEUE_PRODUCT_KEY...)` → `incr(AVAILABLE_PRODUCT_KEY...)`.

No new constructor parameters are introduced → `OrderServiceConfiguration.java` does not change.

**Files:**
- Modify: `order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java`
- Create: `order-service/src/test/java/org/aibles/order_service/service/OrderReserveAvailableTest.java`

- [ ] **Step 1: Write failing tests**

```java
package org.aibles.order_service.service;

import org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse;
import org.aibles.ecommerce.common_dto.response.InventoryProductResponse;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.order_service.client.InventoryGrpcClientService;
import org.aibles.order_service.dto.request.OrderItemRequest;
import org.aibles.order_service.dto.request.OrderRequest;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.entity.ProcessedPaymentEvent;
import org.aibles.order_service.repository.ProcessedPaymentEventRepository;
import org.aibles.order_service.repository.master.MasterOrderItemRepo;
import org.aibles.order_service.repository.master.MasterOrderRepo;
import org.aibles.order_service.repository.slave.SlaveOrderItemRepo;
import org.aibles.order_service.repository.slave.SlaveOrderRepo;
import org.aibles.order_service.service.impl.OrderServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class OrderReserveAvailableTest {

    private InventoryGrpcClientService inventoryGrpcClientService;
    private RedisRepository redisRepository;
    private PendingOrderCacheRepository pendingOrderCacheRepository;
    private MasterOrderRepo masterOrderRepo;
    private MasterOrderItemRepo masterOrderItemRepo;
    private RedissonClient redissonClient;
    private ProcessedPaymentEventRepository processedPaymentEventRepository;
    private ApplicationEventPublisher eventPublisher;
    private SlaveOrderRepo slaveOrderRepo;
    private SlaveOrderItemRepo slaveOrderItemRepo;

    private OrderService orderService;

    @BeforeEach
    void setUp() {
        inventoryGrpcClientService = mock(InventoryGrpcClientService.class);
        redisRepository = mock(RedisRepository.class);
        pendingOrderCacheRepository = mock(PendingOrderCacheRepository.class);
        masterOrderRepo = mock(MasterOrderRepo.class);
        masterOrderItemRepo = mock(MasterOrderItemRepo.class);
        redissonClient = mock(RedissonClient.class);
        processedPaymentEventRepository = mock(ProcessedPaymentEventRepository.class);
        eventPublisher = mock(ApplicationEventPublisher.class);
        slaveOrderRepo = mock(SlaveOrderRepo.class);
        slaveOrderItemRepo = mock(SlaveOrderItemRepo.class);

        orderService = new OrderServiceImpl(
                inventoryGrpcClientService,
                redisRepository,
                pendingOrderCacheRepository,
                masterOrderRepo,
                masterOrderItemRepo,
                redissonClient,
                processedPaymentEventRepository,
                eventPublisher,
                slaveOrderRepo,
                slaveOrderItemRepo
        );

        RLock lock = mock(RLock.class);
        when(redissonClient.getFairLock(anyString())).thenReturn(lock);
        try {
            when(lock.tryLock(anyLong(), anyLong(), any())).thenReturn(true);
        } catch (InterruptedException ignored) {}
        when(lock.isHeldByCurrentThread()).thenReturn(true);
    }

    @Test
    void create_usesCheckAndReserveAvailableAtomic_notOldMethod() throws Exception {
        // Arrange
        InventoryProductResponse product = InventoryProductResponse.builder()
                .id("prod-1").name("Widget").price(9.99).quantity(10L).build();
        when(inventoryGrpcClientService.fetchInventoryData(anyList()))
                .thenReturn(new InventoryProductIdsResponse(List.of(product)));
        when(pendingOrderCacheRepository.checkAndReserveAvailableAtomic(
                eq(RedisConstant.AVAILABLE_PRODUCT_KEY), anyMap()))
                .thenReturn(true);

        Order saved = new Order();
        saved.setId("order-1");
        when(masterOrderRepo.save(any(Order.class))).thenReturn(saved);
        when(masterOrderItemRepo.saveAll(anyList())).thenAnswer(inv -> inv.getArgument(0));

        OrderRequest request = new OrderRequest("123 Main", "0912345678",
                List.of(new OrderItemRequest("prod-1", 2L)));

        // Act
        orderService.create("user-1", request);

        // Assert — new method called with AVAILABLE_PRODUCT_KEY
        verify(pendingOrderCacheRepository).checkAndReserveAvailableAtomic(
                eq(RedisConstant.AVAILABLE_PRODUCT_KEY), eq(Map.of("prod-1", 2L)));
        // OLD method must NOT be called
        verify(pendingOrderCacheRepository, never()).checkAndReserveAtomic(any(), any(), any());
    }

    @Test
    void create_rollbackOnFailure_incrsAvailableKey_notDecrsQueueKey() throws Exception {
        // Arrange — reservation succeeds but order-save fails
        InventoryProductResponse product = InventoryProductResponse.builder()
                .id("prod-1").name("Widget").price(9.99).quantity(10L).build();
        when(inventoryGrpcClientService.fetchInventoryData(anyList()))
                .thenReturn(new InventoryProductIdsResponse(List.of(product)));
        when(pendingOrderCacheRepository.checkAndReserveAvailableAtomic(
                eq(RedisConstant.AVAILABLE_PRODUCT_KEY), anyMap()))
                .thenReturn(true);

        // Order save throws → triggers rollback
        when(masterOrderRepo.save(any(Order.class)))
                .thenThrow(new RuntimeException("DB unavailable"));

        OrderRequest request = new OrderRequest("123 Main", "0912345678",
                List.of(new OrderItemRequest("prod-1", 2L)));

        try {
            orderService.create("user-1", request);
        } catch (Exception ignored) {}

        // Rollback must incr AVAILABLE_PRODUCT_KEY (release)
        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1", 2L);
        // Must NOT decr QUEUE_PRODUCT_KEY (old rollback)
        verify(redisRepository, never()).decr(eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-1"), anyLong());
    }

    @Test
    void handleCanceledOrder_incrsAvailableKey_notDecrsQueueKey() {
        // Arrange
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-cancel"))
                .thenReturn(Optional.of(Map.of("prod-1", 3L)));

        // Act
        orderService.handleCanceledOrder("order-cancel");

        // Assert — release uses AVAILABLE_PRODUCT_KEY incr
        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1", 3L);
        verify(redisRepository, never()).decr(eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-1"), anyLong());
    }

    @Test
    void handleFailedOrder_incrsAvailableKey_notDecrsQueueKey() {
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-fail"))
                .thenReturn(Optional.of(Map.of("prod-2", 1L)));

        orderService.handleFailedOrder("order-fail");

        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-2", 1L);
        verify(redisRepository, never()).decr(eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-2"), anyLong());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /path/to/microservice-ecommerce/order-service
mvn test -Dtest=OrderReserveAvailableTest -q
```

Expected: FAIL — still using `checkAndReserveAtomic` and `decr(QUEUE_PRODUCT_KEY...)`.

- [ ] **Step 3: Update `validateAndReserveInventoryAtomic` in `OrderServiceImpl`**

Replace the existing `validateAndReserveInventoryAtomic` private method:

```java
    /**
     * Validates product existence and prices via gRPC, then atomically reserves inventory
     * using the self-contained available-counter Lua script.
     * NO maxInventory snapshot is fetched — the Redis available counter is the authority.
     */
    private InventoryReservationResult validateAndReserveInventoryAtomic(
            Map<String, Long> productQuantityMap,
            List<String> productIds) {

        log.info("(validateAndReserveInventoryAtomic) Validating and reserving inventory for {} products", productIds.size());

        // Fetch product data (price + existence) — quantity is no longer used as a ceiling
        InventoryProductIdsRequest inventoryRequest = new InventoryProductIdsRequest(productIds);
        InventoryProductIdsResponse inventoryResponse = fetchInventoryData(inventoryRequest);

        // Build price map and validate all prices exist
        Map<String, Double> priceMap = buildAndValidatePriceMap(inventoryResponse);

        // Validate product existence (Lua script handles the availability check atomically)
        validateProductExistence(inventoryResponse.getInventoryProducts(), productQuantityMap);

        // Atomically check and decrement the available counter (no external snapshot)
        boolean reserved = pendingOrderCacheRepository.checkAndReserveAvailableAtomic(
                RedisConstant.AVAILABLE_PRODUCT_KEY,
                productQuantityMap
        );

        if (!reserved) {
            log.error("(validateAndReserveInventoryAtomic) Atomic reservation failed — insufficient available stock");
            throw new InvalidProductQuantityException(new ArrayList<>(productIds));
        }

        double totalPrice = calculateTotalPrice(priceMap, productQuantityMap);

        return InventoryReservationResult.builder()
                .inventoryResponse(inventoryResponse)
                .priceMap(priceMap)
                .totalOrderPrice(totalPrice)
                .reservedQuantities(productQuantityMap)
                .build();
    }
```

- [ ] **Step 4: Update `rollbackInventoryReservation` in `OrderServiceImpl`**

Replace the existing `rollbackInventoryReservation` private method:

```java
    /**
     * Releases inventory reservations by incrementing the available counter.
     * Called when order creation fails after a successful reservation.
     */
    private void rollbackInventoryReservation(Map<String, Long> productQuantityMap) {
        if (productQuantityMap == null || productQuantityMap.isEmpty()) {
            return;
        }

        log.warn("(rollbackInventoryReservation) Releasing reservations (incr available) for {} products",
                productQuantityMap.size());

        for (Map.Entry<String, Long> entry : productQuantityMap.entrySet()) {
            try {
                redisRepository.incr(RedisConstant.AVAILABLE_PRODUCT_KEY + entry.getKey(), entry.getValue());
                log.debug("(rollbackInventoryReservation) Released {} units for product {}", entry.getValue(), entry.getKey());
            } catch (Exception e) {
                log.error("(rollbackInventoryReservation) Failed to release product: {}", entry.getKey(), e);
            }
        }
    }
```

- [ ] **Step 5: Update `updateInventoryCacheWithLocks` in `OrderServiceImpl`**

Replace the existing `updateInventoryCacheWithLocks` private method (called on cancel/fail paths):

```java
    /**
     * Releases inventory reservations for canceled/failed orders
     * by incrementing the available counter for each product.
     */
    private void updateInventoryCacheWithLocks(Map<String, Long> productQuantityMap) {
        log.info("(updateInventoryCacheWithLocks) Releasing inventory reservations for products: {}", productQuantityMap.keySet());
        if (productQuantityMap.isEmpty()) {
            return;
        }

        List<String> productIds = new ArrayList<>(productQuantityMap.keySet());
        Collections.sort(productIds);

        DistributedLockContext lockContext = new DistributedLockContext(productIds);

        try {
            for (String productId : productIds) {
                String lockKey = RedisConstant.LOCK_QUEUE_PRODUCT_KEY + productId;
                RLock lock = acquireLockWithRetry(lockKey, lockContext);
                lockContext.addLock(productId, lock);
            }

            for (Map.Entry<String, Long> entry : productQuantityMap.entrySet()) {
                redisRepository.incr(RedisConstant.AVAILABLE_PRODUCT_KEY + entry.getKey(), entry.getValue());
            }

        } finally {
            lockContext.releaseAllInReverse();
        }
    }
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
mvn test -Dtest=OrderReserveAvailableTest -q
```

Expected: all 4 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/service/impl/OrderServiceImpl.java \
        order-service/src/test/java/org/aibles/order_service/service/OrderReserveAvailableTest.java
git commit -m "fix(order-service): use checkAndReserveAvailableAtomic + incr(AVAILABLE_PRODUCT_KEY) for all release paths"
```

---

## Task 9: Update `ExpiredOrderCleanupJob` — switch release to `incr(AVAILABLE_PRODUCT_KEY)`

**Files:**
- Modify: `order-service/src/main/java/org/aibles/order_service/scheduler/ExpiredOrderCleanupJob.java`
- Create: `order-service/src/test/java/org/aibles/order_service/scheduler/ExpiredOrderCleanupJobTest.java`

- [ ] **Step 1: Write failing test**

```java
package org.aibles.order_service.scheduler;

import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;

import java.util.Map;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ExpiredOrderCleanupJobTest {

    private RedisRepository redisRepository;
    private PendingOrderCacheRepository pendingOrderCacheRepository;
    private RedissonClient redissonClient;

    private ExpiredOrderCleanupJob job;

    @BeforeEach
    void setUp() {
        redisRepository = mock(RedisRepository.class);
        pendingOrderCacheRepository = mock(PendingOrderCacheRepository.class);
        redissonClient = mock(RedissonClient.class);

        job = new ExpiredOrderCleanupJob(redisRepository, pendingOrderCacheRepository, redissonClient);

        RLock lock = mock(RLock.class);
        when(redissonClient.getFairLock(anyString())).thenReturn(lock);
        try {
            when(lock.tryLock(anyLong(), anyLong(), any())).thenReturn(true);
        } catch (InterruptedException ignored) {}
        when(lock.isHeldByCurrentThread()).thenReturn(true);
    }

    @Test
    void cleanupExpiredOrders_incrsAvailableKey_notDecrsQueueKey() {
        // Arrange — one expired order with one product
        when(pendingOrderCacheRepository.getExpiredOrders(anyLong()))
                .thenReturn(Map.of("order-expired", Map.of("prod-1", 4L)));

        // Act
        job.cleanupExpiredOrders();

        // Assert — release uses incr on AVAILABLE_PRODUCT_KEY
        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1", 4L);
        // Must NOT use decr on QUEUE_PRODUCT_KEY (old release pattern)
        verify(redisRepository, never()).decr(eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-1"), anyLong());
    }

    @Test
    void cleanupExpiredOrders_noExpiredOrders_doesNothing() {
        when(pendingOrderCacheRepository.getExpiredOrders(anyLong())).thenReturn(Map.of());

        job.cleanupExpiredOrders();

        verifyNoInteractions(redisRepository);
    }

    @Test
    void cleanupExpiredOrders_removesFromPendingOrdersAfterRelease() {
        when(pendingOrderCacheRepository.getExpiredOrders(anyLong()))
                .thenReturn(Map.of("order-expired", Map.of("prod-1", 2L)));

        job.cleanupExpiredOrders();

        verify(pendingOrderCacheRepository).removeFromPendingOrders("order-expired");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /path/to/microservice-ecommerce/order-service
mvn test -Dtest=ExpiredOrderCleanupJobTest -q
```

Expected: test 1 FAILS — currently calls `decr(QUEUE_PRODUCT_KEY...)`.

- [ ] **Step 3: Update `rollbackProductReservations` in `ExpiredOrderCleanupJob`**

Replace the existing `rollbackProductReservations` private method:

```java
    /**
     * Releases product quantity reservations for an expired order
     * by incrementing the available counter (AVAILABLE_PRODUCT_KEY).
     */
    private void rollbackProductReservations(Map<String, Long> productQuantities) {
        log.debug("(rollbackProductReservations) Releasing reservations for {} products", productQuantities.size());

        for (Map.Entry<String, Long> entry : productQuantities.entrySet()) {
            String productId = entry.getKey();
            Long quantity = entry.getValue();

            try {
                redisRepository.incr(RedisConstant.AVAILABLE_PRODUCT_KEY + productId, quantity);
                log.debug("(rollbackProductReservations) Released {} units for product: {}", quantity, productId);
            } catch (Exception e) {
                log.error("(rollbackProductReservations) Failed to release product: {}", productId, e);
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mvn test -Dtest=ExpiredOrderCleanupJobTest -q
```

Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add order-service/src/main/java/org/aibles/order_service/scheduler/ExpiredOrderCleanupJob.java \
        order-service/src/test/java/org/aibles/order_service/scheduler/ExpiredOrderCleanupJobTest.java
git commit -m "fix(order-service): ExpiredOrderCleanupJob releases via incr(AVAILABLE_PRODUCT_KEY) not decr(QUEUE_PRODUCT_KEY)"
```

---

## Task 10: Full build verification and all unit tests pass

**Files:** None (build + test run only).

- [ ] **Step 1: Install updated core modules**

```bash
cd /path/to/microservice-ecommerce
make build
```

Expected: All core modules install successfully. Build should complete with `BUILD SUCCESS` for all modules.

- [ ] **Step 2: Run all unit tests in changed modules**

```bash
cd /path/to/microservice-ecommerce/core/core-redis
mvn test -q

cd /path/to/microservice-ecommerce/core/core-order-cache
mvn test -q

cd /path/to/microservice-ecommerce/inventory-service
mvn test -q

cd /path/to/microservice-ecommerce/order-service
mvn test -q
```

Expected: All tests PASS. No compilation errors.

- [ ] **Step 3: Verify existing snapshot test still passes (regression guard)**

```bash
cd /path/to/microservice-ecommerce/order-service
mvn test -Dtest=OrderCreateSnapshotTest -q
```

Expected: PASS. The snapshot test's `checkAndReserveAtomic` stub (`when(pendingOrderCacheRepository.checkAndReserveAtomic(any(), any(), any())).thenReturn(true)`) will no longer be invoked (the impl now calls `checkAndReserveAvailableAtomic`). Update the stub in `OrderCreateSnapshotTest` so it doesn't break:

The test currently stubs the OLD method. Since `OrderServiceImpl` now calls `checkAndReserveAvailableAtomic`, the old stub is never invoked and the reservation call returns `false` by default (Mockito default for boolean). Update the stub to:

```java
// In OrderCreateSnapshotTest.setUp() → createOrder_snapshotsProductNameAndImageUrl_onEachOrderItem():
// Replace:
when(pendingOrderCacheRepository.checkAndReserveAtomic(any(), any(), any()))
        .thenReturn(true);
// With:
when(pendingOrderCacheRepository.checkAndReserveAvailableAtomic(any(), any()))
        .thenReturn(true);
```

After updating `OrderCreateSnapshotTest.java`:

```bash
mvn test -Dtest=OrderCreateSnapshotTest -q
```

Expected: PASS.

- [ ] **Step 4: Commit the snapshot test fix**

```bash
git add order-service/src/test/java/org/aibles/order_service/service/OrderCreateSnapshotTest.java
git commit -m "fix(order-service-test): update OrderCreateSnapshotTest stub for checkAndReserveAvailableAtomic"
```

---

## Task 11: k8s Boundary Regression Test

This is the acceptance gate. Seed a product to 60 units, drive 50 VUs all-approve for 90s, let the saga settle, then verify `SUM(product_quantity_history)` floors at 0 and `inventory_product.stock` floors at 0.

**Prerequisites:** k8s cluster is up and running (`make k8s-status` shows all services healthy).

- [ ] **Step 1: Rebuild and push inventory-service and order-service images**

```bash
cd /path/to/microservice-ecommerce
make k8s-rebuild svc=inventory-service
make k8s-rebuild svc=order-service
```

Alternatively, if `FORCE_BUILD` is needed:

```bash
FORCE_BUILD=1 make k8s-rebuild svc=inventory-service
FORCE_BUILD=1 make k8s-rebuild svc=order-service
```

- [ ] **Step 2: Rebuild and push core modules that changed (core-redis, core-order-cache)**

The cores are embedded in each service JAR — rebuilding the service JARs in Step 1 already picks them up via Maven multi-module (`make build` is called by `make k8s-rebuild`).

Verify the JAR timestamps are fresh:

```bash
ls -la /path/to/microservice-ecommerce/inventory-service/target/*.jar
ls -la /path/to/microservice-ecommerce/order-service/target/*.jar
```

Expected: both JARs have today's timestamp.

- [ ] **Step 3: Redeploy inventory-service and order-service**

```bash
kubectl rollout restart deployment/inventory-service -n apps
kubectl rollout restart deployment/order-service -n apps
kubectl rollout status deployment/inventory-service -n apps --timeout=120s
kubectl rollout status deployment/order-service -n apps --timeout=120s
```

- [ ] **Step 4: Verify the seeder ran and populated `available` counters**

Check inventory-service logs for the seeder output:

```bash
kubectl logs -n apps -l app=inventory-service --tail=50 | grep AvailableStockSeeder
```

Expected output: `(AvailableStockSeeder) Seeded available counters for N products`

- [ ] **Step 5: Seed the target product to exactly 60 units**

The boundary test uses product `67c000000000000000000004` (from `oversell-boundary-job.yaml`). Check current stock and set to 60 via the admin update endpoint:

```bash
# Get current SUM of quantity history for the target product
kubectl exec -n infra mysql-0 -- mysql -u root -pecommerce_master ecommerce_dev \
  -e "SELECT SUM(quantity) AS total_stock FROM product_quantity_history WHERE product_id='67c000000000000000000004';"

# If total_stock != 60, add or subtract to reach 60.
# Example: if total is 0, add 60 units via admin endpoint:
curl -s -X PUT "http://api.microecom.local/inventory-service/v1/inventories/67c000000000000000000004" \
  -H "Authorization: Bearer <ADMIN_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"quantity": 60, "is_add": true}' | jq .
```

After restocking, verify Redis `available` counter was updated:

```bash
kubectl exec -n infra redis-0 -- redis-cli -a ecommerce_redis \
  GET "productAvailable:67c000000000000000000004"
```

Expected: `60`

Also verify `inventory_product.stock` column:

```bash
kubectl exec -n infra mysql-0 -- mysql -u root -pecommerce_master ecommerce_dev \
  -e "SELECT id, stock FROM inventory_product WHERE id='67c000000000000000000004';"
```

Expected: `stock = 60`

- [ ] **Step 6: Create the k6 ConfigMap from the boundary script**

```bash
kubectl create configmap k6-oversell-script \
  --from-file=boundary-flow.js=k8s/apps/base/k6-stress/oversell-boundary-flow.js \
  -n apps \
  --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 7: Apply and run the k6 boundary Job**

```bash
kubectl apply -f k8s/apps/base/k6-stress/oversell-boundary-job.yaml
kubectl wait --for=condition=complete job/k6-oversell-boundary -n apps --timeout=300s
kubectl logs -n apps job/k6-oversell-boundary | tail -30
```

The job runs 50 VUs for 90 seconds. Watch for the k6 summary. Stock-rejection errors (HTTP 422/400 for out-of-stock) are expected once the 60 units are depleted — these are correct behavior.

- [ ] **Step 8: Wait for the saga to settle (all in-flight payments processed)**

```bash
# Wait ~30s for Kafka payment events and saga completion
sleep 30
```

Then verify no orders are stuck in PROCESSING:

```bash
kubectl exec -n infra mysql-0 -- mysql -u root -pecommerce_master ecommerce_dev \
  -e "SELECT COUNT(*) AS processing_count FROM \`order\` WHERE status='PROCESSING';"
```

Expected: `0` (all orders resolved to COMPLETED, CANCELED, or FAILED).

- [ ] **Step 9: Query the acceptance criterion**

Run the critical queries that define success or failure:

```bash
kubectl exec -n infra mysql-0 -- mysql -u root -pecommerce_master ecommerce_dev \
  -e "SELECT SUM(quantity) AS final_ledger_sum FROM product_quantity_history WHERE product_id='67c000000000000000000004';"
```

**Expected: `>= 0` (must NOT be negative).** A result of `0` or any positive number is a PASS. A negative number is a FAIL.

```bash
kubectl exec -n infra mysql-0 -- mysql -u root -pecommerce_master ecommerce_dev \
  -e "SELECT stock FROM inventory_product WHERE id='67c000000000000000000004';"
```

**Expected: `0` (DB floor held; stock depleted but not negative).**

```bash
kubectl exec -n infra redis-0 -- redis-cli -a ecommerce_redis \
  GET "productAvailable:67c000000000000000000004"
```

**Expected: `0` or a small positive number (available counter, not negative).** The counter reflects any unsettled reservations.

- [ ] **Step 10: Commit acceptance results note and clean up the job**

```bash
kubectl delete job k6-oversell-boundary -n apps
```

```bash
git commit --allow-empty -m "test(k8s): oversell boundary test PASSED — final_stock >= 0 under 50 VUs"
```

---

## Self-Review

### 1. Spec Coverage

| Spec requirement | Task that implements it |
|---|---|
| New `AVAILABLE_PRODUCT_KEY` constant | Task 1 |
| New Lua `checkAndReserveAvailableAtomic` (check+DECRBY, no maxInventory) | Task 2 |
| Order-create reserve calls new Lua method against `AVAILABLE_PRODUCT_KEY` | Task 8 |
| Order-create rollback releases via `incr(AVAILABLE_PRODUCT_KEY)` | Task 8 |
| Cancel/fail compensation releases via `incr(AVAILABLE_PRODUCT_KEY)` | Task 8 |
| Expiry cleanup releases via `incr(AVAILABLE_PRODUCT_KEY)` | Task 9 |
| Commit path does NOT touch `available` counter | Task 7 (test asserts `never().decr/incr(AVAILABLE_PRODUCT_KEY...)`) |
| `inventory_product.stock` materialized column | Tasks 3, 4, 5 (entity, migration, repo) |
| Commit path: atomic conditional `UPDATE ... WHERE stock >= :n` | Tasks 5, 7 |
| DB floor: 0 rows updated → log alert, skip ledger write | Task 7 (`InventoryCommitPathTest.dbFloorReturnsZero_logsAlertAndSkipsLedgerWrite`) |
| Admin `update()` syncs `stock` DB column + Redis `available` | Task 7 (step 5) |
| Boot seeder: `available:{pid} = stock` for all products | Task 6 |
| Boot seeder: clamps negative stock to 0 | Task 6 (`AvailableStockSeederTest.run_clampsNegativeStockToZero`) |
| `list()` reverts to slave read (locked decision #2) | Task 7 (step 4) |
| New key, no repurposing of `QUEUE_PRODUCT_KEY` (locked decision #3) | Tasks 1, 2 (`QUEUE_PRODUCT_KEY` left in place) |
| Idempotency of commit (existing MongoDB dedup) | Not changed — confirmed preserved in `InventoryServiceImpl.isEventAlreadyProcessed` |
| Unit tests for Lua (concurrent never-below-0, all-or-nothing) | Task 2 (Lua content assertion + multi-product arg encoding test) |
| DB floor unit test | Task 7 (`InventoryCommitPathTest.dbFloorReturnsZero_*`) |
| Boundary regression test k6 + `oversell-boundary-job.yaml` | Task 11 (exact run steps with SQL verification) |
| Tests pass in CI without infra | All unit tests use plain Mockito, no `@SpringBootTest` |

### 2. Placeholder Scan

No steps in this plan contain "TBD", "TODO", "similar to Task N", "add error handling", or any other placeholder pattern. Every code block is complete.

### 3. Type Consistency

| Symbol | Defined in | Used in |
|---|---|---|
| `PendingOrderCacheRepository.checkAndReserveAvailableAtomic(String, Map<String,Long>)` | Task 2 interface | Task 8 `OrderServiceImpl.validateAndReserveInventoryAtomic` |
| `CHECK_AND_RESERVE_AVAILABLE_LUA_SCRIPT` (static field) | Task 2 impl | Task 2 `captureScript()` reflection test |
| `RedisConstant.AVAILABLE_PRODUCT_KEY = "productAvailable:"` | Task 1 | Tasks 2, 6, 7, 8, 9 (all uses consistent) |
| `MasterInventoryProductRepository.decrementStockIfSufficient(String id, long n): int` | Task 5 | Task 7 `processInventoryUpdate` + Task 7 tests |
| `MasterInventoryProductRepository.adjustStock(String id, long delta): void` | Task 5 | Task 7 `update()` |
| `InventoryProduct.getStock(): Long` | Task 3 | Task 6 `AvailableStockSeeder` |
| `AvailableStockSeeder(SlaveInventoryProductRepository, RedisRepository)` | Task 6 | Task 6 `InventoryServiceConfiguration.availableStockSeeder()` |
| `InventoryServiceImpl(MasterInventoryProductRepository, ...)` | Unchanged | Task 7 tests (`InventoryCommitPathTest` constructor matches existing 9-arg constructor) |
| `OrderServiceImpl(InventoryGrpcClientService, ...)` | Unchanged | Task 8 tests (`OrderReserveAvailableTest` constructor matches existing 10-arg constructor) |

All type names, method signatures, and field names are consistent across all tasks.
