package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;

@Getter
public class ProductQuantityUpdatedEvent extends BaseEvent {

    public ProductQuantityUpdatedEvent(Object source, Object data) {
        super(source, data);
    }
}
