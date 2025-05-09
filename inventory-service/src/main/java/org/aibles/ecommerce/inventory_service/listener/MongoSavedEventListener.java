package org.aibles.ecommerce.inventory_service.listener;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.inventory_service.entity.Event;
import org.aibles.ecommerce.inventory_service.repository.EventRepository;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;

@Component
@Slf4j
@RequiredArgsConstructor
public class MongoSavedEventListener {

    private final EventRepository eventRepository;

    @EventListener
    @Async
    public void handle(final MongoSavedEvent event) {
        log.info("(handle)event : {}", event);
        Event eventData = Event.builder()
                .name(event.getEventName())
                .data(event.getData().toString())
                .build();
        eventRepository.save(eventData);
    }
}
