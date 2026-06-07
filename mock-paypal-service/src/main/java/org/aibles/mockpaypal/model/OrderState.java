package org.aibles.mockpaypal.model;

import lombok.Builder;
import lombok.Data;
import lombok.EqualsAndHashCode;

@Data
@Builder
@EqualsAndHashCode(of = "token") // identity is the token; keep mutable fields out of equals/hashCode
public class OrderState {
    private final String token;
    private final String orderId;
    private final String currencyCode;
    private final String value;
    private final String returnUrl;
    private final String cancelUrl;
    private volatile Decision decision;
    private volatile String captureId;
}
