package org.aibles.ecommerce.inventory_service.service;

import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.inventory_service.constant.PaymentEventType;
import org.aibles.ecommerce.inventory_service.entity.ProcessedPaymentEvent;
import org.aibles.ecommerce.inventory_service.repository.ProcessedPaymentEventRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.master.MasterProductQuantityHistoryRepo;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveInventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.slave.SlaveProductQuantityHistoryRepo;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.dao.DuplicateKeyException;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.TimeUnit;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class InventoryCommitPathTest {

    private MasterInventoryProductRepository masterInventoryProductRepository;
    private SlaveInventoryProductRepository slaveInventoryProductRepository;
    private MasterProductQuantityHistoryRepo masterProductQuantityHistoryRepo;
    private SlaveProductQuantityHistoryRepo slaveProductQuantityHistoryRepo;
    private ApplicationEventPublisher applicationEventPublisher;
    private RedisRepository redisRepository;
    private PendingOrderCacheRepository pendingOrderCacheRepository;
    private RedissonClient redissonClient;
    private ProcessedPaymentEventRepository processedPaymentEventRepository;

    private InventoryServiceImpl inventoryService;

    @BeforeEach
    void setUp() {
        masterInventoryProductRepository = mock(MasterInventoryProductRepository.class);
        slaveInventoryProductRepository = mock(SlaveInventoryProductRepository.class);
        masterProductQuantityHistoryRepo = mock(MasterProductQuantityHistoryRepo.class);
        slaveProductQuantityHistoryRepo = mock(SlaveProductQuantityHistoryRepo.class);
        applicationEventPublisher = mock(ApplicationEventPublisher.class);
        redisRepository = mock(RedisRepository.class);
        pendingOrderCacheRepository = mock(PendingOrderCacheRepository.class);
        redissonClient = mock(RedissonClient.class);
        processedPaymentEventRepository = mock(ProcessedPaymentEventRepository.class);

        inventoryService = new InventoryServiceImpl(
                masterInventoryProductRepository,
                slaveInventoryProductRepository,
                masterProductQuantityHistoryRepo,
                slaveProductQuantityHistoryRepo,
                applicationEventPublisher,
                redisRepository,
                pendingOrderCacheRepository,
                redissonClient,
                processedPaymentEventRepository
        );

        // Default lock stub
        RLock lock = mock(RLock.class);
        when(redissonClient.getFairLock(anyString())).thenReturn(lock);
        try {
            when(lock.tryLock(anyLong(), anyLong(), any(TimeUnit.class))).thenReturn(true);
        } catch (InterruptedException ignored) {}
        when(lock.isHeldByCurrentThread()).thenReturn(true);
    }

    @Test
    void handleSuccessPayment_doesNotDecrRedisQueueCounter() {
        // Arrange
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-1"))
                .thenReturn(Optional.of(Map.of("prod-1", 3L)));
        when(masterInventoryProductRepository.decrementStockIfSufficient("prod-1", 3L))
                .thenReturn(1);

        // Act
        inventoryService.handleSuccessPayment("order-1");

        // Assert — MUST NOT call decr on QUEUE_PRODUCT_KEY (old pattern)
        verify(redisRepository, never()).decr(
                eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-1"), anyLong());
        // MUST NOT call incr/decr on AVAILABLE_PRODUCT_KEY at commit time either
        verify(redisRepository, never()).decr(
                eq(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1"), anyLong());
        verify(redisRepository, never()).incr(
                eq(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1"), anyLong());
    }

    @Test
    void handleSuccessPayment_callsDecrementStockIfSufficient_forEachProduct() {
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-2"))
                .thenReturn(Optional.of(Map.of("prod-A", 2L, "prod-B", 5L)));
        when(masterInventoryProductRepository.decrementStockIfSufficient("prod-A", 2L)).thenReturn(1);
        when(masterInventoryProductRepository.decrementStockIfSufficient("prod-B", 5L)).thenReturn(1);

        inventoryService.handleSuccessPayment("order-2");

        verify(masterInventoryProductRepository).decrementStockIfSufficient("prod-A", 2L);
        verify(masterInventoryProductRepository).decrementStockIfSufficient("prod-B", 5L);
    }

    @Test
    void handleSuccessPayment_dbFloorReturnsZero_logsAlertAndSkipsLedgerWrite() {
        // Arrange — stock already 0 (DB floor would be violated)
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-3"))
                .thenReturn(Optional.of(Map.of("prod-depleted", 1L)));
        when(masterInventoryProductRepository.decrementStockIfSufficient("prod-depleted", 1L))
                .thenReturn(0); // DB floor triggered

        // Act — must not throw
        inventoryService.handleSuccessPayment("order-3");

        // Assert — ledger row must NOT be saved for a would-be oversell
        verify(masterProductQuantityHistoryRepo, never()).save(any());
        // ...and no inventory-update event may be published for a floor-blocked product
        verify(applicationEventPublisher, never()).publishEvent(any());
    }

    @Test
    void handleSuccessPayment_oneProductFloorBlocked_otherStillProcessed() {
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-mix"))
                .thenReturn(Optional.of(Map.of("prod-ok", 2L, "prod-blocked", 4L)));
        when(masterInventoryProductRepository.decrementStockIfSufficient("prod-ok", 2L)).thenReturn(1);
        when(masterInventoryProductRepository.decrementStockIfSufficient("prod-blocked", 4L)).thenReturn(0);

        inventoryService.handleSuccessPayment("order-mix");

        // Only the passing product writes a ledger row and publishes an event;
        // the floor-blocked product is skipped via continue.
        verify(masterProductQuantityHistoryRepo, times(1)).save(any());
        verify(applicationEventPublisher, times(1)).publishEvent(any());
        // Cleanup still runs for the order as a whole.
        verify(pendingOrderCacheRepository).removeFromPendingOrders("order-mix");
    }

    @Test
    void handleSuccessPayment_alreadyProcessed_skipsEverything() {
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenThrow(new DuplicateKeyException("duplicate"));

        inventoryService.handleSuccessPayment("order-dup");

        verifyNoInteractions(pendingOrderCacheRepository);
        verifyNoInteractions(masterInventoryProductRepository);
        verifyNoInteractions(redisRepository);
    }
}
