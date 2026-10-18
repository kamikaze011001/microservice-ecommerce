package org.aibles.ecommerce.inventory_service.service;

import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.ecommerce.inventory_service.repository.ProcessedPaymentEventRepository;
import org.aibles.ecommerce.inventory_service.repository.InventoryProductRepository;
import org.aibles.ecommerce.inventory_service.repository.ProductQuantityHistoryRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * The payment-success commit path. Contract (since the chaos run lost 70 of 532
 * decrements when Redis restarted):
 *  - the order lines come from the EVENT; the Redis index is only a fallback
 *    for events published before lines were carried;
 *  - no lines anywhere, or the stock floor → THROW (the transaction, inbox row
 *    included, rolls back; the consumer retries, then dead-letters it);
 *  - the inbox row is written AFTER the stock work — it means "applied".
 */
class InventoryCommitPathTest {

    private InventoryProductRepository inventoryProductRepository;
    private ProductQuantityHistoryRepository productQuantityHistoryRepository;
    private ApplicationEventPublisher applicationEventPublisher;
    private RedisRepository redisRepository;
    private PendingOrderCacheRepository pendingOrderCacheRepository;
    private ProcessedPaymentEventRepository processedPaymentEventRepository;

    private InventoryServiceImpl inventoryService;

    @BeforeEach
    void setUp() {
        inventoryProductRepository = mock(InventoryProductRepository.class);
        productQuantityHistoryRepository = mock(ProductQuantityHistoryRepository.class);
        applicationEventPublisher = mock(ApplicationEventPublisher.class);
        redisRepository = mock(RedisRepository.class);
        pendingOrderCacheRepository = mock(PendingOrderCacheRepository.class);
        RedissonClient redissonClient = mock(RedissonClient.class);
        processedPaymentEventRepository = mock(ProcessedPaymentEventRepository.class);

        inventoryService = new InventoryServiceImpl(
                inventoryProductRepository,
                productQuantityHistoryRepository,
                applicationEventPublisher,
                redisRepository,
                pendingOrderCacheRepository,
                redissonClient,
                processedPaymentEventRepository
        );

        RLock lock = mock(RLock.class);
        when(redissonClient.getFairLock(anyString())).thenReturn(lock);
        try {
            when(lock.tryLock(anyLong(), anyLong(), any(TimeUnit.class))).thenReturn(true);
        } catch (InterruptedException ignored) {}
        when(lock.isHeldByCurrentThread()).thenReturn(true);
    }

    @Test
    void decrementsFromTheEventsLinesWithoutAskingRedis() {
        when(inventoryProductRepository.decrementStockIfSufficient("prod-A", 2L)).thenReturn(1);
        when(inventoryProductRepository.decrementStockIfSufficient("prod-B", 5L)).thenReturn(1);

        inventoryService.handleSuccessPayment("order-2", Map.of("prod-A", 2L, "prod-B", 5L));

        verify(inventoryProductRepository).decrementStockIfSufficient("prod-A", 2L);
        verify(inventoryProductRepository).decrementStockIfSufficient("prod-B", 5L);
        verify(productQuantityHistoryRepository, times(2)).save(any());
        verify(pendingOrderCacheRepository, never()).getProductQuantitiesForOrder(anyString());
    }

    @Test
    void theRedisLossScenario_noLinesAnywhere_throwsAndLeavesNoInboxRow() {
        // The chaos-run bug: the event has no lines (old) and Redis lost the index.
        // It used to log "invalid or already processed" and commit the inbox row.
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-lost")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> inventoryService.handleSuccessPayment("order-lost", Map.of()))
                .isInstanceOf(PaymentStockNotAppliedException.class)
                .hasMessageContaining("order-lost");

        verify(processedPaymentEventRepository, never()).saveAndFlush(any());
        verify(inventoryProductRepository, never()).decrementStockIfSufficient(anyString(), anyLong());
    }

    @Test
    void anEventFromBeforeTheChangeFallsBackToTheRedisIndex() {
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-old"))
                .thenReturn(Optional.of(Map.of("prod-1", 3L)));
        when(inventoryProductRepository.decrementStockIfSufficient("prod-1", 3L)).thenReturn(1);

        inventoryService.handleSuccessPayment("order-old", Map.of());

        verify(inventoryProductRepository).decrementStockIfSufficient("prod-1", 3L);
        verify(processedPaymentEventRepository).saveAndFlush(argThat(e -> e.getId().equals("order-old:PAYMENT_SUCCESS")));
    }

    @Test
    void doesNotTouchTheRedisAvailableCounterAtCommit() {
        when(inventoryProductRepository.decrementStockIfSufficient("prod-1", 3L)).thenReturn(1);

        inventoryService.handleSuccessPayment("order-1", Map.of("prod-1", 3L));

        // The unit left the available counter at reserve time (order-service).
        verify(redisRepository, never()).decr(eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-1"), anyLong());
        verify(redisRepository, never()).decr(eq(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1"), anyLong());
        verify(redisRepository, never()).incr(eq(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1"), anyLong());
    }

    @Test
    void stockFloor_throwsInsteadOfSilentlySkippingAPaidLine() {
        when(inventoryProductRepository.decrementStockIfSufficient("prod-depleted", 1L)).thenReturn(0);

        assertThatThrownBy(() -> inventoryService.handleSuccessPayment("order-3", Map.of("prod-depleted", 1L)))
                .isInstanceOf(PaymentStockNotAppliedException.class)
                .hasMessageContaining("prod-depleted");

        verify(productQuantityHistoryRepository, never()).save(any());
        verify(processedPaymentEventRepository, never()).saveAndFlush(any());
    }

    @Test
    void oneLineAtTheFloor_failsTheWholeOrder_notHalfOfIt() {
        // Lines are applied in sorted order: prod-a passes, prod-b hits the floor.
        when(inventoryProductRepository.decrementStockIfSufficient("prod-a", 2L)).thenReturn(1);
        when(inventoryProductRepository.decrementStockIfSufficient("prod-b", 4L)).thenReturn(0);

        assertThatThrownBy(() -> inventoryService.handleSuccessPayment("order-mix", Map.of("prod-a", 2L, "prod-b", 4L)))
                .isInstanceOf(PaymentStockNotAppliedException.class);

        // prod-a's writes happened inside the transaction that now rolls back;
        // what matters here is the event is NOT marked applied.
        verify(processedPaymentEventRepository, never()).saveAndFlush(any());
        verify(pendingOrderCacheRepository, never()).removeFromPendingOrders("order-mix");
    }

    @Test
    void theInboxRowIsWrittenAfterTheStockWork() {
        when(inventoryProductRepository.decrementStockIfSufficient("prod-1", 2L)).thenReturn(1);

        inventoryService.handleSuccessPayment("order-4", Map.of("prod-1", 2L));

        // "processed" means the stock change happened — never the other way round.
        org.mockito.InOrder inOrder = inOrder(inventoryProductRepository, processedPaymentEventRepository);
        inOrder.verify(inventoryProductRepository).decrementStockIfSufficient("prod-1", 2L);
        inOrder.verify(processedPaymentEventRepository).saveAndFlush(argThat(e ->
                e.getId().equals("order-4:PAYMENT_SUCCESS")));
    }

    @Test
    void aRedeliveryOfAnAppliedPaymentChangesNothing() {
        when(processedPaymentEventRepository.existsById("order-5:PAYMENT_SUCCESS")).thenReturn(true);

        inventoryService.handleSuccessPayment("order-5", Map.of("prod-1", 2L));

        verify(inventoryProductRepository, never()).decrementStockIfSufficient(anyString(), anyLong());
        verify(productQuantityHistoryRepository, never()).save(any());
        verify(processedPaymentEventRepository, never()).saveAndFlush(any());
        verifyNoInteractions(pendingOrderCacheRepository);
    }
}
