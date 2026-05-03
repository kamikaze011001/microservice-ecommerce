package org.aibles.order_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.order_service.entity.Order;
import org.aibles.order_service.entity.OrderItem;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class OrderSummaryResponse {

    private String id;
    private String status;
    private String address;
    private String phoneNumber;
    private LocalDateTime createdAt;
    private LocalDateTime updatedAt;
    private BigDecimal totalAmount;
    private int itemCount;
    private String firstItemImageUrl;

    public static OrderSummaryResponse from(Order order, List<OrderItem> items) {
        BigDecimal total = items.stream()
                .map(i -> BigDecimal.valueOf(i.getPrice()).multiply(BigDecimal.valueOf(i.getQuantity())))
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        int count = items.size();
        String firstImage = items.isEmpty() ? null : items.get(0).getImageUrl();

        return OrderSummaryResponse.builder()
                .id(order.getId())
                .status(order.getStatus().name())
                .address(order.getAddress())
                .phoneNumber(order.getPhoneNumber())
                .createdAt(order.getCreatedAt())
                .updatedAt(order.getUpdatedAt())
                .totalAmount(total)
                .itemCount(count)
                .firstItemImageUrl(firstImage)
                .build();
    }
}
