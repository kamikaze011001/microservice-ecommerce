package org.aibles.order_service.service;

import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.common_dto.exception.ForbiddenException;
import org.aibles.ecommerce.common_dto.exception.NotFoundException;
import org.aibles.ecommerce.common_dto.exception.OrderAlreadyCanceledException;
import org.aibles.ecommerce.common_dto.exception.OrderNotCancellableException;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.order_service.client.InventoryGrpcClientService;
import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.dto.response.OrderCancelResponse;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.entity.ProcessedPaymentEvent;
import org.aibles.order_service.repository.ProcessedPaymentEventRepository;
import org.aibles.order_service.repository.master.MasterOrderItemRepo;
import org.aibles.order_service.repository.master.MasterOrderRepo;
import org.aibles.order_service.repository.slave.SlaveOrderItemRepo;
import org.aibles.order_service.repository.slave.SlaveOrderRepo;
import org.aibles.order_service.service.impl.OrderServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * RED-state test for OrderService.cancel(userId, orderId).
 *
 * All 7 tests currently fail with UnsupportedOperationException because the
 * method body is a stub. The human's task is to replace the stub with the
 * real implementation so that all tests turn GREEN.
 */
class OrderCancelServiceTest {

    // All 10 constructor parameters of OrderServiceImpl
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
    }

    // ---------------------------------------------------------------------------
    // Helper: build an Order with a given status and owner
    // ---------------------------------------------------------------------------
    private Order orderWith(String orderId, String userId, OrderStatus status) {
        Order order = new Order();
        order.setId(orderId);
        order.setUserId(userId);
        order.setStatus(status);
        order.setAddress("123 Test St");
        order.setPhoneNumber("0123456789");
        return order;
    }

    // ---------------------------------------------------------------------------
    // Test 1: Happy path — PROCESSING order owned by the caller
    // ---------------------------------------------------------------------------
    @Test
    void cancelHappyPath_processingOrderOwnedByUser_returnsCanceledAndPublishes() {
        // Arrange
        String userId = "u1";
        String orderId = "o1";
        Order order = orderWith(orderId, userId, OrderStatus.PROCESSING);
        when(slaveOrderRepo.findById(orderId)).thenReturn(Optional.of(order));

        // Act
        OrderCancelResponse response = orderService.cancel(userId, orderId);

        // Assert — response shape
        assertThat(response.getOrderId()).isEqualTo(orderId);
        assertThat(response.getStatus()).isEqualTo(OrderStatus.CANCELED);

        // Assert — eventPublisher was called with a MongoSavedEvent carrying PAYMENT_CANCELED
        ArgumentCaptor<MongoSavedEvent> eventCaptor = ArgumentCaptor.forClass(MongoSavedEvent.class);
        verify(eventPublisher).publishEvent(eventCaptor.capture());
        MongoSavedEvent capturedEvent = eventCaptor.getValue();

        assertThat(capturedEvent.getEventName())
                .isEqualTo(EcommerceEvent.PAYMENT_CANCELED.getValue());

        assertThat(capturedEvent.getData()).isInstanceOf(PaymentCanceled.class);
        PaymentCanceled payload = (PaymentCanceled) capturedEvent.getData();
        assertThat(payload.getOrderId().toString()).isEqualTo(orderId);
    }

    // ---------------------------------------------------------------------------
    // Test 2: A different user tries to cancel someone else's order → ForbiddenException
    // ---------------------------------------------------------------------------
    @Test
    void cancelByOtherUser_throwsForbidden() {
        String ownerUserId = "u1";
        String callerUserId = "u2";
        String orderId = "o1";
        Order order = orderWith(orderId, ownerUserId, OrderStatus.PROCESSING);
        when(slaveOrderRepo.findById(orderId)).thenReturn(Optional.of(order));

        assertThatThrownBy(() -> orderService.cancel(callerUserId, orderId))
                .isInstanceOf(ForbiddenException.class);

        verify(eventPublisher, never()).publishEvent(any());
    }

    // ---------------------------------------------------------------------------
    // Test 3: Order is COMPLETED → OrderNotCancellableException
    // ---------------------------------------------------------------------------
    @Test
    void cancelCompletedOrder_throwsNotCancellable() {
        String userId = "u1";
        String orderId = "o1";
        Order order = orderWith(orderId, userId, OrderStatus.COMPLETED);
        when(slaveOrderRepo.findById(orderId)).thenReturn(Optional.of(order));

        assertThatThrownBy(() -> orderService.cancel(userId, orderId))
                .isInstanceOf(OrderNotCancellableException.class);

        verify(eventPublisher, never()).publishEvent(any());
    }

    // ---------------------------------------------------------------------------
    // Test 4: Order is already CANCELED → OrderAlreadyCanceledException
    // ---------------------------------------------------------------------------
    @Test
    void cancelAlreadyCanceledOrder_throwsAlreadyCanceled() {
        String userId = "u1";
        String orderId = "o1";
        Order order = orderWith(orderId, userId, OrderStatus.CANCELED);
        when(slaveOrderRepo.findById(orderId)).thenReturn(Optional.of(order));

        assertThatThrownBy(() -> orderService.cancel(userId, orderId))
                .isInstanceOf(OrderAlreadyCanceledException.class);

        verify(eventPublisher, never()).publishEvent(any());
    }

    // ---------------------------------------------------------------------------
    // Test 5: Order is FAILED → OrderNotCancellableException
    // ---------------------------------------------------------------------------
    @Test
    void cancelFailedOrder_throwsNotCancellable() {
        String userId = "u1";
        String orderId = "o1";
        Order order = orderWith(orderId, userId, OrderStatus.FAILED);
        when(slaveOrderRepo.findById(orderId)).thenReturn(Optional.of(order));

        assertThatThrownBy(() -> orderService.cancel(userId, orderId))
                .isInstanceOf(OrderNotCancellableException.class);

        verify(eventPublisher, never()).publishEvent(any());
    }

    // ---------------------------------------------------------------------------
    // Test 6: Order is REFUNDED → OrderNotCancellableException
    // ---------------------------------------------------------------------------
    @Test
    void cancelRefundedOrder_throwsNotCancellable() {
        String userId = "u1";
        String orderId = "o1";
        Order order = orderWith(orderId, userId, OrderStatus.REFUNDED);
        when(slaveOrderRepo.findById(orderId)).thenReturn(Optional.of(order));

        assertThatThrownBy(() -> orderService.cancel(userId, orderId))
                .isInstanceOf(OrderNotCancellableException.class);

        verify(eventPublisher, never()).publishEvent(any());
    }

    // ---------------------------------------------------------------------------
    // Test 7: Order does not exist → NotFoundException
    // ---------------------------------------------------------------------------
    @Test
    void cancelNonexistentOrder_throwsNotFound() {
        String userId = "u1";
        String orderId = "nonexistent";
        when(slaveOrderRepo.findById(orderId)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> orderService.cancel(userId, orderId))
                .isInstanceOf(NotFoundException.class);

        verify(eventPublisher, never()).publishEvent(any());
    }
}
