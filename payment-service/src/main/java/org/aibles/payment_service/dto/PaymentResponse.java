package org.aibles.payment_service.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.payment_service.entity.Payment;

@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class PaymentResponse {

    private String id;
    private String orderId;
    private String status;
    private String type;
    private Double totalPrice;

    public static PaymentResponse from(Payment payment) {
        return PaymentResponse.builder()
                .id(payment.getId())
                .orderId(payment.getOrderId())
                .status(payment.getStatus().name())
                .type(payment.getType().name())
                .totalPrice(payment.getTotalPrice())
                .build();
    }
}
