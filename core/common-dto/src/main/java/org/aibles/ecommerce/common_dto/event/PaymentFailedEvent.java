package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;

@Getter
public class PaymentFailedEvent extends BaseEvent {

    public PaymentFailedEvent(Object source, Object data) {
        super(source, data);
    }
}
