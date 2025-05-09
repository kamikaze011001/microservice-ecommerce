package org.aibles.ecommerce.core_paypal.dto.paypal;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.util.List;

@Data
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
@AllArgsConstructor
@NoArgsConstructor
public class PaypalOrderRequest {

    private String intent;
    private List<PurchaseUnit> purchaseUnits;
    private PaymentSource paymentSource;
}
