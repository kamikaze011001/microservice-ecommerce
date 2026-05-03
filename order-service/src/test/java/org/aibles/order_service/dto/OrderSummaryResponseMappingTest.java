package org.aibles.order_service.dto;

import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.dto.response.OrderSummaryResponse;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.entity.OrderItem;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Task 5 – RED → GREEN test.
 *
 * Verifies that OrderSummaryResponse.from(Order, List<OrderItem>) computes
 * totalAmount, itemCount, and firstItemImageUrl correctly.
 */
class OrderSummaryResponseMappingTest {

    private static OrderItem item(String productId, long qty, String price, String name, String imageUrl) {
        return OrderItem.builder()
                .productId(productId)
                .quantity(qty)
                .price(Double.parseDouble(price))
                .productName(name)
                .imageUrl(imageUrl)
                .build();
    }

    private static Order orderWithItems(List<OrderItem> items) {
        // items are passed separately to from(); Order just needs minimal fields
        return Order.builder()
                .id("order-1")
                .status(OrderStatus.PROCESSING)
                .address("123 Street")
                .phoneNumber("0123456789")
                .userId("user-1")
                .build();
    }

    @Test
    void summary_zeroItems_returnsZeroTotal() {
        Order o = orderWithItems(List.of());
        OrderSummaryResponse r = OrderSummaryResponse.from(o, List.of());
        assertThat(r.getTotalAmount()).isEqualByComparingTo(BigDecimal.ZERO);
        assertThat(r.getItemCount()).isZero();
        assertThat(r.getFirstItemImageUrl()).isNull();
    }

    @Test
    void summary_oneItem_sumsCorrectly() {
        List<OrderItem> items = List.of(item("p1", 2, "9.99", "Widget", "https://x/1.png"));
        Order o = orderWithItems(items);
        OrderSummaryResponse r = OrderSummaryResponse.from(o, items);
        assertThat(r.getTotalAmount()).isEqualByComparingTo("19.98");
        assertThat(r.getItemCount()).isEqualTo(1);
        assertThat(r.getFirstItemImageUrl()).isEqualTo("https://x/1.png");
    }

    @Test
    void summary_threeItems_sumsAndPicksFirstImage() {
        List<OrderItem> items = List.of(
                item("p1", 1, "10.00", "A", "https://x/1.png"),
                item("p2", 3, "5.50", "B", "https://x/2.png"),
                item("p3", 2, "1.00", "C", null));
        Order o = orderWithItems(items);
        OrderSummaryResponse r = OrderSummaryResponse.from(o, items);
        assertThat(r.getTotalAmount()).isEqualByComparingTo("28.50");
        assertThat(r.getItemCount()).isEqualTo(3);
        assertThat(r.getFirstItemImageUrl()).isEqualTo("https://x/1.png");
    }
}
