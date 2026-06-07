package org.aibles.mockpaypal.store;

import org.aibles.mockpaypal.model.Decision;
import org.aibles.mockpaypal.model.OrderState;
import org.springframework.stereotype.Component;

import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

@Component
public class OrderStore {

    private final ConcurrentHashMap<String, OrderState> states = new ConcurrentHashMap<>();

    public OrderState create(String orderId, String currencyCode, String value,
                             String returnUrl, String cancelUrl) {
        String token = "MOCKORDER-" + UUID.randomUUID().toString().replace("-", "").toUpperCase();
        OrderState state = OrderState.builder()
                .token(token)
                .orderId(orderId)
                .currencyCode(currencyCode)
                .value(value)
                .returnUrl(returnUrl)
                .cancelUrl(cancelUrl)
                .decision(Decision.PENDING)
                .build();
        states.put(token, state);
        return state;
    }

    public OrderState get(String token) {
        return states.get(token);
    }

    public void setDecision(String token, Decision decision) {
        OrderState s = states.get(token);
        if (s != null) {
            s.setDecision(decision);
        }
    }

    public void setCapture(String token, String captureId) {
        OrderState s = states.get(token);
        if (s != null) {
            s.setCaptureId(captureId);
        }
    }
}
