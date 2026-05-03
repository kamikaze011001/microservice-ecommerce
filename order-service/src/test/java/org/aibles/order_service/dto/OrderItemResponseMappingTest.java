package org.aibles.order_service.dto;

import org.aibles.order_service.dto.response.OrderItemResponse;
import org.aibles.order_service.entity.OrderItem;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Task 4 – RED → GREEN test.
 *
 * Verifies that OrderItemResponse.from() maps productName and imageUrl
 * from the OrderItem entity to the response DTO.
 */
class OrderItemResponseMappingTest {

    @Test
    void toResponse_includes_snapshot_fields() {
        OrderItem entity = OrderItem.builder()
                .id("i1")
                .productId("p1")
                .price(9.99)
                .quantity(2L)
                .productName("Widget")
                .imageUrl("https://x/y.png")
                .build();

        OrderItemResponse r = OrderItemResponse.from(entity);

        assertThat(r.getProductName()).isEqualTo("Widget");
        assertThat(r.getImageUrl()).isEqualTo("https://x/y.png");
    }
}
