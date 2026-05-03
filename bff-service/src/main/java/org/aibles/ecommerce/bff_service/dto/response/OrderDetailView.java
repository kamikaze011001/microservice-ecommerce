package org.aibles.ecommerce.bff_service.dto.response;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

import java.time.LocalDateTime;
import java.util.List;

@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record OrderDetailView(
        String id,
        String status,
        String address,
        String phoneNumber,
        LocalDateTime createdAt,
        LocalDateTime updatedAt,
        List<OrderItemView> items
) {}
