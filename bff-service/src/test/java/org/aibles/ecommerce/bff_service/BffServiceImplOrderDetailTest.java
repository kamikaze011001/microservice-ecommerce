package org.aibles.ecommerce.bff_service;

import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.PaymentFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.dto.OrderDetailBffResponse;
import org.aibles.ecommerce.bff_service.dto.response.OrderDetailView;
import org.aibles.ecommerce.bff_service.dto.response.PaymentView;
import org.aibles.ecommerce.bff_service.service.impl.BffServiceImpl;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class BffServiceImplOrderDetailTest {

    @Mock
    private ProductFeignClient productFeignClient;

    @Mock
    private OrderFeignClient orderFeignClient;

    @Mock
    private PaymentFeignClient paymentFeignClient;

    @Mock
    private InventoryGrpcClientService inventoryGrpcClientService;

    @InjectMocks
    private BffServiceImpl service;

    private BaseResponse orderFixture() {
        Map<String, Object> item = Map.of(
                "id", "item1",
                "productId", "p1",
                "productName", "Widget",
                "imageUrl", "https://cdn.example.com/widget.jpg",
                "price", 9.99,
                "quantity", 2
        );
        Map<String, Object> order = Map.of(
                "id", "o1",
                "status", "PENDING",
                "address", "123 Main St",
                "phoneNumber", "555-0100",
                "createdAt", "2026-05-01T10:00:00",
                "updatedAt", "2026-05-01T10:00:00",
                "items", List.of(item)
        );
        return BaseResponse.ok(order);
    }

    private PaymentView paymentFixture() {
        return new PaymentView("pay1", "o1", "PAID", "PURCHASE", 19.98);
    }

    @Test
    void aggregate_returnsOrderAndPayment() {
        when(orderFeignClient.getOrder("u1", "o1")).thenReturn(orderFixture());
        when(paymentFeignClient.byOrderId("o1")).thenReturn(paymentFixture());

        OrderDetailBffResponse r = service.getOrderDetail("u1", "o1");

        assertThat(r.order().id()).isEqualTo("o1");
        assertThat(r.payment().status()).isEqualTo("PAID");
        verifyNoInteractions(productFeignClient);
    }

    @Test
    void aggregate_paymentMissing_returnsNullPayment() {
        when(orderFeignClient.getOrder("u1", "o2")).thenReturn(
                BaseResponse.ok(Map.of(
                        "id", "o2",
                        "status", "PENDING",
                        "address", "456 Elm St",
                        "phoneNumber", "555-0200",
                        "createdAt", "2026-05-01T10:00:00",
                        "updatedAt", "2026-05-01T10:00:00",
                        "items", List.of()
                ))
        );
        when(paymentFeignClient.byOrderId("o2")).thenReturn(null);

        OrderDetailBffResponse r = service.getOrderDetail("u1", "o2");

        assertThat(r.payment()).isNull();
    }
}
