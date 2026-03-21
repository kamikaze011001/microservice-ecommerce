package org.aibles.ecommerce.core_order_cache.repository.impl;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_order_cache.constant.OrderCacheConstant;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.springframework.data.redis.connection.ReturnType;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.RedisTemplate;

import java.nio.charset.StandardCharsets;
import java.util.*;

@Slf4j
public class PendingOrderCacheRepositoryImpl implements PendingOrderCacheRepository {

    private final RedisTemplate<String, Object> redisTemplate;
    private final ObjectMapper objectMapper;

    /**
     * Lua script for atomic check-and-reserve operation.
     * This ensures that inventory checks and reservations happen atomically,
     * preventing race conditions (TOCTOU vulnerabilities).
     *
     * Script logic:
     * 1. Parse input arrays of product IDs, quantities, and max inventory
     * 2. For each product, check if (current_queued + requested) <= max_inventory
     * 3. If any product fails, return 0 (rollback, nothing reserved)
     * 4. If all pass, increment all products and return 1 (success)
     */
    private static final String CHECK_AND_RESERVE_LUA_SCRIPT =
            "local keyPrefix = ARGV[1]\n" +
            "local numProducts = tonumber(ARGV[2])\n" +
            "local argOffset = 3\n" +
            "\n" +
            "-- Parse input: productIds, quantities, maxInventory\n" +
            "local productIds = {}\n" +
            "local quantities = {}\n" +
            "local maxInventory = {}\n" +
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
            "for i = 1, numProducts do\n" +
            "    maxInventory[i] = tonumber(ARGV[argOffset])\n" +
            "    argOffset = argOffset + 1\n" +
            "end\n" +
            "\n" +
            "-- Phase 1: Check all products\n" +
            "for i = 1, numProducts do\n" +
            "    local key = keyPrefix .. productIds[i]\n" +
            "    local currentQueued = tonumber(redis.call('GET', key)) or 0\n" +
            "    local requested = quantities[i]\n" +
            "    local max = maxInventory[i]\n" +
            "    \n" +
            "    if currentQueued + requested > max then\n" +
            "        return 0  -- Insufficient inventory, abort\n" +
            "    end\n" +
            "end\n" +
            "\n" +
            "-- Phase 2: All checks passed, reserve all products\n" +
            "for i = 1, numProducts do\n" +
            "    local key = keyPrefix .. productIds[i]\n" +
            "    redis.call('INCRBY', key, quantities[i])\n" +
            "end\n" +
            "\n" +
            "return 1  -- Success\n";

    public PendingOrderCacheRepositoryImpl(RedisTemplate<String, Object> redisTemplate, ObjectMapper objectMapper) {
        this.redisTemplate = redisTemplate;
        this.objectMapper = objectMapper;
    }

    @Override
    public boolean checkAndReserveAtomic(String keyPrefix, Map<String, Long> productQuantities, Map<String, Long> maxInventory) {
        log.info("(checkAndReserveAtomic) Executing atomic check-and-reserve for {} products with keyPrefix: {}",
                productQuantities.size(), keyPrefix);

        if (productQuantities.isEmpty()) {
            log.warn("(checkAndReserveAtomic) Empty product quantities map, nothing to reserve");
            return true;
        }

        // Prepare script arguments
        List<String> args = new ArrayList<>();
        args.add(keyPrefix);  // ARGV[1]
        args.add(String.valueOf(productQuantities.size()));  // ARGV[2]

        // Add product IDs
        List<String> productIds = new ArrayList<>(productQuantities.keySet());
        args.addAll(productIds);

        // Add quantities
        for (String productId : productIds) {
            args.add(String.valueOf(productQuantities.get(productId)));
        }

        // Add max inventory
        for (String productId : productIds) {
            Long maxQty = maxInventory.get(productId);
            if (maxQty == null) {
                log.error("(checkAndReserveAtomic) Max inventory not found for product: {}", productId);
                return false;
            }
            args.add(String.valueOf(maxQty));
        }

        // Execute Lua script using RedisCallback for complete control over serialization
        try {
            Long result = redisTemplate.execute((RedisCallback<Long>) connection -> {
                // Convert all args to raw bytes - this ensures Lua receives plain strings
                byte[][] argBytes = args.stream()
                        .map(arg -> arg.getBytes(StandardCharsets.UTF_8))
                        .toArray(byte[][]::new);

                // Execute eval with 0 keys (all data passed via ARGV)
                return connection.scriptingCommands().eval(
                        CHECK_AND_RESERVE_LUA_SCRIPT.getBytes(StandardCharsets.UTF_8),
                        ReturnType.INTEGER,
                        0,
                        argBytes
                );
            });

            boolean success = result != null && result == 1L;
            if (success) {
                log.info("(checkAndReserveAtomic) Successfully reserved inventory for products: {}", productIds);
            } else {
                log.warn("(checkAndReserveAtomic) Failed to reserve inventory - insufficient stock for products: {}", productIds);
            }

            return success;
        } catch (Exception e) {
            log.error("(checkAndReserveAtomic) Exception while executing Lua script", e);
            return false;
        }
    }

    @Override
    public void addToPendingOrders(String orderId, double orderPrice, Map<String, Long> productQuantities, long expiryTimestampMillis) {
        log.info("(addToPendingOrders) Adding order {} to pending orders ZSET with price: {}, expiry: {}",
                orderId, orderPrice, expiryTimestampMillis);

        try {
            // Create order data structure with price and products
            Map<String, Object> orderData = new HashMap<>();
            orderData.put("price", orderPrice);
            orderData.put("products", productQuantities);

            // Serialize order data to JSON
            String orderDataJson = objectMapper.writeValueAsString(orderData);

            // Create ZSET member: orderId:jsonData
            String zsetMember = orderId + ":" + orderDataJson;

            // Add to ZSET with expiry timestamp as score
            redisTemplate.opsForZSet().add(
                    OrderCacheConstant.PENDING_ORDERS_ZSET,
                    zsetMember,
                    expiryTimestampMillis
            );

            // Add to Hash index for O(1) lookup
            redisTemplate.opsForHash().put(
                    OrderCacheConstant.PENDING_ORDERS_INDEX,
                    orderId,
                    zsetMember
            );

            log.debug("(addToPendingOrders) Successfully added order {} to pending orders and index", orderId);
        } catch (JsonProcessingException e) {
            log.error("(addToPendingOrders) Failed to serialize order data for order: {}", orderId, e);
            throw new RuntimeException("Failed to serialize order data", e);
        }
    }

    @Override
    public Map<String, Map<String, Long>> getExpiredOrders(long currentTimestampMillis) {
        log.info("(getExpiredOrders) Fetching expired orders with timestamp < {}", currentTimestampMillis);

        try {
            // Get all ZSET members with score (expiry time) less than current time
            Set<Object> expiredMembers = redisTemplate.opsForZSet().rangeByScore(
                    OrderCacheConstant.PENDING_ORDERS_ZSET,
                    0,
                    currentTimestampMillis
            );

            if (expiredMembers == null || expiredMembers.isEmpty()) {
                log.info("(getExpiredOrders) No expired orders found");
                return Collections.emptyMap();
            }

            log.info("(getExpiredOrders) Found {} expired orders", expiredMembers.size());

            Map<String, Map<String, Long>> expiredOrders = new HashMap<>();

            for (Object memberObj : expiredMembers) {
                String member = memberObj.toString();

                // Parse member: orderId:jsonData
                int separatorIndex = member.indexOf(':');
                if (separatorIndex == -1) {
                    log.warn("(getExpiredOrders) Invalid member format (missing separator): {}", member);
                    continue;
                }

                String orderId = member.substring(0, separatorIndex);
                String orderDataJson = member.substring(separatorIndex + 1);

                try {
                    // Deserialize order data (contains price and products)
                    Map<String, Object> orderData = objectMapper.readValue(
                            orderDataJson,
                            new TypeReference<Map<String, Object>>() {}
                    );

                    // Extract products from order data
                    Object productsObj = orderData.get("products");
                    if (productsObj instanceof Map<?, ?> rawMap) {
                        Map<String, Long> productQuantities = new HashMap<>();
                        for (Map.Entry<?, ?> entry : rawMap.entrySet()) {
                            if (entry.getKey() instanceof String key && entry.getValue() instanceof Number value) {
                                productQuantities.put(key, value.longValue());
                            }
                        }
                        expiredOrders.put(orderId, productQuantities);
                    } else {
                        log.warn("(getExpiredOrders) Invalid products data for order: {}", orderId);
                    }
                } catch (JsonProcessingException e) {
                    log.error("(getExpiredOrders) Failed to deserialize order data for order: {}", orderId, e);
                }
            }

            return expiredOrders;
        } catch (Exception e) {
            log.error("(getExpiredOrders) Exception while fetching expired orders", e);
            return Collections.emptyMap();
        }
    }

    @Override
    public void removeFromPendingOrders(String orderId) {
        log.info("(removeFromPendingOrders) Removing order {} from pending orders", orderId);

        try {
            // O(1) lookup from Hash index instead of O(n) ZSET scan
            Object zsetMemberObj = redisTemplate.opsForHash().get(
                    OrderCacheConstant.PENDING_ORDERS_INDEX,
                    orderId
            );

            if (zsetMemberObj == null) {
                log.debug("(removeFromPendingOrders) Order {} not found in pending orders", orderId);
                return;
            }

            String zsetMember = zsetMemberObj.toString();

            // Remove from ZSET
            redisTemplate.opsForZSet().remove(OrderCacheConstant.PENDING_ORDERS_ZSET, zsetMember);

            // Remove from Hash index
            redisTemplate.opsForHash().delete(OrderCacheConstant.PENDING_ORDERS_INDEX, orderId);

            log.debug("(removeFromPendingOrders) Removed order {} from pending orders and index", orderId);
        } catch (Exception e) {
            log.error("(removeFromPendingOrders) Exception while removing order from pending orders", e);
        }
    }

    @Override
    public Optional<Map<String, Long>> getProductQuantitiesForOrder(String orderId) {
        log.info("(getProductQuantitiesForOrder) Fetching product quantities for order: {}", orderId);

        try {
            // O(1) lookup from Hash index instead of O(n) ZSET scan
            Object zsetMemberObj = redisTemplate.opsForHash().get(
                    OrderCacheConstant.PENDING_ORDERS_INDEX,
                    orderId
            );

            if (zsetMemberObj == null) {
                log.debug("(getProductQuantitiesForOrder) Order {} not found in pending orders", orderId);
                return Optional.empty();
            }

            String zsetMember = zsetMemberObj.toString();

            // Extract JSON from member (format: orderId:jsonData)
            int separatorIndex = zsetMember.indexOf(':');
            if (separatorIndex == -1) {
                log.warn("(getProductQuantitiesForOrder) Invalid member format for order: {}", orderId);
                return Optional.empty();
            }

            String orderDataJson = zsetMember.substring(separatorIndex + 1);

            // Deserialize order data
            Map<String, Object> orderData = objectMapper.readValue(
                    orderDataJson,
                    new TypeReference<Map<String, Object>>() {}
            );

            // Extract products
            Object productsObj = orderData.get("products");
            if (productsObj instanceof Map<?, ?> rawMap) {
                Map<String, Long> productQuantities = new HashMap<>();
                for (Map.Entry<?, ?> entry : rawMap.entrySet()) {
                    if (entry.getKey() instanceof String key && entry.getValue() instanceof Number value) {
                        productQuantities.put(key, value.longValue());
                    }
                }
                log.debug("(getProductQuantitiesForOrder) Found product quantities for order: {}", orderId);
                return Optional.of(productQuantities);
            }

            log.warn("(getProductQuantitiesForOrder) Invalid products data for order: {}", orderId);
            return Optional.empty();
        } catch (Exception e) {
            log.error("(getProductQuantitiesForOrder) Exception while fetching product quantities for order: {}", orderId, e);
            return Optional.empty();
        }
    }

    @Override
    public Optional<Double> getOrderPrice(String orderId) {
        log.info("(getOrderPrice) Fetching order price for order: {}", orderId);

        try {
            // O(1) lookup from Hash index instead of O(n) ZSET scan
            Object zsetMemberObj = redisTemplate.opsForHash().get(
                    OrderCacheConstant.PENDING_ORDERS_INDEX,
                    orderId
            );

            if (zsetMemberObj == null) {
                log.debug("(getOrderPrice) Order {} not found in pending orders", orderId);
                return Optional.empty();
            }

            String zsetMember = zsetMemberObj.toString();

            // Extract JSON from member (format: orderId:jsonData)
            int separatorIndex = zsetMember.indexOf(':');
            if (separatorIndex == -1) {
                log.warn("(getOrderPrice) Invalid member format for order: {}", orderId);
                return Optional.empty();
            }

            String orderDataJson = zsetMember.substring(separatorIndex + 1);

            // Deserialize order data
            Map<String, Object> orderData = objectMapper.readValue(
                    orderDataJson,
                    new TypeReference<Map<String, Object>>() {}
            );

            // Extract price
            Object priceObj = orderData.get("price");
            if (priceObj instanceof Number) {
                double price = ((Number) priceObj).doubleValue();
                log.debug("(getOrderPrice) Found price {} for order: {}", price, orderId);
                return Optional.of(price);
            }

            log.warn("(getOrderPrice) Invalid price data for order: {}", orderId);
            return Optional.empty();
        } catch (Exception e) {
            log.error("(getOrderPrice) Exception while fetching order price for order: {}", orderId, e);
            return Optional.empty();
        }
    }
}
