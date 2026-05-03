package org.aibles.order_service.service;

import org.aibles.ecommerce.common_dto.response.InventoryProductIdsResponse;
import org.aibles.ecommerce.common_dto.response.InventoryProductResponse;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.order_service.client.InventoryGrpcClientService;
import org.aibles.order_service.dto.request.OrderItemRequest;
import org.aibles.order_service.dto.request.OrderRequest;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.entity.OrderItem;
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
import org.redisson.api.RLock;
import org.redisson.api.RedissonClient;
import org.springframework.context.ApplicationEventPublisher;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * Task 3 – RED → GREEN test.
 *
 * Verifies that OrderServiceImpl.create() snapshots productName and imageUrl
 * from the inventory gRPC response onto each persisted OrderItem.
 */
class OrderCreateSnapshotTest {

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

    @Test
    void createOrder_snapshotsProductNameAndImageUrl_onEachOrderItem() throws InterruptedException {
        // ---- arrange ----
        String productId = "prod-1";
        String userId = "user-1";

        // Stub gRPC inventory response with name and imageUrl
        InventoryProductResponse productResponse = InventoryProductResponse.builder()
                .id(productId)
                .name("Widget")
                .price(9.99)
                .quantity(100L)
                .imageUrl("https://x/y.png")
                .build();
        InventoryProductIdsResponse inventoryResponse =
                new InventoryProductIdsResponse(List.of(productResponse));
        when(inventoryGrpcClientService.fetchInventoryData(anyList()))
                .thenReturn(inventoryResponse);

        // Stub atomic reservation → success
        when(pendingOrderCacheRepository.checkAndReserveAtomic(any(), any(), any()))
                .thenReturn(true);

        // Stub Redisson fair lock — acquire always succeeds
        RLock lock = mock(RLock.class);
        when(redissonClient.getFairLock(anyString())).thenReturn(lock);
        when(lock.tryLock(anyLong(), anyLong(), any())).thenReturn(true);
        when(lock.isHeldByCurrentThread()).thenReturn(true);

        // Stub order save → return order with id
        Order savedOrder = new Order();
        savedOrder.setId("order-abc");
        when(masterOrderRepo.save(any(Order.class))).thenReturn(savedOrder);

        // Stub masterOrderItemRepo.saveAll → return same list
        when(masterOrderItemRepo.saveAll(anyList())).thenAnswer(inv -> inv.getArgument(0));

        // Build request
        OrderItemRequest itemRequest = new OrderItemRequest(productId, 2L);
        OrderRequest request = new OrderRequest("123 Main St", "0912345678",
                List.of(itemRequest));

        // ---- act ----
        orderService.create(userId, request);

        // ---- assert ----
        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<OrderItem>> captor = ArgumentCaptor.forClass(List.class);
        verify(masterOrderItemRepo).saveAll(captor.capture());

        List<OrderItem> savedItems = captor.getValue();
        assertThat(savedItems).hasSize(1);

        OrderItem item = savedItems.get(0);
        assertThat(item.getProductName())
                .as("productName must be snapshotted from inventory response")
                .isEqualTo("Widget");
        assertThat(item.getImageUrl())
                .as("imageUrl must be snapshotted from inventory response")
                .isEqualTo("https://x/y.png");
        assertThat(item.getPrice()).isEqualTo(9.99);
        assertThat(item.getQuantity()).isEqualTo(2L);
    }
}
