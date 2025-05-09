package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.function.BiFunction;

@Getter
public enum EcommerceEvent {

    PRODUCT_QUANTITY_UPDATED("Product.Quantity.Updated", ProductQuantityUpdatedEvent::new),
    PAYMENT_SUCCESS("Payment.Success", PaymentSuccessEvent::new),
    PAYMENT_FAILED("Payment.Failed", PaymentFailedEvent::new),
    PAYMENT_CANCELED("Payment.Canceled", PaymentCanceledEvent::new),
    PRODUCT_UPDATE("Product.Updated", ProductUpdateEvent::new);

    private final String value;
    private final BiFunction<Object, Object, BaseEvent> eventFactory;
    private static final Map<String, EcommerceEvent> eventMap = new HashMap<>();

    EcommerceEvent(String value, BiFunction<Object, Object, BaseEvent> eventFactory) {
        this.value = value;
        this.eventFactory = eventFactory;
    }

    static {
        for (EcommerceEvent ecommerceEvent : EcommerceEvent.values()) {
            eventMap.put(ecommerceEvent.value, ecommerceEvent);
        }
    }

    public static Optional<EcommerceEvent> resolve(final String value) {
        return Optional.ofNullable(eventMap.get(value));
    }

    public BaseEvent createEvent(final Object source, final Object data) {
        return eventFactory.apply(source, data);
    }
}
