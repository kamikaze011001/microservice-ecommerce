package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;
import org.springframework.context.ApplicationEvent;

@Getter
public class MongoSavedEvent extends ApplicationEvent {

    private final String eventName;

    private final Object data;

    public MongoSavedEvent(Object source, String eventName, Object data) {
        super(source);
        this.eventName = eventName;
        this.data = data;
    }
}
