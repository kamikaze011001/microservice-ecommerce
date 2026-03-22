package org.aibles.ecommerce.orchestrator_service.listener;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.event.BaseEvent;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.orchestrator_service.dto.EventDTO;
import org.aibles.ecommerce.orchestrator_service.service.SagaOrchestrationService;
import org.apache.avro.generic.GenericRecord;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.messaging.handler.annotation.Payload;
import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.Optional;
import java.util.Set;

@Slf4j
@Component
public class MongoEventListener {

    private static final Set<String> SAGA_PAYMENT_EVENTS = Set.of(
            EcommerceEvent.PAYMENT_SUCCESS.getValue(),
            EcommerceEvent.PAYMENT_FAILED.getValue(),
            EcommerceEvent.PAYMENT_CANCELED.getValue()
    );

    private final ObjectMapper mapper;
    private final ApplicationEventPublisher eventPublisher;
    private final SagaOrchestrationService sagaOrchestrationService;

    public MongoEventListener(ObjectMapper mapper,
                              ApplicationEventPublisher eventPublisher,
                              SagaOrchestrationService sagaOrchestrationService) {
        this.mapper = mapper;
        this.eventPublisher = eventPublisher;
        this.sagaOrchestrationService = sagaOrchestrationService;
    }

    @KafkaListener(groupId = "${application.kafka.group-id.mongo.event}",
    topics = "${application.kafka.topics.mongo.event}")
    private void handleChangeStream(@Payload final GenericRecord genericRecord,
                                    @Header(KafkaHeaders.OFFSET) final Long offset) throws JsonProcessingException {
        log.info("(handleChangeStream) offset: {}", offset);

        Object fullDocumentObj = genericRecord.get("fullDocument");
        if (fullDocumentObj == null) {
            log.warn("(handleChangeStream) fullDocument is null, skipping");
            return;
        }

        EventDTO eventDTO = mapper.readValue(fullDocumentObj.toString(), EventDTO.class);

        Optional<EcommerceEvent> eventOptional = EcommerceEvent.resolve(eventDTO.getName());
        if (eventOptional.isEmpty()) {
            log.warn("(handleChangeStream) unknown event name: {} — skipping", eventDTO.getName());
            return;
        }

        EcommerceEvent ecommerceEvent = eventOptional.get();
        String eventName = ecommerceEvent.getValue();

        // Route Order.Created to saga orchestrator
        if (EcommerceEvent.ORDER_CREATED.getValue().equals(eventName)) {
            String orderId = extractOrderId(eventDTO.getData());
            if (orderId == null) {
                log.warn("(handleChangeStream) Could not extract orderId from Order.Created data: {} — skipping", eventDTO.getData());
                return;
            }
            sagaOrchestrationService.startSaga(orderId);
            return;
        }

        // Route Payment.* to saga orchestrator
        if (SAGA_PAYMENT_EVENTS.contains(eventName)) {
            BaseEvent baseEvent = ecommerceEvent.createEvent(this, eventDTO.getData());
            sagaOrchestrationService.handlePaymentReply(baseEvent);
            return;
        }

        // Flows 2 & 3: stateless routing via EventListenerHandler
        eventPublisher.publishEvent(ecommerceEvent.createEvent(this, eventDTO.getData()));
    }

    private String extractOrderId(Object data) {
        if (data instanceof Map) {
            Object id = ((Map<?, ?>) data).get("orderId");
            return id != null ? id.toString() : null;
        }
        return null;
    }
}
