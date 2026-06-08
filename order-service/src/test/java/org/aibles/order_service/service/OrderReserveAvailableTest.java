package org.aibles.order_service.service;

import org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse;
import org.aibles.ecommerce.common_dto.response.InventoryProductResponse;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.order_service.client.InventoryGrpcClientService;
import org.aibles.order_service.dto.request.OrderItemRequest;
import org.aibles.order_service.dto.request.OrderRequest;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.entity.ProcessedPaymentEvent;
import org.aibles.order_service.repository.ProcessedPaymentEventRepository;
import org.junit.jupiter.api.Assertions;
import org.springframework.dao.DuplicateKeyException;
import org.aibles.order_service.repository.master.MasterOrderItemRepo;
import org.aibles.order_service.repository.master.MasterOrderRepo;
import org.aibles.order_service.repository.slave.SlaveOrderItemRepo;
import org.aibles.order_service.repository.slave.SlaveOrderRepo;
import org.aibles.order_service.service.impl.OrderServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class OrderReserveAvailableTest {

    private InventoryGrpcClientService inventoryGrpcClientService;
    private RedisRepository redisRepository;
    private PendingOrderCacheRepository pendingOrderCacheRepository;
    private MasterOrderRepo masterOrderRepo;
    private MasterOrderItemRepo masterOrderItemRepo;
    private RedissonClient redissonClient;
    private ProcessedPaymentEventRepository processedPaymentEventRepository;
    private ApplicationEventPublisher eventPublisher;
    private SlaveOrderRepo slaveOrderRepo;
    private SlaveOrderItemRepo slaveOrderItemRepo;

    private OrderService orderService;

    @BeforeEach
    void setUp() {
        inventoryGrpcClientService = mock(InventoryGrpcClientService.class);
        redisRepository = mock(RedisRepository.class);
        pendingOrderCacheRepository = mock(PendingOrderCacheRepository.class);
        masterOrderRepo = mock(MasterOrderRepo.class);
        masterOrderItemRepo = mock(MasterOrderItemRepo.class);
        redissonClient = mock(RedissonClient.class);
        processedPaymentEventRepository = mock(ProcessedPaymentEventRepository.class);
        eventPublisher = mock(ApplicationEventPublisher.class);
        slaveOrderRepo = mock(SlaveOrderRepo.class);
        slaveOrderItemRepo = mock(SlaveOrderItemRepo.class);

        orderService = new OrderServiceImpl(
                inventoryGrpcClientService,
                redisRepository,
                pendingOrderCacheRepository,
                masterOrderRepo,
                masterOrderItemRepo,
                redissonClient,
                processedPaymentEventRepository,
                eventPublisher,
                slaveOrderRepo,
                slaveOrderItemRepo
        );

        RLock lock = mock(RLock.class);
        when(redissonClient.getFairLock(anyString())).thenReturn(lock);
        try {
            when(lock.tryLock(anyLong(), anyLong(), any())).thenReturn(true);
        } catch (InterruptedException ignored) {}
        when(lock.isHeldByCurrentThread()).thenReturn(true);
    }

    @Test
    void create_usesCheckAndReserveAvailableAtomic_notOldMethod() throws Exception {
        // Arrange
        InventoryProductResponse product = InventoryProductResponse.builder()
                .id("prod-1").name("Widget").price(9.99).quantity(10L).build();
        when(inventoryGrpcClientService.fetchInventoryData(anyList()))
                .thenReturn(new InventoryProductIdsResponse(List.of(product)));
        when(pendingOrderCacheRepository.checkAndReserveAvailableAtomic(
                eq(RedisConstant.AVAILABLE_PRODUCT_KEY), anyMap()))
                .thenReturn(true);

        Order saved = new Order();
        saved.setId("order-1");
        when(masterOrderRepo.save(any(Order.class))).thenReturn(saved);
        when(masterOrderItemRepo.saveAll(anyList())).thenAnswer(inv -> inv.getArgument(0));

        OrderRequest request = new OrderRequest("123 Main", "0912345678",
                List.of(new OrderItemRequest("prod-1", 2L)));

        // Act
        orderService.create("user-1", request);

        // Assert — new method called with AVAILABLE_PRODUCT_KEY
        verify(pendingOrderCacheRepository).checkAndReserveAvailableAtomic(
                eq(RedisConstant.AVAILABLE_PRODUCT_KEY), eq(Map.of("prod-1", 2L)));
        // OLD method must NOT be called
        verify(pendingOrderCacheRepository, never()).checkAndReserveAtomic(any(), any(), any());
    }

    @Test
    void create_rollbackOnFailure_incrsAvailableKey_notDecrsQueueKey() throws Exception {
        // Arrange — reservation succeeds but order-save fails
        InventoryProductResponse product = InventoryProductResponse.builder()
                .id("prod-1").name("Widget").price(9.99).quantity(10L).build();
        when(inventoryGrpcClientService.fetchInventoryData(anyList()))
                .thenReturn(new InventoryProductIdsResponse(List.of(product)));
        when(pendingOrderCacheRepository.checkAndReserveAvailableAtomic(
                eq(RedisConstant.AVAILABLE_PRODUCT_KEY), anyMap()))
                .thenReturn(true);

        // Order save throws → triggers rollback
        when(masterOrderRepo.save(any(Order.class)))
                .thenThrow(new RuntimeException("DB unavailable"));

        OrderRequest request = new OrderRequest("123 Main", "0912345678",
                List.of(new OrderItemRequest("prod-1", 2L)));

        Assertions.assertThrows(RuntimeException.class, () -> orderService.create("user-1", request));

        // Rollback must incr AVAILABLE_PRODUCT_KEY (release)
        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1", 2L);
        // Must NOT decr QUEUE_PRODUCT_KEY (old rollback)
        verify(redisRepository, never()).decr(eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-1"), anyLong());
    }

    @Test
    void handleCanceledOrder_incrsAvailableKey_notDecrsQueueKey() {
        // Arrange
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-cancel"))
                .thenReturn(Optional.of(Map.of("prod-1", 3L)));

        // Act
        orderService.handleCanceledOrder("order-cancel");

        // Assert — release uses AVAILABLE_PRODUCT_KEY incr
        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-1", 3L);
        verify(redisRepository, never()).decr(eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-1"), anyLong());
    }

    @Test
    void handleFailedOrder_incrsAvailableKey_notDecrsQueueKey() {
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenReturn(new ProcessedPaymentEvent());
        when(pendingOrderCacheRepository.getProductQuantitiesForOrder("order-fail"))
                .thenReturn(Optional.of(Map.of("prod-2", 1L)));

        orderService.handleFailedOrder("order-fail");

        verify(redisRepository).incr(RedisConstant.AVAILABLE_PRODUCT_KEY + "prod-2", 1L);
        verify(redisRepository, never()).decr(eq(RedisConstant.QUEUE_PRODUCT_KEY + "prod-2"), anyLong());
    }

    @Test
    void handleCanceledOrder_alreadyProcessed_doesNotIncrAvailable() {
        // stub the processed-event save to throw DuplicateKeyException —
        // isEventAlreadyProcessed catches this and returns true → early return
        when(processedPaymentEventRepository.save(any(ProcessedPaymentEvent.class)))
                .thenThrow(new DuplicateKeyException("duplicate key"));

        orderService.handleCanceledOrder("order-cancel-dup");

        // duplicate event: inventory must NOT be released a second time
        verify(redisRepository, never()).incr(anyString(), anyLong());
    }
}
