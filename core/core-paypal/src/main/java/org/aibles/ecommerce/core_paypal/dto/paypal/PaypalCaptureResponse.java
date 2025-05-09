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
public class PaypalCaptureResponse {

    private String id;

    private String status;

    private String createdTime;

    private String updatedTime;

    private List<PaymentSource> paymentSources;

    private List<PurchaseUnit> purchaseUnits;

    private String intent;


}
