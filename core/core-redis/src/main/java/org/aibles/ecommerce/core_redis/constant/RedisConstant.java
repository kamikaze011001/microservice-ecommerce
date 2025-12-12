package org.aibles.ecommerce.core_redis.constant;

public class RedisConstant {

    private RedisConstant() {}

    public static final String QUEUE_PRODUCT_KEY = "productQuantityQueue:";

    public static final String LOCK_QUEUE_PRODUCT_KEY = "lock:productQueue:";

    /**
     * Redis ZSET key for tracking pending orders with expiration timestamps.
     * Stores order data including price and product quantities in JSON format.
     * Format: ZADD pendingOrders {expiryTimestamp} "{orderId}:{orderDataJson}"
     * Used for TTL-based cleanup of expired orders and retrieving order information.
     */
    public static final String PENDING_ORDERS_ZSET = "pendingOrders";

    /**
     * Redis Hash key for O(1) order lookup index.
     * Maps orderId to ZSET member for fast retrieval without scanning entire ZSET.
     * Format: HSET pendingOrdersIndex {orderId} "{orderId}:{orderDataJson}"
     */
    public static final String PENDING_ORDERS_INDEX = "pendingOrdersIndex";

    /**
     * Number of hours after which an unpaid order expires.
     * After this time, the cleanup job will rollback the reservation.
     */
    public static final int ORDER_EXPIRY_HOURS = 24;
}
