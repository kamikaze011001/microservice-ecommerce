package org.aibles.ecommerce.orchestrator_service.listener;

import com.fasterxml.jackson.databind.JsonNode;
import org.aibles.ecommerce.orchestrator_service.entity.SagaItem;
import java.util.ArrayList;
import java.util.List;
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
                                    @Header(KafkaHeaders.RECEIVED_TOPIC) final String topic,
                                    @Header(KafkaHeaders.RECEIVED_PARTITION) final Integer partition,
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
            sagaOrchestrationService.startSaga(orderId, extractItems(eventDTO.getData()));
            return;
        }

        // Route Payment.* to saga orchestrator
        if (SAGA_PAYMENT_EVENTS.contains(eventName)) {
            BaseEvent baseEvent = ecommerceEvent.createEvent(this, eventDTO.getData());
            sagaOrchestrationService.handlePaymentReply(baseEvent);
            return;
        }

        // Flows 2 & 3: stateless routing via EventListenerHandler. The CDC record is the
        // event source so the forward can carry its id for downstream deduplication.
        eventPublisher.publishEvent(ecommerceEvent.createEvent(
                new CdcRecordSource(topic, partition, offset), eventDTO.getData()));
    }

    /**
     * The order's lines from Order.Created data — a Map, or the JSON string the
     * Avro record's toString() wrote to Mongo. Empty when the event predates
     * them (or has none); the saga then forwards no lines and inventory falls
     * back to its old lookup.
     */
    List<SagaItem> extractItems(Object data) {
        JsonNode items;
        if (data instanceof String str) {
            try {
                items = mapper.readTree(str).path("items");
            } catch (Exception e) {
                log.warn("(extractItems) unparseable Order.Created data, no lines taken: {}", str, e);
                return List.of();
            }
        } else if (data instanceof Map) {
            items = mapper.valueToTree(((Map<?, ?>) data).get("items"));
        } else {
            return List.of();
        }
        if (items == null || !items.isArray()) {
            return List.of();
        }
        List<SagaItem> out = new ArrayList<>();
        for (JsonNode item : items) {
            String productId = item.path("productId").asText(null);
            long quantity = item.path("quantity").asLong(0);
            if (productId == null || quantity <= 0) {
                log.warn("(extractItems) skipping malformed line in Order.Created: {}", item);
                continue;
            }
            out.add(new SagaItem(productId, quantity));
        }
        return out;
    }

    private String extractOrderId(Object data) {
        if (data instanceof Map) {
            Object id = ((Map<?, ?>) data).get("orderId");
            return id != null ? id.toString() : null;
        }
        if (data instanceof String str) {
            try {
                return mapper.readTree(str).path("orderId").asText(null);
            } catch (Exception e) {
                log.warn("(extractOrderId) Failed to parse orderId from String data: {}", str, e);
                return null;
            }
        }
        return null;
    }
}
