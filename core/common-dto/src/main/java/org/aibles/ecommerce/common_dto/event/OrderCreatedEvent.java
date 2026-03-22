package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;

@Getter
public class OrderCreatedEvent extends BaseEvent {

    public OrderCreatedEvent(Object source, Object data) {
        super(source, data);
    }
}
