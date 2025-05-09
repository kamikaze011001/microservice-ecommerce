package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;

@Getter
public class ProductUpdateEvent extends BaseEvent {

    public ProductUpdateEvent(Object source, Object data) {
        super(source, data);
    }
}
