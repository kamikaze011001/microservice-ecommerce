package org.aibles.order_service.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.OrderCreated;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.common_dto.exception.ForbiddenException;
import org.aibles.ecommerce.common_dto.exception.InternalErrorException;
import org.aibles.ecommerce.common_dto.exception.NotFoundException;
import org.aibles.ecommerce.common_dto.exception.OrderAlreadyCanceledException;
import org.aibles.ecommerce.common_dto.exception.OrderNotCancellableException;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.order_service.dto.response.OrderCancelResponse;
import org.aibles.ecommerce.common_dto.request.InventoryProductIdsRequest;
import org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse;
import org.aibles.ecommerce.common_dto.response.InventoryProductResponse;
import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.ecommerce.core_order_cache.constant.OrderCacheConstant;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.order_service.client.InventoryGrpcClientService;
import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.dto.request.OrderItemRequest;
import org.aibles.order_service.dto.request.OrderRequest;
import org.aibles.order_service.dto.response.OrderCreatedResponse;
import org.aibles.order_service.dto.response.OrderDetailResponse;
import org.aibles.order_service.dto.response.OrderItemResponse;
import org.aibles.order_service.dto.response.OrderSummaryResponse;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.entity.OrderItem;
import org.aibles.order_service.exception.InvalidProductQuantityException;
import org.aibles.order_service.repository.master.MasterOrderItemRepo;
import org.aibles.order_service.repository.master.MasterOrderRepo;
import org.aibles.order_service.repository.slave.SlaveOrderItemRepo;
import org.aibles.order_service.repository.slave.SlaveOrderRepo;
import org.aibles.order_service.service.OrderService;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
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
    private final PendingOrderCacheRepository pendingOrderCacheRepository;
    private final MasterOrderRepo masterOrderRepo;
    private final MasterOrderItemRepo masterOrderItemRepo;
    private final RedissonClient redissonClient;
    private final ApplicationEventPublisher eventPublisher;
    private final SlaveOrderRepo slaveOrderRepo;
    private final SlaveOrderItemRepo slaveOrderItemRepo;

    public OrderServiceImpl(InventoryGrpcClientService inventoryGrpcClientService,
                            RedisRepository redisRepository,
                            PendingOrderCacheRepository pendingOrderCacheRepository,
                            MasterOrderRepo masterOrderRepo,
                            MasterOrderItemRepo masterOrderItemRepo,
                            RedissonClient redissonClient,
                            ApplicationEventPublisher eventPublisher,
                            SlaveOrderRepo slaveOrderRepo,
                            SlaveOrderItemRepo slaveOrderItemRepo) {
        this.inventoryGrpcClientService = inventoryGrpcClientService;
        this.redisRepository = redisRepository;
        this.pendingOrderCacheRepository = pendingOrderCacheRepository;
        this.masterOrderRepo = masterOrderRepo;
        this.masterOrderItemRepo = masterOrderItemRepo;
        this.redissonClient = redissonClient;
        this.eventPublisher = eventPublisher;
        this.slaveOrderRepo = slaveOrderRepo;
        this.slaveOrderItemRepo = slaveOrderItemRepo;
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

            // Publish Order.Created for Saga Orchestrator
            OrderCreated orderCreated = OrderCreated.newBuilder()
                    .setOrderId(order.getId())
                    .build();
            eventPublisher.publishEvent(new MongoSavedEvent(
                    this,
                    EcommerceEvent.ORDER_CREATED.getValue(),
                    order.getId(),
                    orderCreated
            ));

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
            log.warn("(validateAndReserveInventoryAtomic) Atomic reservation failed — insufficient available stock");
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
            throw new InternalErrorException("order.product.price_missing", Map.of("id", product.getId()));
        }
    }

    /**
     * Validates that all requested products exist and have valid inventory data.
     * Availability check is handled atomically by Lua script in checkAndReserveAvailableAtomic().
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

        // Build product lookup map for snapshot fields (name, imageUrl)
        Map<String, org.aibles.ecommerce.common_dto.response.InventoryProductResponse> productMap =
                reservation.getInventoryResponse().getInventoryProducts().stream()
                        .collect(Collectors.toMap(
                                org.aibles.ecommerce.common_dto.response.InventoryProductResponse::getId,
                                p -> p
                        ));

        // Save order items with snapshotted product name and image URL
        saveOrderItems(request.getItems(), order.getId(), reservation.getPriceMap(), productMap);

        // Add to pending orders ZSET (stores price AND product quantities)
        long expiryTimestamp = Instant.now()
                .plus(OrderCacheConstant.ORDER_EXPIRY_HOURS, ChronoUnit.HOURS)
                .toEpochMilli();

        pendingOrderCacheRepository.addToPendingOrders(
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

    @Override
    @Transactional
    public void handleCanceledOrder(String orderId) {
        finishOrder(orderId, OrderStatus.CANCELED);
    }

    @Override
    @Transactional
    public void handleFailedOrder(String orderId) {
        finishOrder(orderId, OrderStatus.FAILED);
    }

    @Override
    @Transactional
    public void handleSuccessOrder(String orderId) {
        // Only the status changes here. inventory-service consumes the reservation
        // (reads the pending order → decrements stock → removes it), so releasing it
        // to `available` from this side would hand sold units back.
        if (masterOrderRepo.updateStatusIfCurrent(orderId, OrderStatus.PROCESSING, OrderStatus.COMPLETED) == 0) {
            log.info("order not PROCESSING, success reply ignored (redelivery or already final). orderId={}", orderId);
        }
    }

    /**
     * Idempotent terminal transition for cancel/failure replies — safe to receive any
     * number of times, on any pod, in any order relative to other replies:
     * 1. the state guard lets exactly one delivery move PROCESSING → {@code target};
     *    a redelivery, a concurrent duplicate or a late cancel after COMPLETED gets 0
     *    rows and stops here;
     * 2. that one delivery gives the reserved units back through the atomic Redis
     *    claim, which also guards against the expiry cleanup job releasing the same
     *    reservation concurrently.
     * If the process dies between 1 and 2, the reservation stays pending and the
     * expiry cleanup job releases it later — late, but exactly once.
     */
    private void finishOrder(String orderId, OrderStatus target) {
        if (masterOrderRepo.updateStatusIfCurrent(orderId, OrderStatus.PROCESSING, target) == 0) {
            log.info("order not PROCESSING, {} reply ignored (redelivery or already final). orderId={}", target, orderId);
            return;
        }
        pendingOrderCacheRepository.releaseReservation(orderId, RedisConstant.AVAILABLE_PRODUCT_KEY)
                .ifPresentOrElse(
                        released -> log.debug("reservation released orderId={} products={}", orderId, released),
                        () -> log.warn("order moved to {} but its reservation was already gone. orderId={}", target, orderId));
    }

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

                throw new InternalErrorException("order.lock.interrupted", Map.of("key", lockKey));
            }
        }

        log.error("(acquireLockWithRetry) Failed to acquire lock after {} attempts: {}", MAX_LOCK_RETRY_ATTEMPTS, lockKey);
        throw new InternalErrorException("order.lock.acquire_failed", Map.of("key", lockKey));
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

    private void saveOrderItems(List<OrderItemRequest> orderItems, String orderId,
                                Map<String, Double> itemPriceMap,
                                Map<String, org.aibles.ecommerce.common_dto.response.InventoryProductResponse> productMap) {
        log.info("(saveOrderItems) Saving order items for order: {}", orderId);
        List<OrderItem> items = orderItems.stream()
                .map(item -> {
                    org.aibles.ecommerce.common_dto.response.InventoryProductResponse product =
                            productMap.get(item.getProductId());
                    return OrderItem.builder()
                            .orderId(orderId)
                            .productId(item.getProductId())
                            .price(itemPriceMap.get(item.getProductId()) != null ? itemPriceMap.get(item.getProductId()) : 0.0)
                            .quantity(item.getQuantity())
                            .productName(product != null ? product.getName() : null)
                            .imageUrl(product != null ? product.getImageUrl() : null)
                            .build();
                })
                .toList();

        masterOrderItemRepo.saveAll(items);
    }

    private InventoryProductIdsResponse fetchInventoryData(InventoryProductIdsRequest request) {
        log.info("(fetchInventoryData) Fetching inventory data for {} products", request.getIds().size());
        return inventoryGrpcClientService.fetchInventoryData(request.getIds());
    }


    @Override
    @Transactional(readOnly = true)
    public PagingResponse list(String userId, int page, int size) {
        log.info("(list) userId: {}, page: {}, size: {}", userId, page, size);
        PageRequest pageRequest = PageRequest.of(page - 1, size);
        Page<Order> ordersByPage = slaveOrderRepo.findAllByUserId(userId, pageRequest);
        List<Order> orders = ordersByPage.toList();
        List<OrderSummaryResponse> orderSummaryResponses = orders.stream()
                .map(order -> {
                    List<OrderItem> items = slaveOrderItemRepo.findAllByOrderId(order.getId());
                    return OrderSummaryResponse.from(order, items);
                })
                .toList();
        return PagingResponse.builder()
                .size(size)
                .page(page)
                .total(ordersByPage.getTotalElements())
                .data(orderSummaryResponses)
                .build();
    }

    @Override
    @Transactional(readOnly = true)
    public OrderDetailResponse get(String userId, String orderId) {
        log.info("(get) userId: {}, orderId: {}", userId, orderId);
        Order order = slaveOrderRepo.findByIdAndUserId(orderId, userId)
                .orElseThrow(() -> new NotFoundException("order.not_found", Map.of("id", orderId)));

        List<OrderItem> orderItems = slaveOrderItemRepo.findAllByOrderId(orderId);

        List<OrderItemResponse> orderItemResponses = orderItems.stream().map(OrderItemResponse::from).toList();
        return OrderDetailResponse.from(order, orderItemResponses);
    }

    @Override
    public OrderCancelResponse cancel(String userId, String orderId) {
        log.info("(cancel)orderId: {}", orderId);
        Order order = slaveOrderRepo.findById(orderId)
                .orElseThrow(() -> new NotFoundException("order.not_found", Map.of("id", orderId)));

        if (!userId.equals(order.getUserId())) {
            log.warn("(cancel)order : {} is not belong to user", orderId);
            throw new ForbiddenException("order.cancel.forbidden", Map.of("id", orderId));
        }

        if (order.getStatus().equals(OrderStatus.CANCELED)) {
            log.warn("(cancel)order : {} canceled already", orderId);
            throw new OrderAlreadyCanceledException();
        }

        if (!order.getStatus().equals(OrderStatus.PROCESSING)) {
            log.warn("(cancel)order: {} can not be canceled", orderId);
            throw new OrderNotCancellableException();
        }

        PaymentCanceled paymentCanceled = PaymentCanceled.newBuilder().setOrderId(orderId).build();

        eventPublisher.publishEvent(new MongoSavedEvent(
                this, EcommerceEvent.PAYMENT_CANCELED.getValue(), orderId, paymentCanceled));

        return OrderCancelResponse.builder().orderId(orderId).status(OrderStatus.CANCELED).build();
    }
}
