package org.aibles.order_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.order_service.entity.OrderItem;

@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class OrderItemResponse {

    private String id;
    private String productId;
    private Double price;
    private Long quantity;
    private String productName;
    private String imageUrl;

    public static OrderItemResponse from(OrderItem item) {
        return OrderItemResponse.builder()
                .id(item.getId())
                .productId(item.getProductId())
                .price(item.getPrice())
                .quantity(item.getQuantity())
                .productName(item.getProductName())
                .imageUrl(item.getImageUrl())
                .build();
    }
}
