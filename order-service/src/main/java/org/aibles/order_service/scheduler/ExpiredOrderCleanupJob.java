package org.aibles.order_service.scheduler;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.*;
import java.util.concurrent.TimeUnit;

/**
 * Scheduled job that cleans up expired orders from the pending orders ZSET.
 *
 * Runs every 30 minutes to find orders that expired (user didn't pay within 24 hours)
 * and rolls back their inventory reservations.
 *
 * This prevents inventory leaks where products remain reserved forever
 * after the orderQueue:{orderId} TTL expires.
 */
@Component
@Slf4j
public class ExpiredOrderCleanupJob {

    private static final int LOCK_WAIT_TIME_SECONDS = 5;
    private static final int LOCK_LEASE_TIME_SECONDS = 10;

    private final RedisRepository redisRepository;
    private final RedissonClient redissonClient;

    public ExpiredOrderCleanupJob(RedisRepository redisRepository, RedissonClient redissonClient) {
        this.redisRepository = redisRepository;
        this.redissonClient = redissonClient;
    }

    /**
     * Runs every 30 minutes to clean up expired orders.
     * Cron: At minute 0 and 30 of every hour
     **/
    @Scheduled(cron = "0 */30 * * * *")
    public void cleanupExpiredOrders() {
        log.info("(cleanupExpiredOrders) Starting expired order cleanup job");

        try {
            // Get current timestamp
            long currentTimestamp = Instant.now().toEpochMilli();

            // Fetch expired orders from ZSET
            Map<String, Map<String, Long>> expiredOrders = getExpiredOrdersFromRedis(currentTimestamp);

            if (expiredOrders.isEmpty()) {
                log.info("(cleanupExpiredOrders) No expired orders found");
                return;
            }

            log.warn("(cleanupExpiredOrders) Found {} expired orders to clean up", expiredOrders.size());

            // Process each expired order
            int successCount = 0;
            int failCount = 0;

            for (Map.Entry<String, Map<String, Long>> entry : expiredOrders.entrySet()) {
                String orderId = entry.getKey();
                Map<String, Long> productQuantities = entry.getValue();

                try {
                    rollbackExpiredOrder(orderId, productQuantities);
                    successCount++;
                } catch (Exception e) {
                    log.error("(cleanupExpiredOrders) Failed to rollback expired order: {}", orderId, e);
                    failCount++;
                }
            }

            log.info("(cleanupExpiredOrders) Cleanup completed. Success: {}, Failed: {}", successCount, failCount);
        } catch (Exception e) {
            log.error("(cleanupExpiredOrders) Unexpected error during cleanup job", e);
        }
    }

    /**
     * Fetches expired orders from pending orders ZSET.
     */
    private Map<String, Map<String, Long>> getExpiredOrdersFromRedis(long currentTimestamp) {
        log.debug("(getExpiredOrdersFromRedis) Fetching expired orders with timestamp < {}", currentTimestamp);
        return redisRepository.getExpiredOrders(currentTimestamp);
    }

    /**
     * Rolls back inventory reservation for an expired order.
     *
     * Steps:
     * 1. Acquire distributed locks for all products (in sorted order)
     * 2. Decrement productQuantityQueue for each product
     * 3. Remove order from pending orders ZSET
     * 4. Delete order metadata (orderQueue, orderPrice)
     * 5. Release locks
     */
    private void rollbackExpiredOrder(String orderId, Map<String, Long> productQuantities) {
        log.warn("(rollbackExpiredOrder) Rolling back expired order: {} with products: {}",
                orderId, productQuantities);

        if (productQuantities == null || productQuantities.isEmpty()) {
            log.warn("(rollbackExpiredOrder) No products to rollback for order: {}", orderId);
            cleanupExpiredOrderMetadata(orderId);
            return;
        }

        // Get sorted product IDs for deterministic lock acquisition
        List<String> productIds = new ArrayList<>(productQuantities.keySet());
        Collections.sort(productIds);

        Map<String, RLock> locks = new HashMap<>();

        try {
            // Acquire locks in sorted order to prevent deadlocks
            acquireLocksForProducts(productIds, locks);

            // Rollback inventory reservations
            rollbackProductReservations(productQuantities);

            // Cleanup order metadata
            cleanupExpiredOrderMetadata(orderId);

            log.info("(rollbackExpiredOrder) Successfully rolled back expired order: {}", orderId);
        } finally {
            releaseLocksInReverse(productIds, locks);
        }
    }

    /**
     * Acquires distributed locks for all products.
     */
    private void acquireLocksForProducts(List<String> productIds, Map<String, RLock> locks) {
        log.debug("(acquireLocksForProducts) Acquiring locks for {} products", productIds.size());

        for (String productId : productIds) {
            String lockKey = RedisConstant.LOCK_QUEUE_PRODUCT_KEY + productId;
            RLock lock = redissonClient.getFairLock(lockKey);

            try {
                if (lock.tryLock(LOCK_WAIT_TIME_SECONDS, LOCK_LEASE_TIME_SECONDS, TimeUnit.SECONDS)) {
                    locks.put(productId, lock);
                } else {
                    log.error("(acquireLocksForProducts) Failed to acquire lock for product: {}", productId);
                    throw new RuntimeException("Failed to acquire lock for product: " + productId);
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                log.error("(acquireLocksForProducts) Interrupted while acquiring lock for product: {}", productId, e);
                throw new RuntimeException("Interrupted while acquiring lock", e);
            }
        }
    }

    /**
     * Rolls back product quantity reservations by decrementing Redis queue.
     */
    private void rollbackProductReservations(Map<String, Long> productQuantities) {
        log.debug("(rollbackProductReservations) Rolling back reservations for {} products", productQuantities.size());

        for (Map.Entry<String, Long> entry : productQuantities.entrySet()) {
            String productId = entry.getKey();
            Long quantity = entry.getValue();

            try {
                redisRepository.decr(RedisConstant.QUEUE_PRODUCT_KEY + productId, quantity);
                log.debug("(rollbackProductReservations) Rolled back {} units for product: {}", quantity, productId);
            } catch (Exception e) {
                log.error("(rollbackProductReservations) Failed to rollback product: {}", productId, e);
            }
        }
    }

    /**
     * Cleans up order metadata from Redis.
     */
    private void cleanupExpiredOrderMetadata(String orderId) {
        log.debug("(cleanupExpiredOrderMetadata) Cleaning up metadata for order: {}", orderId);

        try {
            // Remove from pending orders ZSET (this also removes price and product quantities)
            redisRepository.removeFromPendingOrders(orderId);

            log.debug("(cleanupExpiredOrderMetadata) Cleaned up metadata for order: {}", orderId);
        } catch (Exception e) {
            log.error("(cleanupExpiredOrderMetadata) Failed to cleanup metadata for order: {}", orderId, e);
        }
    }

    /**
     * Releases locks in reverse order (LIFO) for proper cleanup.
     */
    private void releaseLocksInReverse(List<String> productIds, Map<String, RLock> locks) {
        log.debug("(releaseLocksInReverse) Releasing {} locks", locks.size());

        // Release in reverse order
        for (int i = productIds.size() - 1; i >= 0; i--) {
            String productId = productIds.get(i);
            RLock lock = locks.get(productId);

            if (lock != null && lock.isHeldByCurrentThread()) {
                try {
                    lock.unlock();
                    log.debug("(releaseLocksInReverse) Released lock for product: {}", productId);
                } catch (Exception e) {
                    log.warn("(releaseLocksInReverse) Failed to release lock for product: {}", productId, e);
                }
            }
        }
    }
}