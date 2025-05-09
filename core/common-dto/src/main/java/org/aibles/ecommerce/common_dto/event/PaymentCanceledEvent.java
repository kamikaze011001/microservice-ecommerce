package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;

@Getter
public class PaymentCanceledEvent extends BaseEvent {
    public PaymentCanceledEvent(Object source, Object data) {
        super(source, data);
    }
}
