package org.aibles.ecommerce.bff_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PaymentView(
        String id,
        String orderId,
        String status,
        String type,
        Double totalPrice
) {}
