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
