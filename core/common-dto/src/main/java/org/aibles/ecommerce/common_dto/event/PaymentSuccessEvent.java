package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;

@Getter
public class PaymentSuccessEvent extends BaseEvent {

    public PaymentSuccessEvent(Object source, Object data) {
        super(source, data);
    }
}
