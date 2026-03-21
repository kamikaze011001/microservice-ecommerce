package org.aibles.ecommerce.core_redis.constant;

public class RedisConstant {

    private RedisConstant() {}

    public static final String QUEUE_PRODUCT_KEY = "productQuantityQueue:";

    public static final String LOCK_QUEUE_PRODUCT_KEY = "lock:productQueue:";
}
