package org.aibles.payment_service.entity;

import jakarta.persistence.*;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.payment_service.constant.PaymentStatus;
import org.aibles.payment_service.constant.PaymentType;

@Entity
@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class Payment {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private String id;

    @Enumerated(EnumType.STRING)
    private PaymentType type;

    private String orderId;

    @Enumerated(EnumType.STRING)
    private PaymentStatus status;

    private Double totalPrice;
}
