package org.aibles.order_service.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.redisson.api.RLock;

import java.util.*;

/**
 * Value object that manages the lifecycle of distributed locks.
 * Tracks acquired locks and ensures proper cleanup in reverse order.
 */
@Slf4j
public class DistributedLockContext {

    private final Map<String, RLock> locks = new LinkedHashMap<>();
    private final List<String> productIds;

    public DistributedLockContext(List<String> productIds) {
        this.productIds = new ArrayList<>(productIds);
    }

    /**
     * Adds a successfully acquired lock to the context.
     *
     * @param productId The product ID associated with the lock
     * @param lock      The acquired lock
     */
    public void addLock(String productId, RLock lock) {
        log.debug("(addLock) Adding lock for product: {}", productId);
        locks.put(productId, lock);
    }

    /**
     * Gets a lock for a specific product.
     *
     * @param productId The product ID
     * @return The lock, or null if not found
     */
    public RLock getLock(String productId) {
        return locks.get(productId);
    }

    /**
     * Checks if a lock has been acquired for a product.
     *
     * @param productId The product ID
     * @return true if lock exists in context
     */
    public boolean hasLock(String productId) {
        return locks.containsKey(productId);
    }

    /**
     * Gets all product IDs that need locks.
     *
     * @return Unmodifiable list of product IDs
     */
    public List<String> getProductIds() {
        return Collections.unmodifiableList(productIds);
    }

    /**
     * Gets the number of locks currently held.
     *
     * @return Lock count
     */
    public int getLockCount() {
        return locks.size();
    }

    /**
     * Releases all locks in reverse order to prevent deadlocks.
     * Safe to call multiple times - only releases locks held by current thread.
     */
    public void releaseAllInReverse() {
        log.info("(releaseAllInReverse) Releasing {} locks for products: {}", locks.size(), productIds);

        List<String> reversedProductIds = new ArrayList<>(productIds);
        Collections.reverse(reversedProductIds);

        for (String productId : reversedProductIds) {
            RLock lock = locks.get(productId);
            if (lock != null && lock.isHeldByCurrentThread()) {
                try {
                    lock.unlock();
                    log.debug("(releaseAllInReverse) Released lock for product: {}", productId);
                } catch (Exception e) {
                    log.warn("(releaseAllInReverse) Failed to release lock for product: {}", productId, e);
                }
            }
        }

        locks.clear();
    }

    /**
     * Checks if all locks have been acquired.
     *
     * @return true if all products have locks
     */
    public boolean hasAllLocks() {
        return locks.size() == productIds.size();
    }
}
