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
import org.aibles.ecommerce.inventory_service.entity.ProductQuantityHistory;
import org.aibles.ecommerce.inventory_service.repository.master.MasterInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterProductQuantityHistoryRepo;
import org.aibles.ecommerce.inventory_service.repository.projection.ProductQuantitySummary;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveProductQuantityHistoryRepo;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.transaction.annotation.Transactional;

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

    public InventoryServiceImpl(MasterInventoryProductRepository masterInventoryProductRepository,
                                SlaveInventoryProductRepository slaveInventoryProductRepository, MasterProductQuantityHistoryRepo masterProductQuantityHistoryRepo, SlaveProductQuantityHistoryRepo slaveProductQuantityHistoryRepo,
                                ApplicationEventPublisher applicationEventPublisher, RedisRepository redisRepository, RedissonClient redissonClient) {
        this.masterInventoryProductRepository = masterInventoryProductRepository;
        this.slaveInventoryProductRepository = slaveInventoryProductRepository;
        this.masterProductQuantityHistoryRepo = masterProductQuantityHistoryRepo;
        this.slaveProductQuantityHistoryRepo = slaveProductQuantityHistoryRepo;
        this.applicationEventPublisher = applicationEventPublisher;
        this.redisRepository = redisRepository;
        this.redissonClient = redissonClient;
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

        Optional<Map<String, Long>> productQuantityFromOrderOptional = redisRepository.getMapStringLong(RedisConstant.QUEUE_ORDER_KEY + orderId);
        if (productQuantityFromOrderOptional.isEmpty()) {
            log.warn("(handleSuccessPayment)orderId: {} is invalid", orderId);
            return;
        }

        Map<String, Long> productQuantityFromOrder = productQuantityFromOrderOptional.get();

        if (productQuantityFromOrder.isEmpty()) {
            log.warn("(handleSuccessPayment)orderId: {} has no product", orderId);
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
                productQuantityHistory = new ProductQuantityHistory();
                productQuantityHistory.setProductId(entry.getKey());
                productQuantityHistory.setQuantity(entry.getValue() * -1);
                masterProductQuantityHistoryRepo.save(productQuantityHistory);
                redisRepository.decr(RedisConstant.QUEUE_PRODUCT_KEY + entry.getKey(), entry.getValue());
                productQuantityUpdated = ProductQuantityUpdated.newBuilder()
                        .setProductId(entry.getKey())
                        .setQuantity(entry.getValue() * -1)
                        .build();
                mongoSavedEvent = new MongoSavedEvent(this,
                        EcommerceEvent.PRODUCT_QUANTITY_UPDATED.getValue(),
                        productQuantityUpdated);
                applicationEventPublisher.publishEvent(mongoSavedEvent);
            }
        } catch (Exception e) {
            log.error("(handleSuccessPayment)error happen when update quantity for success orderId: {}", orderId, e);
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

}
