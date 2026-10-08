package org.aibles.ecommerce.common_dto.event;

import lombok.Getter;
import org.springframework.context.ApplicationEvent;

@Getter
public class MongoSavedEvent extends ApplicationEvent {

    private final String eventName;

    /**
     * Id of the entity this event is about — orderId for saga events, productId
     * for product events. Becomes the Kafka record key, so every event of one
     * aggregate lands on the same partition, in order.
     */
    private final String aggregateId;

    private final Object data;

    public MongoSavedEvent(Object source, String eventName, String aggregateId, Object data) {
        super(source);
        this.eventName = eventName;
        this.aggregateId = aggregateId;
        this.data = data;
    }
}
