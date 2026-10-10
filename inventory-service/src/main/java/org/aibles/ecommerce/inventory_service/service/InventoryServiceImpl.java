package org.aibles.ecommerce.inventory_service.service;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductQuantityUpdated;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductUpdate;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.common_dto.exception.InternalErrorException;
import org.aibles.ecommerce.common_dto.exception.NotFoundException;
import org.aibles.ecommerce.common_dto.request.InventoryProductIdsRequest;
import org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse;
import org.aibles.ecommerce.common_dto.response.InventoryProductResponse;
import org.aibles.ecommerce.common_dto.response.PagingResponse;
import org.aibles.ecommerce.inventory_service.dto.response.InventoryProductListResponse;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.inventory_service.constant.PaymentEventType;
import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.aibles.ecommerce.inventory_service.entity.ProcessedPaymentEvent;
import org.aibles.ecommerce.inventory_service.entity.ProductQuantityHistory;
import org.aibles.ecommerce.inventory_service.repository.master.MasterProcessedPaymentEventRepo;
import org.aibles.ecommerce.inventory_service.repository.master.MasterInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterProductQuantityHistoryRepo;
import org.aibles.ecommerce.inventory_service.repository.projection.ProductQuantitySummary;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveProductQuantityHistoryRepo;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

@Slf4j
public class InventoryServiceImpl implements InventoryService {

    private static final int LOCK_WAIT_TIME_SECONDS = 5;
    private static final int LOCK_LEASE_TIME_SECONDS = 10;
    private static final int MAX_LOCK_RETRY_ATTEMPTS = 3;
    private static final long INITIAL_BACKOFF_MS = 100;
    private static final Random RANDOM = new Random();

    private final MasterInventoryProductRepository masterInventoryProductRepository;

    private final SlaveInventoryProductRepository slaveInventoryProductRepository;

    private final MasterProductQuantityHistoryRepo masterProductQuantityHistoryRepo;

    private final SlaveProductQuantityHistoryRepo slaveProductQuantityHistoryRepo;

    private final ApplicationEventPublisher applicationEventPublisher;

    private final RedisRepository redisRepository;

    private final PendingOrderCacheRepository pendingOrderCacheRepository;

    private final RedissonClient redissonClient;

    private final MasterProcessedPaymentEventRepo masterProcessedPaymentEventRepo;

    public InventoryServiceImpl(MasterInventoryProductRepository masterInventoryProductRepository,
                                SlaveInventoryProductRepository slaveInventoryProductRepository,
                                MasterProductQuantityHistoryRepo masterProductQuantityHistoryRepo,
                                SlaveProductQuantityHistoryRepo slaveProductQuantityHistoryRepo,
                                ApplicationEventPublisher applicationEventPublisher,
                                RedisRepository redisRepository,
                                PendingOrderCacheRepository pendingOrderCacheRepository,
                                RedissonClient redissonClient,
                                MasterProcessedPaymentEventRepo masterProcessedPaymentEventRepo) {
        this.masterInventoryProductRepository = masterInventoryProductRepository;
        this.slaveInventoryProductRepository = slaveInventoryProductRepository;
        this.masterProductQuantityHistoryRepo = masterProductQuantityHistoryRepo;
        this.slaveProductQuantityHistoryRepo = slaveProductQuantityHistoryRepo;
        this.applicationEventPublisher = applicationEventPublisher;
        this.redisRepository = redisRepository;
        this.pendingOrderCacheRepository = pendingOrderCacheRepository;
        this.redissonClient = redissonClient;
        this.masterProcessedPaymentEventRepo = masterProcessedPaymentEventRepo;
    }

    @Override
    @Transactional
    public void save(ProductUpdate productUpdate) {
        log.info("(save)productUpdate: {}", productUpdate);

        if (!slaveInventoryProductRepository.existsById(productUpdate.getId().toString())) {
            masterInventoryProductRepository.save(InventoryProduct.from(productUpdate));
            return;
        }
        Optional<InventoryProduct> inventoryProductOptional =
                slaveInventoryProductRepository.findById(productUpdate.getId().toString());

        if (inventoryProductOptional.isEmpty()) {
            return;
        }

        InventoryProduct inventoryProduct = inventoryProductOptional.get();
        inventoryProduct.setName(productUpdate.getName().toString());
        inventoryProduct.setPrice(productUpdate.getPrice());
        inventoryProduct.setImageUrl(productUpdate.getImageUrl() != null
                ? productUpdate.getImageUrl().toString()
                : null);
        masterInventoryProductRepository.save(inventoryProduct);
    }

    @Override
    @Transactional(readOnly = true)
    public InventoryProductIdsResponse list(InventoryProductIdsRequest request) {
        log.info("(list)request: {}", request);
        List<InventoryProduct> inventoryProducts = masterInventoryProductRepository.findByIdIn(request.getIds());
        // Browse/display reads tolerate slave staleness — reservation no longer uses this SUM
        // (the AVAILABLE_PRODUCT_KEY Redis counter is now the reservation authority).
        // Reverted to slave per the oversell fix design (locked decision #2).
        List<ProductQuantitySummary> quantitySummaries =
                slaveProductQuantityHistoryRepo.sumQuantitiesByProductIds(request.getIds());

        Map<String, Long> productQuantityMap = quantitySummaries.stream().collect(
                Collectors.toMap(ProductQuantitySummary::getProductId, ProductQuantitySummary::getTotalQuantity)
        );

        List<InventoryProductResponse> inventoryProductResponses = new ArrayList<>();
        for (InventoryProduct inventoryProduct : inventoryProducts) {
            InventoryProductResponse inventoryProductResponse = InventoryProductResponse.builder()
                    .id(inventoryProduct.getId())
                    .name(inventoryProduct.getName())
                    .price(inventoryProduct.getPrice())
                    .quantity(productQuantityMap.get(inventoryProduct.getId()) != null ?
                            productQuantityMap.get(inventoryProduct.getId()) : 0L)
                    .imageUrl(inventoryProduct.getImageUrl())
                    .build();
            inventoryProductResponses.add(inventoryProductResponse);
        }
        return new InventoryProductIdsResponse(inventoryProductResponses);
    }

    @Override
    @Transactional
    public void update(String id, Long quantity, Boolean isAdd) {
        log.info("(update)id: {}, quantity: {}, isAdd: {}", id, quantity, isAdd);
        if (!slaveInventoryProductRepository.existsById(id)) {
            log.warn("(update)id: {} is invalid", id);
            throw new NotFoundException("inventory.product.not_found", Map.of("id", id));
        }

        long actualQuantity = Boolean.TRUE.equals(isAdd) ? quantity : -quantity;

        // Ledger row (history/compat — keep as-is)
        ProductQuantityHistory productQuantityHistory = new ProductQuantityHistory();
        productQuantityHistory.setProductId(id);
        productQuantityHistory.setQuantity(actualQuantity);
        masterProductQuantityHistoryRepo.save(productQuantityHistory);

        // Sync materialized stock column (admin ops: use adjustStock, operator accepts responsibility)
        masterInventoryProductRepository.adjustStock(id, actualQuantity);

        // Sync Redis available counter
        if (actualQuantity > 0) {
            redisRepository.incr(RedisConstant.AVAILABLE_PRODUCT_KEY + id, actualQuantity);
        } else if (actualQuantity < 0) {
            redisRepository.decr(RedisConstant.AVAILABLE_PRODUCT_KEY + id, Math.abs(actualQuantity));
        }

        ProductQuantityUpdated eventData = ProductQuantityUpdated.newBuilder()
                .setProductId(id)
                .setQuantity(actualQuantity)
                .build();

        MongoSavedEvent mongoSavedEvent = new MongoSavedEvent(this,
                EcommerceEvent.PRODUCT_QUANTITY_UPDATED.getValue(),
                id,
                eventData);
        applicationEventPublisher.publishEvent(mongoSavedEvent);
    }

    @Override
    @Transactional(readOnly = true)
    public PagingResponse listAll(int page, int size) {
        log.info("(listAll) page: {}, size: {}", page, size);

        Page<InventoryProduct> inventoryProductPage = slaveInventoryProductRepository
                .findAll(PageRequest.of(page - 1, size));

        List<InventoryProduct> inventoryProducts = inventoryProductPage.getContent();

        List<String> productIds = inventoryProducts.stream().map(InventoryProduct::getId).toList();

        List<ProductQuantitySummary> productQuantitySummaries = slaveProductQuantityHistoryRepo
                .sumQuantitiesByProductIds(productIds);

        Map<String, Long> quantityMap = new HashMap<>();

        productQuantitySummaries.forEach(productQuantitySummary -> {
            quantityMap.putIfAbsent(productQuantitySummary.getProductId(), productQuantitySummary.getTotalQuantity());
        });

        List<InventoryProductListResponse> inventoryProductListResponses = inventoryProducts.stream().map(
                inventoryProduct -> InventoryProductListResponse.builder()
                        .id(inventoryProduct.getId())
                        .name(inventoryProduct.getName())
                        .price(inventoryProduct.getPrice())
                        .quantity(quantityMap.getOrDefault(inventoryProduct.getId(), 0L))
                        .build()
        ).toList();

        return PagingResponse.builder()
                .size(size)
                .page(page)
                .total(inventoryProductPage.getTotalElements())
                .data(inventoryProductListResponses)
                .build();
    }

    /**
     * Applies a paid order to stock — exactly once, and never silently not at all.
     *
     * <p>The lines come from the event (PaymentSuccess carries them since the
     * order was created), so this no longer depends on the Redis pending-order
     * index: a Redis restart used to empty it, this method then logged "invalid
     * or already processed" and committed the inbox row anyway — the decrement
     * was lost and every redelivery skipped it as a duplicate (70 of 532 orders
     * in the chaos run).
     *
     * <p>If the lines can't be determined, or the floor-guarded decrement can't
     * be applied, it THROWS: the whole transaction (inbox row included) rolls
     * back, the consumer retries, then dead-letters it — visible and replayable,
     * instead of marked done.
     *
     * <p>The inbox row is written AFTER the stock work, in the same transaction:
     * it records "this payment's stock change happened". Two pods racing on one
     * order both decrement under the per-product locks, then collide on the
     * inbox primary key at flush; the loser's transaction — its decrement with
     * it — rolls back, and its redelivery takes the existsById branch.
     */
    @Override
    @Transactional
    public void handleSuccessPayment(String orderId, Map<String, Long> lines) {
        log.info("(handleSuccessPayment)orderId: {} lines: {}", orderId, lines.size());

        String inboxId = ProcessedPaymentEvent.idOf(orderId, PaymentEventType.PAYMENT_SUCCESS);
        if (masterProcessedPaymentEventRepo.existsById(inboxId)) {
            log.info("payment success already applied, skipping redelivery. orderId={}", orderId);
            return;
        }

        processInventoryUpdate(orderId, resolveLines(orderId, lines));

        masterProcessedPaymentEventRepo.saveAndFlush(ProcessedPaymentEvent.of(orderId, PaymentEventType.PAYMENT_SUCCESS));
    }

    /**
     * The event's lines; for events published before they were carried, the old
     * Redis index (transition only). Neither → the payment can't be applied.
     */
    private Map<String, Long> resolveLines(String orderId, Map<String, Long> fromEvent) {
        if (!fromEvent.isEmpty()) {
            return fromEvent;
        }
        Map<String, Long> fromRedis = pendingOrderCacheRepository.getProductQuantitiesForOrder(orderId)
                .orElse(Map.of());
        if (!fromRedis.isEmpty()) {
            log.warn("payment success without lines (published before they were carried); using the Redis index. orderId={}",
                    orderId);
            return fromRedis;
        }
        throw new PaymentStockNotAppliedException(
                "no order lines for orderId " + orderId + ": not in the event, not in the Redis index");
    }

    /**
     * Layer 1: does NOT touch the Redis available counter (the unit left it at reserve time).
     * Layer 2: decrements inventory_product.stock with an atomic conditional floor (stock >= n).
     *          0 rows = this paid order would take stock below zero → throw; the whole order
     *          rolls back to the dead-letter topic rather than being half-applied or skipped.
     */
    private void processInventoryUpdate(String orderId, Map<String, Long> productQuantityFromOrder) {
        log.info("(processInventoryUpdate) Processing inventory update for order: {}", orderId);

        List<String> productIds = new ArrayList<>(productQuantityFromOrder.keySet());
        Collections.sort(productIds);
        Map<String, RLock> locks = new HashMap<>();

        try {
            for (String productId : productIds) {
                locks.put(productId, acquireLockWithRetry(RedisConstant.LOCK_QUEUE_PRODUCT_KEY + productId));
            }

            ProductQuantityUpdated productQuantityUpdated;
            MongoSavedEvent mongoSavedEvent;

            for (Map.Entry<String, Long> entry : productQuantityFromOrder.entrySet()) {
                String productId = entry.getKey();
                long qty = entry.getValue();

                // Layer 2: atomic conditional DB decrement (floor at 0)
                int rows = masterInventoryProductRepository.decrementStockIfSufficient(productId, qty);

                if (rows == 0) {
                    // DB floor: applying this paid order would take stock below zero.
                    // Skipping it (the old behaviour) silently dropped a sold unit from
                    // the ledger; throwing rolls back the whole order to the DLT, where
                    // an operator sees it and `make dlt-replay` can re-apply it.
                    throw new PaymentStockNotAppliedException("stock floor: productId " + productId
                            + " has less than " + qty + " left for paid orderId " + orderId);
                }

                // Layer 1 (commit path): do NOT touch Redis available counter.
                // The unit was removed from available at reserve time. No Redis change here.

                // Ledger row for history/compat (only when DB floor passes)
                ProductQuantityHistory productQuantityHistory = new ProductQuantityHistory();
                productQuantityHistory.setProductId(productId);
                productQuantityHistory.setQuantity(qty * -1);
                masterProductQuantityHistoryRepo.save(productQuantityHistory);

                // Publish inventory update event
                productQuantityUpdated = ProductQuantityUpdated.newBuilder()
                        .setProductId(productId)
                        .setQuantity(qty * -1)
                        .build();
                mongoSavedEvent = new MongoSavedEvent(this,
                        EcommerceEvent.PRODUCT_QUANTITY_UPDATED.getValue(),
                        productId,
                        productQuantityUpdated);
                applicationEventPublisher.publishEvent(mongoSavedEvent);
            }

            // Remove order from pending orders (cleanup)
            pendingOrderCacheRepository.removeFromPendingOrders(orderId);
            log.info("(processInventoryUpdate) Successfully processed inventory and cleaned up order: {}", orderId);

        } catch (PaymentStockNotAppliedException e) {
            throw e;   // already says why; don't bury it under a generic wrapper
        } catch (Exception e) {
            log.error("(processInventoryUpdate) Error processing inventory for orderId: {}", orderId, e);
            throw new InternalErrorException("inventory.order.processing_failed", Map.of("order_id", orderId));
        } finally {
            releaseLockInReverse(productIds, locks);
        }
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

    private RLock acquireLockWithRetry(String lockKey) {
        log.info("(acquireLockWithRetry) Acquiring lock with key : {}", lockKey);
        RLock lock = redissonClient.getFairLock(lockKey);
        int retryCount = 0;

        while (retryCount < MAX_LOCK_RETRY_ATTEMPTS) {
            try {
                if (retryCount > 0) {
                    long backoffTime = INITIAL_BACKOFF_MS * (long) Math.pow(2, (retryCount - 1));
                    backoffTime += RANDOM.nextInt((int) (backoffTime * 0.2));
                    Thread.sleep(backoffTime);
                }

                if (lock.tryLock(LOCK_WAIT_TIME_SECONDS, LOCK_LEASE_TIME_SECONDS, TimeUnit.SECONDS)) {
                    return lock;
                }

                retryCount++;

            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                log.error("(acquireLockWithRetry) Interrupted while waiting for lock with key : {}", lockKey, e);
                throw new InternalErrorException("inventory.lock.interrupted", Map.of("key", lockKey));
            }
        }
        log.error("(acquireLockWithRetry) Failed to acquire lock after multiple attempts with key : {}", lockKey);
        throw new InternalErrorException("inventory.lock.acquire_failed", Map.of("key", lockKey));
    }


}
