package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;
import org.springframework.context.ApplicationEvent;

@Getter
public class BaseEvent extends ApplicationEvent {

    private final Object data;

    public BaseEvent(Object source, Object data) {
        super(source);
        this.data = data;
    }
}
