package org.aibles.ecommerce.orchestrator_service.listener;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.orchestrator_service.dto.EventDTO;
import org.apache.avro.generic.GenericRecord;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.messaging.handler.annotation.Payload;
import org.springframework.stereotype.Component;

import java.util.Optional;

@Slf4j
@Component
public class MongoEventListener {

    private final ObjectMapper mapper;

    private final ApplicationEventPublisher eventPublisher;

    public MongoEventListener(ObjectMapper mapper, ApplicationEventPublisher eventPublisher) {
        this.mapper = mapper;
        this.eventPublisher = eventPublisher;
    }

    @KafkaListener(groupId = "${application.kafka.group-id.mongo.event}",
    topics = "${application.kafka.topics.mongo.event}")
    private void handleChangeStream(@Payload final GenericRecord genericRecord,
                                    @Header(KafkaHeaders.OFFSET) final Long offset) throws JsonProcessingException {
        log.info("(handleChangeStream)stream: {}, offset: {}", genericRecord, offset);
        String fullDocument = genericRecord.get("fullDocument").toString();
        EventDTO eventDTO = mapper.readValue(fullDocument, EventDTO.class);
        Optional<EcommerceEvent> eventOptional = EcommerceEvent.resolve(eventDTO.getName());
        if (eventOptional.isEmpty()) {
            log.warn("(handleChangeStream)event name : {} is not available", eventDTO.getName());
            return;
        }
        EcommerceEvent event = eventOptional.get();
        eventPublisher.publishEvent(event.createEvent(this, eventDTO.getData()));
    }
}
