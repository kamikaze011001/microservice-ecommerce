package org.aibles.ecommerce.core_paypal.dto;

import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class CreatePaypalOrderRequest {

    private String orderId;
    private double amount;
}
