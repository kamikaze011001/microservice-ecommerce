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
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.inventory_service.entity.InventoryProduct;
import org.aibles.ecommerce.inventory_service.entity.ProcessedPaymentEvent;
import org.aibles.ecommerce.inventory_service.entity.ProductQuantityHistory;
import org.aibles.ecommerce.inventory_service.repository.ProcessedPaymentEventRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterProductQuantityHistoryRepo;
import org.aibles.ecommerce.inventory_service.repository.projection.ProductQuantitySummary;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveProductQuantityHistoryRepo;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.dao.DuplicateKeyException;
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

    private final RedissonClient redissonClient;

    private final ProcessedPaymentEventRepository processedPaymentEventRepository;

    public InventoryServiceImpl(MasterInventoryProductRepository masterInventoryProductRepository,
                                SlaveInventoryProductRepository slaveInventoryProductRepository,
                                MasterProductQuantityHistoryRepo masterProductQuantityHistoryRepo,
                                SlaveProductQuantityHistoryRepo slaveProductQuantityHistoryRepo,
                                ApplicationEventPublisher applicationEventPublisher,
                                RedisRepository redisRepository,
                                RedissonClient redissonClient,
                                ProcessedPaymentEventRepository processedPaymentEventRepository) {
        this.masterInventoryProductRepository = masterInventoryProductRepository;
        this.slaveInventoryProductRepository = slaveInventoryProductRepository;
        this.masterProductQuantityHistoryRepo = masterProductQuantityHistoryRepo;
        this.slaveProductQuantityHistoryRepo = slaveProductQuantityHistoryRepo;
        this.applicationEventPublisher = applicationEventPublisher;
        this.redisRepository = redisRepository;
        this.redissonClient = redissonClient;
        this.processedPaymentEventRepository = processedPaymentEventRepository;
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
        masterInventoryProductRepository.save(inventoryProduct);
    }

    @Override
    @Transactional(readOnly = true)
    public InventoryProductIdsResponse list(InventoryProductIdsRequest request) {
        log.info("(list)request: {}", request);
        List<InventoryProduct> inventoryProducts = masterInventoryProductRepository.findByIdIn(request.getIds());
        List<ProductQuantitySummary> quantitySummaries = slaveProductQuantityHistoryRepo.sumQuantitiesByProductIds(request.getIds());

        Map<String, Long> productQuantityMap = quantitySummaries.stream().collect(
                Collectors.toMap(ProductQuantitySummary::getProductId, ProductQuantitySummary::getTotalQuantity)
        );

        List<InventoryProductResponse> inventoryProductResponses = new ArrayList<>();
        InventoryProductResponse inventoryProductResponse;
        for (InventoryProduct inventoryProduct : inventoryProducts) {
            inventoryProductResponse = InventoryProductResponse.builder()
                    .id(inventoryProduct.getId())
                    .name(inventoryProduct.getName())
                    .price(inventoryProduct.getPrice())
                    .quantity(productQuantityMap.get(inventoryProduct.getId()) != null ?
                            productQuantityMap.get(inventoryProduct.getId()) : 0L)
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
            throw new NotFoundException();
        }

        long actualQuantity = Boolean.TRUE.equals(isAdd) ? quantity : -quantity;

        ProductQuantityHistory productQuantityHistory = new ProductQuantityHistory();
        productQuantityHistory.setProductId(id);
        productQuantityHistory.setQuantity(actualQuantity);

        masterProductQuantityHistoryRepo.save(productQuantityHistory);

        ProductQuantityUpdated eventData = ProductQuantityUpdated.newBuilder()
                .setProductId(id)
                .setQuantity(actualQuantity)
                .build();

        MongoSavedEvent mongoSavedEvent = new MongoSavedEvent(this,
                EcommerceEvent.PRODUCT_QUANTITY_UPDATED.getValue(),
                eventData);
        applicationEventPublisher.publishEvent(mongoSavedEvent);
    }

    @Override
    @Transactional
    public void handleSuccessPayment(String orderId) {
        log.info("(handleSuccessPayment)orderId: {}", orderId);

        // Idempotency check: Skip if already processed
        // If this returns false, the record is ALREADY saved by isEventAlreadyProcessed()
        if (isEventAlreadyProcessed(orderId, "PAYMENT_SUCCESS")) {
            log.warn("(handleSuccessPayment) Order {} already processed, skipping", orderId);
            return;
        }

        // Process the inventory update (event already recorded above)
        processInventoryUpdate(orderId);
    }

    /**
     * Processes inventory update for a successful payment.
     * Decrements inventory for all products in the order.
     * Also releases queue reservations and removes order from pending orders.
     */
    private void processInventoryUpdate(String orderId) {
        log.info("(processInventoryUpdate) Processing inventory update for order: {}", orderId);

        Optional<Map<String, Long>> productQuantityFromOrderOptional = redisRepository.getProductQuantitiesForOrder(orderId);
        if (productQuantityFromOrderOptional.isEmpty()) {
            log.warn("(processInventoryUpdate) orderId: {} is invalid or already processed", orderId);
            return;
        }

        Map<String, Long> productQuantityFromOrder = productQuantityFromOrderOptional.get();

        if (productQuantityFromOrder.isEmpty()) {
            log.warn("(processInventoryUpdate) orderId: {} has no product", orderId);
            return;
        }

        List<String> productIds = new ArrayList<>(productQuantityFromOrder.keySet());
        Collections.sort(productIds);
        Map<String, RLock> locks = new HashMap<>();

        try {
            for (String productId : productIds) {
                locks.put(productId, acquireLockWithRetry(RedisConstant.LOCK_QUEUE_PRODUCT_KEY + productId));
            }

            ProductQuantityUpdated productQuantityUpdated;
            MongoSavedEvent mongoSavedEvent;
            ProductQuantityHistory productQuantityHistory;

            for (Map.Entry<String, Long> entry : productQuantityFromOrder.entrySet()) {
                // 1. Decrement actual inventory in database
                productQuantityHistory = new ProductQuantityHistory();
                productQuantityHistory.setProductId(entry.getKey());
                productQuantityHistory.setQuantity(entry.getValue() * -1);
                masterProductQuantityHistoryRepo.save(productQuantityHistory);

                // 2. Release queue reservation (decrement queue counter)
                redisRepository.decr(RedisConstant.QUEUE_PRODUCT_KEY + entry.getKey(), entry.getValue());

                // 3. Publish inventory update event
                productQuantityUpdated = ProductQuantityUpdated.newBuilder()
                        .setProductId(entry.getKey())
                        .setQuantity(entry.getValue() * -1)
                        .build();
                mongoSavedEvent = new MongoSavedEvent(this,
                        EcommerceEvent.PRODUCT_QUANTITY_UPDATED.getValue(),
                        productQuantityUpdated);
                applicationEventPublisher.publishEvent(mongoSavedEvent);
            }

            // 4. Remove order from pending orders (cleanup)
            redisRepository.removeFromPendingOrders(orderId);
            log.info("(processInventoryUpdate) Successfully processed inventory and cleaned up order: {}", orderId);

        } catch (Exception e) {
            log.error("(processInventoryUpdate) error happen when update quantity for success orderId: {}", orderId, e);
            throw new InternalErrorException();
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
                throw new InternalErrorException();
            }
        }
        log.error("(acquireLockWithRetry) Failed to acquire lock after multiple attempts with key : {}", lockKey);
        throw new InternalErrorException();
    }

    /**
     * Checks if a payment event has already been processed for this order.
     * MongoDB's unique compound index on (orderId, eventType) ensures atomicity.
     *
     * IMPORTANT: This method SAVES the record if it doesn't exist (returns false).
     * No need to call a separate "record" method afterward.
     *
     * @param orderId Order ID to check
     * @param eventType Event type (PAYMENT_SUCCESS)
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
