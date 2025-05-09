package org.aibles.ecommerce.core_redis.constant;

public class RedisConstant {

    private RedisConstant() {}

    public static final String QUEUE_ORDER_KEY = "orderQueue:";

    public static final String ORDER_PRICE_KEY = "orderPrice:";

    public static final String QUEUE_PRODUCT_KEY = "productQuantityQueue:";

    public static final String LOCK_QUEUE_PRODUCT_KEY = "lock:productQueue:";

    public static final int ORDER_QUEUE_LIVE_DAY = 1;
}
