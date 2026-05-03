package org.aibles.ecommerce.bff_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class CartItemView {
    private String shoppingCartItemId;
    private String productId;
    private String name;
    private String imageUrl;
    private Double unitPrice;
    private Long quantity;
    private Long availableStock;
}
