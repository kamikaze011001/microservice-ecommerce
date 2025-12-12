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
import org.aibles.order_service.entity.ProcessedPaymentEvent;
import org.aibles.order_service.repository.ProcessedPaymentEventRepository;
import org.aibles.order_service.repository.master.MasterOrderItemRepo;
import org.aibles.order_service.repository.master.MasterOrderRepo;
import org.aibles.order_service.service.OrderService;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.time.LocalDateTime;
import java.time.temporal.ChronoUnit;
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
    private final ProcessedPaymentEventRepository processedPaymentEventRepository;

    public OrderServiceImpl(InventoryGrpcClientService inventoryGrpcClientService,
                            RedisRepository redisRepository,
                            MasterOrderRepo masterOrderRepo,
                            MasterOrderItemRepo masterOrderItemRepo,
                            RedissonClient redissonClient,
                            ProcessedPaymentEventRepository processedPaymentEventRepository) {
        this.inventoryGrpcClientService = inventoryGrpcClientService;
        this.redisRepository = redisRepository;
        this.masterOrderRepo = masterOrderRepo;
        this.masterOrderItemRepo = masterOrderItemRepo;
        this.redissonClient = redissonClient;
        this.processedPaymentEventRepository = processedPaymentEventRepository;
    }

    @Override
    @Transactional
    public OrderCreatedResponse create(String userId, OrderRequest request) {
        log.info("(create) Creating order for user: {}", userId);

        // Step 1: Build product quantity map from request
        Map<String, Long> productQuantityMap = buildProductQuantityMap(request);

        // Step 2: Get deterministically ordered product IDs for deadlock prevention
        List<String> sortedProductIds = getSortedProductIds(productQuantityMap);

        // Step 3: Execute order creation with distributed locks
        String orderId = executeWithDistributedLocks(userId, request, productQuantityMap, sortedProductIds);

        return OrderCreatedResponse.builder()
                .orderId(orderId)
                .build();
    }

    /**
     * Builds a map of product ID to quantity from order request.
     * Aggregates quantities if same product appears multiple times.
     */
    private Map<String, Long> buildProductQuantityMap(OrderRequest request) {
        log.info("(buildProductQuantityMap) Converting order items to product quantity map");
        return request.getItems().stream()
                .collect(Collectors.toMap(
                        OrderItemRequest::getProductId,
                        OrderItemRequest::getQuantity,
                        Long::sum
                ));
    }

    /**
     * Returns sorted list of product IDs for deterministic lock acquisition order.
     * This prevents deadlocks when multiple orders try to lock the same products.
     */
    private List<String> getSortedProductIds(Map<String, Long> productQuantityMap) {
        List<String> productIds = new ArrayList<>(productQuantityMap.keySet());
        Collections.sort(productIds);
        return productIds;
    }

    /**
     * Executes order creation with distributed locks to ensure thread safety.
     * Manages full lifecycle: acquire locks → validate → reserve → create order → release locks.
     */
    private String executeWithDistributedLocks(String userId, OrderRequest request,
                                                Map<String, Long> productQuantityMap,
                                                List<String> sortedProductIds) {
        DistributedLockContext lockContext = new DistributedLockContext(sortedProductIds);
        boolean inventoryReserved = false;

        try {
            // Acquire all locks in deterministic order
            acquireAllLocks(lockContext);

            // Validate and atomically reserve inventory
            InventoryReservationResult reservation = validateAndReserveInventoryAtomic(productQuantityMap, sortedProductIds);
            inventoryReserved = true;  // Only set to true AFTER successful reservation

            // Create order and persist metadata to cache
            Order order = persistOrderAndMetadata(userId, request, reservation);

            return order.getId();

        } catch (Exception e) {
            log.error("(executeWithDistributedLocks) Exception during order creation", e);
            // Only rollback if inventory was actually reserved
            if (inventoryReserved) {
                log.warn("(executeWithDistributedLocks) Inventory was reserved, initiating rollback");
                rollbackInventoryReservation(productQuantityMap);
            } else {
                log.debug("(executeWithDistributedLocks) Inventory was not reserved, skipping rollback");
            }
            throw e;
        } finally {
            lockContext.releaseAllInReverse();
        }
    }

    /**
     * Acquires distributed locks for all products in the lock context.
     */
    private void acquireAllLocks(DistributedLockContext lockContext) {
        log.info("(acquireAllLocks) Acquiring {} locks", lockContext.getProductIds().size());

        for (String productId : lockContext.getProductIds()) {
            String lockKey = RedisConstant.LOCK_QUEUE_PRODUCT_KEY + productId;
            RLock lock = acquireLockWithRetry(lockKey, lockContext);
            lockContext.addLock(productId, lock);
        }
    }

    /**
     * Validates inventory availability and atomically reserves products.
     * Uses Lua script to prevent TOCTOU race conditions.
     */
    private InventoryReservationResult validateAndReserveInventoryAtomic(
            Map<String, Long> productQuantityMap,
            List<String> productIds) {

        log.info("(validateAndReserveInventoryAtomic) Validating and reserving inventory for {} products", productIds.size());

        // Fetch inventory data from inventory service
        InventoryProductIdsRequest inventoryRequest = new InventoryProductIdsRequest(productIds);
        InventoryProductIdsResponse inventoryResponse = fetchInventoryData(inventoryRequest);

        // Build price map and validate all prices exist
        Map<String, Double> priceMap = buildAndValidatePriceMap(inventoryResponse);

        // Build max inventory map for atomic reservation
        Map<String, Long> maxInventoryMap = inventoryResponse.getInventoryProducts().stream()
                .filter(p -> p.getQuantity() != null)
                .collect(Collectors.toMap(
                        InventoryProductResponse::getId,
                        InventoryProductResponse::getQuantity
                ));

        // Validate product existence (availability check is done atomically by Lua script)
        validateProductExistence(inventoryResponse.getInventoryProducts(), productQuantityMap);

        // Atomically check and reserve using Lua script
        boolean reserved = redisRepository.checkAndReserveAtomic(
                RedisConstant.QUEUE_PRODUCT_KEY,
                productQuantityMap,
                maxInventoryMap
        );

        if (!reserved) {
            log.error("(validateAndReserveInventoryAtomic) Atomic reservation failed - race condition detected or insufficient inventory");
            throw new InvalidProductQuantityException(new ArrayList<>(productIds));
        }

        // Calculate total order price
        double totalPrice = calculateTotalPrice(priceMap, productQuantityMap);

        return InventoryReservationResult.builder()
                .inventoryResponse(inventoryResponse)
                .priceMap(priceMap)
                .totalOrderPrice(totalPrice)
                .reservedQuantities(productQuantityMap)
                .build();
    }

    /**
     * Builds price map from inventory response and validates all prices are present.
     * Throws exception if any price is missing.
     */
    private Map<String, Double> buildAndValidatePriceMap(InventoryProductIdsResponse inventoryResponse) {
        Map<String, Double> priceMap = new HashMap<>();

        for (InventoryProductResponse product : inventoryResponse.getInventoryProducts()) {
            validatePriceForProduct(product);
            priceMap.put(product.getId(), product.getPrice());
        }

        return priceMap;
    }

    /**
     * Validates that a product has a non-null price.
     * Throws InternalErrorException if price is missing.
     */
    private void validatePriceForProduct(InventoryProductResponse product) {
        if (product.getPrice() == null) {
            log.error("(validatePriceForProduct) Product {} has null price - data integrity issue", product.getId());
            throw new InternalErrorException();
        }
    }

    /**
     * Validates that all requested products exist and have valid inventory data.
     * Availability check is handled atomically by Lua script in checkAndReserveAtomic().
     */
    private void validateProductExistence(
            List<InventoryProductResponse> inventoryProducts,
            Map<String, Long> productQuantityMap) {

        log.info("(validateProductExistence) Validating product existence");

        Map<String, InventoryProductResponse> productMap = inventoryProducts.stream()
                .collect(Collectors.toMap(InventoryProductResponse::getId, p -> p));

        List<String> invalidProducts = new ArrayList<>();

        for (String productId : productQuantityMap.keySet()) {
            InventoryProductResponse product = productMap.get(productId);

            if (product == null || product.getQuantity() == null) {
                invalidProducts.add(productId);
            }
        }

        if (!invalidProducts.isEmpty()) {
            log.error("(validateProductExistence) Products not found or have invalid data: {}", invalidProducts);
            throw new InvalidProductQuantityException(invalidProducts);
        }
    }

    /**
     * Calculates total order price from price map and quantities.
     * All prices are guaranteed to be non-null at this point.
     */
    private double calculateTotalPrice(Map<String, Double> priceMap, Map<String, Long> productQuantityMap) {
        log.info("(calculateTotalPrice) Calculating total price for order");
        return productQuantityMap.entrySet().stream()
                .mapToDouble(entry -> priceMap.get(entry.getKey()) * entry.getValue())
                .sum();
    }

    /**
     * Creates order entity and persists all metadata to Redis cache.
     */
    private Order persistOrderAndMetadata(String userId, OrderRequest request, InventoryReservationResult reservation) {
        log.info("(persistOrderAndMetadata) Persisting order and metadata for user: {}", userId);

        // Create and save order entity
        Order order = saveOrder(request.getAddress(), request.getPhoneNumber(), userId);

        // Save order items
        saveOrderItems(request.getItems(), order.getId(), reservation.getPriceMap());

        // Add to pending orders ZSET (stores price AND product quantities)
        long expiryTimestamp = Instant.now()
                .plus(RedisConstant.ORDER_EXPIRY_HOURS, ChronoUnit.HOURS)
                .toEpochMilli();

        redisRepository.addToPendingOrders(
                order.getId(),
                reservation.getTotalOrderPrice(),
                reservation.getReservedQuantities(),
                expiryTimestamp
        );

        log.debug("(persistOrderAndMetadata) Added order {} to pending orders with price: {}, expiry: {}",
                order.getId(), reservation.getTotalOrderPrice(), expiryTimestamp);

        return order;
    }

    /**
     * Rolls back inventory reservations by decrementing Redis counters.
     */
    private void rollbackInventoryReservation(Map<String, Long> productQuantityMap) {
        if (productQuantityMap == null || productQuantityMap.isEmpty()) {
            return;
        }

        log.warn("(rollbackInventoryReservation) Rolling back reservations for {} products", productQuantityMap.size());

        for (Map.Entry<String, Long> entry : productQuantityMap.entrySet()) {
            try {
                redisRepository.decr(RedisConstant.QUEUE_PRODUCT_KEY + entry.getKey(), entry.getValue());
                log.debug("(rollbackInventoryReservation) Rolled back {} units for product {}", entry.getValue(), entry.getKey());
            } catch (Exception e) {
                log.error("(rollbackInventoryReservation) Failed to rollback product: {}", entry.getKey(), e);
            }
        }
    }

    @Override
    @Transactional
    public void handleCanceledOrder(String orderId) {
        log.info("(handleCanceledOrder) Processing canceled order: {}", orderId);

        // Idempotency check: Skip if already processed
        // If this returns false, the record is ALREADY saved by isEventAlreadyProcessed()
        if (isEventAlreadyProcessed(orderId, "PAYMENT_CANCELED")) {
            log.warn("(handleCanceledOrder) Order {} already processed, skipping", orderId);
            return;
        }

        // Process the order status change (event already recorded above)
        processOrderStatusChange(orderId, OrderStatus.CANCELED);
    }

    @Override
    @Transactional
    public void handleFailedOrder(String orderId) {
        log.info("(handleFailedOrder) Processing failed order: {}", orderId);

        // Idempotency check: Skip if already processed
        // If this returns false, the record is ALREADY saved by isEventAlreadyProcessed()
        if (isEventAlreadyProcessed(orderId, "PAYMENT_FAILED")) {
            log.warn("(handleFailedOrder) Order {} already processed, skipping", orderId);
            return;
        }

        // Process the order status change (event already recorded above)
        processOrderStatusChange(orderId, OrderStatus.FAILED);
    }

    @Override
    @Transactional
    public void handleSuccessOrder(String orderId) {
        log.info("(handleSuccessOrder) Processing successful order: {}", orderId);

        // Idempotency check: Skip if already processed
        // If this returns false, the record is ALREADY saved by isEventAlreadyProcessed()
        if (isEventAlreadyProcessed(orderId, "PAYMENT_SUCCESS")) {
            log.warn("(handleSuccessOrder) Order {} already processed, skipping", orderId);
            return;
        }

        // For SUCCESS: only update order status
        // inventory-service will handle: read pending orders → decrement inventory → release queue → remove pending orders
        // This prevents race condition where order-service removes data before inventory-service can read it
        updateOrderStatus(orderId, OrderStatus.COMPLETED);
    }

    private void processOrderStatusChange(String orderId, OrderStatus newStatus) {
        log.info("(processOrderStatusChange) Processing order {} status change to {}", orderId, newStatus);

        Optional<Map<String, Long>> productQuantityMapOptional = redisRepository.getProductQuantitiesForOrder(orderId);

        Map<String, Long> productQuantityMap = productQuantityMapOptional.orElse(new HashMap<>());

        if (productQuantityMap.isEmpty()) {
            log.warn("(processOrderStatusChange) Order ID: {} is invalid or expired", orderId);
            return;
        }

        updateInventoryCacheWithLocks(productQuantityMap);
        updateOrderStatus(orderId, newStatus);

        // Remove from pending orders ZSET (order is now processed)
        // This also removes the price and product quantities stored in ZSET
        redisRepository.removeFromPendingOrders(orderId);
        log.debug("(processOrderStatusChange) Removed order {} from pending orders ZSET", orderId);
    }

    private void updateInventoryCacheWithLocks(Map<String, Long> productQuantityMap) {
        log.info("(updateInventoryCacheWithLocks) Updating inventory cache with locks for products: {}", productQuantityMap.keySet());
        if (productQuantityMap.isEmpty()) {
            return;
        }

        List<String> productIds = new ArrayList<>(productQuantityMap.keySet());
        Collections.sort(productIds);

        DistributedLockContext lockContext = new DistributedLockContext(productIds);

        try {
            // Acquire all locks
            for (String productId : productIds) {
                String lockKey = RedisConstant.LOCK_QUEUE_PRODUCT_KEY + productId;
                RLock lock = acquireLockWithRetry(lockKey, lockContext);
                lockContext.addLock(productId, lock);
            }

            // Decrement inventory cache
            for (Map.Entry<String, Long> entry : productQuantityMap.entrySet()) {
                redisRepository.decr(RedisConstant.QUEUE_PRODUCT_KEY + entry.getKey(), entry.getValue());
            }

        } finally {
            lockContext.releaseAllInReverse();
        }
    }

    /**
     * Acquires a distributed lock with retry and exponential backoff.
     * CRITICAL FIX: On InterruptedException, releases lock if acquired and cleans up all locks in context.
     */
    private RLock acquireLockWithRetry(String lockKey, DistributedLockContext lockContext) {
        log.info("(acquireLockWithRetry) Acquiring lock with key: {}", lockKey);
        RLock lock = redissonClient.getFairLock(lockKey);
        int retryCount = 0;

        while (retryCount < MAX_LOCK_RETRY_ATTEMPTS) {
            try {
                // Apply exponential backoff after first attempt
                if (retryCount > 0) {
                    long backoffTime = INITIAL_BACKOFF_MS * (long) Math.pow(2, (retryCount - 1));
                    backoffTime += RANDOM.nextInt((int) (backoffTime * 0.2));
                    Thread.sleep(backoffTime);
                }

                if (lock.tryLock(LOCK_WAIT_TIME_SECONDS, LOCK_LEASE_TIME_SECONDS, TimeUnit.SECONDS)) {
                    log.debug("(acquireLockWithRetry) Successfully acquired lock: {}", lockKey);
                    return lock;
                }

                retryCount++;

            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                log.error("(acquireLockWithRetry) Interrupted while waiting for lock: {}", lockKey, e);

                // CRITICAL FIX: Release this lock if we acquired it
                if (lock.isHeldByCurrentThread()) {
                    try {
                        lock.unlock();
                        log.debug("(acquireLockWithRetry) Released interrupted lock: {}", lockKey);
                    } catch (Exception unlockException) {
                        log.warn("(acquireLockWithRetry) Failed to release interrupted lock: {}", lockKey, unlockException);
                    }
                }

                // Release all previously acquired locks in the context
                lockContext.releaseAllInReverse();

                throw new InternalErrorException();
            }
        }

        log.error("(acquireLockWithRetry) Failed to acquire lock after {} attempts: {}", MAX_LOCK_RETRY_ATTEMPTS, lockKey);
        throw new InternalErrorException();
    }

    private void updateOrderStatus(String orderId, OrderStatus status) {
        log.info("(updateOrderStatus) Updating order {} status to {}", orderId, status);
        masterOrderRepo.updateStatus(orderId, status);
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

    private InventoryProductIdsResponse fetchInventoryData(InventoryProductIdsRequest request) {
        log.info("(fetchInventoryData) Fetching inventory data for {} products", request.getIds().size());
        return inventoryGrpcClientService.fetchInventoryData(request.getIds());
    }

    /**
     * Checks if a payment event has already been processed for this order.
     * MongoDB's unique compound index on (orderId, eventType) ensures atomicity.
     *
     * IMPORTANT: This method SAVES the record if it doesn't exist (returns false).
     * No need to call a separate "record" method afterward.
     *
     * @param orderId Order ID to check
     * @param eventType Event type (PAYMENT_SUCCESS, PAYMENT_FAILED, PAYMENT_CANCELED)
     * @return true if event was already processed, false otherwise (and saves the record)
     */
    private boolean isEventAlreadyProcessed(String orderId, String eventType) {
        log.debug("(isEventAlreadyProcessed) Checking if event {} for order {} was already processed",
                eventType, orderId);

        try {
            // Try to insert the record
            ProcessedPaymentEvent event = ProcessedPaymentEvent.builder()
                    .orderId(orderId)
                    .eventType(eventType)
                    .processedAt(LocalDateTime.now())
                    .build();

            processedPaymentEventRepository.save(event);

            // If save succeeded, event was NOT processed before (and we just saved it)
            log.info("(isEventAlreadyProcessed) First time processing event {} for order {}, record saved",
                    eventType, orderId);
            return false;
        } catch (DuplicateKeyException e) {
            // Duplicate key means event was already processed
            log.info("(isEventAlreadyProcessed) Event {} for order {} already processed, skipping",
                    eventType, orderId);
            return true;
        }
    }
}
