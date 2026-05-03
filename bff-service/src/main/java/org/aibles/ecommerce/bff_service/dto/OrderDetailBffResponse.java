package org.aibles.ecommerce.bff_service.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import org.aibles.ecommerce.bff_service.dto.response.OrderDetailView;
import org.aibles.ecommerce.bff_service.dto.response.PaymentView;

@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record OrderDetailBffResponse(
        OrderDetailView order,
        PaymentView payment
) {}
