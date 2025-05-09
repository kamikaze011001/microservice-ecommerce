package org.aibles.order_service.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.exception.InternalErrorException;
import org.aibles.ecommerce.common_dto.request.InventoryProductIdsRequest;
import org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse;
import org.aibles.ecommerce.common_dto.response.InventoryProductResponse;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.order_service.client.InventoryGrpcClientService;
import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.dto.request.OrderItemRequest;
import org.aibles.order_service.dto.request.OrderRequest;
import org.aibles.order_service.dto.response.OrderCreatedResponse;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.entity.OrderItem;
import org.aibles.order_service.exception.InvalidProductQuantityException;
import org.aibles.order_service.repository.master.MasterOrderItemRepo;
import org.aibles.order_service.repository.master.MasterOrderRepo;
import org.aibles.order_service.service.OrderService;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.transaction.annotation.Transactional;

import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

@Slf4j
public class OrderServiceImpl implements OrderService {

    private static final int LOCK_WAIT_TIME_SECONDS = 5;
    private static final int LOCK_LEASE_TIME_SECONDS = 10;
    private static final int MAX_LOCK_RETRY_ATTEMPTS = 3;
    private static final long INITIAL_BACKOFF_MS = 100;
    private static final Random RANDOM = new Random();

    private final InventoryGrpcClientService inventoryGrpcClientService;
    private final RedisRepository redisRepository;
    private final MasterOrderRepo masterOrderRepo;
    private final MasterOrderItemRepo masterOrderItemRepo;
    private final RedissonClient redissonClient;

    public OrderServiceImpl(InventoryGrpcClientService inventoryGrpcClientService,
                            RedisRepository redisRepository,
                            MasterOrderRepo masterOrderRepo,
                            MasterOrderItemRepo masterOrderItemRepo,
                            RedissonClient redissonClient) {
        this.inventoryGrpcClientService = inventoryGrpcClientService;
        this.redisRepository = redisRepository;
        this.masterOrderRepo = masterOrderRepo;
        this.masterOrderItemRepo = masterOrderItemRepo;
        this.redissonClient = redissonClient;
    }

    @Override
    @Transactional
    public OrderCreatedResponse create(String userId, OrderRequest request) {
        log.info("(create) Creating order for user: {}", userId);

        Map<String, Long> productQuantityMap = getProductQuantityFromRequest(request);
        List<String> productIds = new ArrayList<>(productQuantityMap.keySet());
        Collections.sort(productIds);

        InventoryProductIdsRequest inventoryRequest = new InventoryProductIdsRequest(productIds);
        InventoryProductIdsResponse inventoryResponse;

        Map<String, RLock> locks = new HashMap<>();
        List<String> reservedProducts = new ArrayList<>();

        try {
            for (String productId : productIds) {
                locks.put(productId, acquireLockWithRetry(RedisConstant.LOCK_QUEUE_PRODUCT_KEY + productId));
            }

            inventoryResponse = fetchInventoryData(inventoryRequest);
            validateProductQuantities(inventoryResponse.getInventoryProducts(), productQuantityMap);

            for (Map.Entry<String, Long> entry : productQuantityMap.entrySet()) {
                redisRepository.incr(RedisConstant.QUEUE_PRODUCT_KEY + entry.getKey(), entry.getValue());
                reservedProducts.add(entry.getKey());
            }

            Order order = handleOrderCreation(userId, request, inventoryResponse, productQuantityMap);

            return OrderCreatedResponse.builder()
                    .orderId(order.getId())
                    .build();

        } catch (Exception e) {
            log.error("(create)Exception while create order, rollback reserved products: {} ", reservedProducts, e);
            if (!reservedProducts.isEmpty()) {
                Map<String, Long> productsToRollback = new HashMap<>();
                for (String productId : reservedProducts) {
                    if (productQuantityMap.containsKey(productId)) {
                        productsToRollback.put(productId, productQuantityMap.get(productId));
                    }
                }

                for (Map.Entry<String, Long> entry : productsToRollback.entrySet()) {
                    redisRepository.decr(RedisConstant.QUEUE_PRODUCT_KEY + entry.getKey(), entry.getValue());
                }
            }
            throw e;
        } finally {
            releaseLockInReverse(productIds, locks);
        }
    }


    private Order handleOrderCreation(String userId, OrderRequest request, InventoryProductIdsResponse inventoryResponse, Map<String, Long> productQuantityMap) {
        log.info("(handleOrderCreation) Processing order creation for user: {}", userId);
        Order order = saveOrder(request.getAddress(), request.getPhoneNumber(), userId);
        Map<String, Double> productPriceMap = inventoryResponse.getInventoryProducts().stream()
                .collect(Collectors.toMap(InventoryProductResponse::getId, InventoryProductResponse::getPrice));
        saveOrderItems(request.getItems(), order.getId(), productPriceMap);

        double orderPrice = calculateOrderPrice(productPriceMap, productQuantityMap);

        redisRepository.save(
                RedisConstant.ORDER_PRICE_KEY + order.getId(),
                orderPrice,
                RedisConstant.ORDER_QUEUE_LIVE_DAY,
                TimeUnit.DAYS);

        redisRepository.save(
                RedisConstant.QUEUE_ORDER_KEY + order.getId(),
                productQuantityMap,
                RedisConstant.ORDER_QUEUE_LIVE_DAY,
                TimeUnit.DAYS);
        return order;
    }

    @Override
    @Transactional
    public void handleCanceledOrder(String orderId) {
        log.info("(handleCanceledOrder) Processing canceled order: {}", orderId);
        processOrderStatusChange(orderId, OrderStatus.CANCELED);
    }

    @Override
    @Transactional
    public void handleFailedOrder(String orderId) {
        log.info("(handleFailedOrder) Processing failed order: {}", orderId);
        processOrderStatusChange(orderId, OrderStatus.FAILED);
    }

    @Override
    @Transactional
    public void handleSuccessOrder(String orderId) {
        log.info("(handleSuccessOrder) Processing successful order: {}", orderId);
        processOrderStatusChange(orderId, OrderStatus.COMPLETED);
    }

    private void processOrderStatusChange(String orderId, OrderStatus newStatus) {
        log.info("(processOrderStatusChange) Processing order {} status change to {}", orderId, newStatus);

        Optional<Map<String, Long>> productQuantityMapOptional = redisRepository.getMapStringLong(
                RedisConstant.QUEUE_ORDER_KEY + orderId);

        Map<String, Long> productQuantityMap = productQuantityMapOptional.orElse(new HashMap<>());

        if (productQuantityMap.isEmpty()) {
            log.warn("(processOrderStatusChange) Order ID: {} is invalid or expired", orderId);
            return;
        }

        updateInventoryCacheWithLocks(productQuantityMap);
        updateOrderStatus(orderId, newStatus);
        redisRepository.delete(RedisConstant.ORDER_PRICE_KEY + orderId);

        if (newStatus != OrderStatus.COMPLETED) {
            redisRepository.delete(RedisConstant.QUEUE_ORDER_KEY + orderId);
        }
    }

    private void updateInventoryCacheWithLocks(Map<String, Long> productQuantityMap) {
        log.info("(create) Updating inventory cache with locks for products: {}", productQuantityMap.keySet());
        if (productQuantityMap.isEmpty()) {
            return;
        }

        List<String> productIds = new ArrayList<>(productQuantityMap.keySet());
        Collections.sort(productIds);

        Map<String, RLock> locks = new HashMap<>();

        try {
            for (String productId : productIds) {
                locks.put(productId, acquireLockWithRetry(RedisConstant.LOCK_QUEUE_PRODUCT_KEY + productId));
            }

            for (Map.Entry<String, Long> entry : productQuantityMap.entrySet()) {
                redisRepository.decr(RedisConstant.QUEUE_PRODUCT_KEY + entry.getKey(), entry.getValue());
            }

        } finally {
            releaseLockInReverse(productIds, locks);
        }
    }

    private RLock acquireLockWithRetry(String lockKey) {
        log.info("(acquireLockWithRetry) Acquiring lock with key : {}", lockKey);
        RLock lock = redissonClient.getFairLock(lockKey);
        int retryCount = 0;

        while (retryCount < MAX_LOCK_RETRY_ATTEMPTS) {
            try {
                if (retryCount > 0) {
                    long backoffTime = INITIAL_BACKOFF_MS * (long)Math.pow(2, (retryCount - 1));
                    backoffTime += RANDOM.nextInt((int)(backoffTime * 0.2));
                    Thread.sleep(backoffTime);
                }

                if (lock.tryLock(LOCK_WAIT_TIME_SECONDS, LOCK_LEASE_TIME_SECONDS, TimeUnit.SECONDS)) {
                    return lock;
                }

                retryCount++;

            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                log.error("(acquireLockWithRetry) Interrupted while waiting for lock with key : {}", lockKey, e);
                throw new InternalErrorException();
            }
        }
        log.error("(acquireLockWithRetry) Failed to acquire lock after multiple attempts with key : {}", lockKey);
        throw new InternalErrorException();
    }

    private void updateOrderStatus(String orderId, OrderStatus status) {
        log.info("(updateOrderStatus) Updating order {} status to {}", orderId, status);
        masterOrderRepo.updateStatus(orderId, status);
    }

    private Map<String, Long> getProductQuantityFromRequest(OrderRequest orderRequest) {
        log.info("(getProductQuantityFromRequest) Converting order items to product quantity map: {}", orderRequest.getItems());
        return orderRequest.getItems().stream()
                .collect(Collectors.toMap(
                        OrderItemRequest::getProductId,
                        OrderItemRequest::getQuantity,
                        Long::sum
                ));
    }

    private void validateProductQuantities(
            List<InventoryProductResponse> inventoryProducts,
            Map<String, Long> productQuantityMap) {
        log.info("(validateProductQuantities) Validating product quantities: {}", productQuantityMap);
        Map<String, InventoryProductResponse> productMap = inventoryProducts.stream()
                .collect(Collectors.toMap(InventoryProductResponse::getId, p -> p));

        log.info("(validateProductQuantities) Inventory products: {}", productMap);

        List<String> invalidProducts = new ArrayList<>();
        String cacheKey;
        long queuedQuantity;
        for (Map.Entry<String, Long> entry : productQuantityMap.entrySet()) {
            InventoryProductResponse product = productMap.get(entry.getKey());

            if (product == null || product.getQuantity() == null) {
                invalidProducts.add(entry.getKey());
                continue;
            }

            cacheKey = RedisConstant.QUEUE_PRODUCT_KEY + entry.getKey();
            queuedQuantity = redisRepository.getLong(cacheKey).orElse(0L);
            log.info("(validateProductQuantities) Product: {}, queued quantity: {}, quantity request : {}", product.getQuantity(), queuedQuantity, entry.getValue());
            if (product.getQuantity() - entry.getValue() - queuedQuantity < 0) {
                invalidProducts.add(product.getName() != null ? product.getName() : entry.getKey());
            }
        }

        if (!invalidProducts.isEmpty()) {
            throw new InvalidProductQuantityException(invalidProducts);
        }
    }

    private Order saveOrder(String address, String phoneNumber, String userId) {
        log.info("(saveOrder) Saving order for user: {}", userId);
        Order order = Order.builder()
                .status(OrderStatus.PROCESSING)
                .userId(userId)
                .address(address)
                .phoneNumber(phoneNumber)
                .build();

        return masterOrderRepo.save(order);
    }

    private void saveOrderItems(List<OrderItemRequest> orderItems, String orderId, Map<String, Double> itemPriceMap) {
        log.info("(saveOrderItems) Saving order items for order: {}", orderId);
        List<OrderItem> items = orderItems.stream()
                .map(item -> OrderItem.builder()
                        .orderId(orderId)
                        .productId(item.getProductId())
                        .price(itemPriceMap.get(item.getProductId()) != null ? itemPriceMap.get(item.getProductId()) : 0.0)
                        .quantity(item.getQuantity())
                        .build())
                .toList();

        masterOrderItemRepo.saveAll(items);
    }

    private double calculateOrderPrice(
            Map<String, Double> productPriceMap,
            Map<String, Long> productQuantityMap) {
        log.info("(calculateOrderPrice) Calculating order price for products: {}", productQuantityMap);
        return productQuantityMap.entrySet().stream()
                .mapToDouble(entry -> {
                    Double productPrice = productPriceMap.get(entry.getKey());
                    return productPrice != null ? productPrice * entry.getValue() : 0.0;
                })
                .sum();
    }

    private InventoryProductIdsResponse fetchInventoryData(InventoryProductIdsRequest request) {
        log.info("(fetchInventoryData)request: {} ", request);
        return inventoryGrpcClientService.fetchInventoryData(request.getIds());
    }

    private void releaseLockInReverse(List<String> productIds, Map<String, RLock> locks) {
        log.info("(releaseLockInReverse) Releasing locks for products: {}", productIds);
        List<String> reversedProductIds = new ArrayList<>(productIds);
        Collections.reverse(reversedProductIds);

        for (String productId : reversedProductIds) {
            RLock lock = locks.get(productId);
            if (lock != null && lock.isHeldByCurrentThread()) {
                lock.unlock();
            }
        }
    }
}
