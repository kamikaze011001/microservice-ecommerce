package org.aibles.ecommerce.bff_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record OrderItemView(
        String id,
        String productId,
        String productName,
        String imageUrl,
        Double price,
        Long quantity
) {}
