package org.aibles.ecommerce.orchestrator_service.eventhandler;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.*;
import org.aibles.ecommerce.common_dto.event.*;
import org.aibles.ecommerce.orchestrator_service.config.ApplicationKafkaProperties;
import org.aibles.ecommerce.orchestrator_service.util.AvroConverter;
import org.apache.avro.specific.SpecificRecordBase;
import org.springframework.context.event.EventListener;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.util.Collections;
import java.util.List;
import org.apache.avro.Schema;

@Component
@Slf4j
@RequiredArgsConstructor
public class EventListenerHandler {

    private final KafkaTemplate<String, Object> kafkaTemplate;
    private final ApplicationKafkaProperties applicationKafkaProperties;
    private static final String FAILED_CONVERT_OBJECT_MSG = "Failed to convert data to avro object";

    @EventListener
    private void handleProductQuantityUpdated(ProductQuantityUpdatedEvent event) {
        log.info("handle product quantity updated event : {}", event.getData());

        ProductQuantityUpdated converted = convertEventData(
                event.getData().toString(),
                ProductQuantityUpdated.class,
                ProductQuantityUpdated.SCHEMA$,
                "product quantity updated event"
        );

        if (converted != null) {
            publishToTopics(converted, Collections.singletonList(
                    "product-service.product.update-quantity"
            ));
        }
    }

    @EventListener
    private void handlePaymentSuccess(PaymentSuccessEvent event) {
        log.info("handle payment success event : {}", event.getData());

        PaymentSuccess converted = convertEventData(
                event.getData().toString(),
                PaymentSuccess.class,
                PaymentSuccess.SCHEMA$,
                "payment success event"
        );

        if (converted != null) {
            publishToTopics(converted, List.of(
                    "order-service.order.success-status",
                    "inventory-service.inventory-product.update-quantity"
            ));
        }
    }

    @EventListener
    private void handlePaymentFailed(PaymentFailedEvent event) {
        log.info("handle payment failed event : {}", event.getData());

        PaymentFailed converted = convertEventData(
                event.getData().toString(),
                PaymentFailed.class,
                PaymentFailed.SCHEMA$,
                "payment failed event"
        );

        if (converted != null) {
            publishToTopics(converted, Collections.singletonList(
                    "order-service.order.failed-status"
            ));
        }
    }

    @EventListener
    private void handlePaymentCanceled(PaymentCanceledEvent event) {
        log.info("handle payment canceled event : {}", event.getData());

        PaymentCanceled converted = convertEventData(
                event.getData().toString(),
                PaymentCanceled.class,
                PaymentCanceled.SCHEMA$,
                "payment canceled event"
        );

        if (converted != null) {
            publishToTopics(converted, Collections.singletonList(
                    "order-service.order.canceled-status"
            ));
        }
    }

    @EventListener
    private void handleProductUpdate(ProductUpdateEvent event) {
        log.info("handle product update event : {}", event.getData());
        ProductUpdate converted = convertEventData(
                event.getData().toString(),
                ProductUpdate.class,
                ProductUpdate.SCHEMA$,
                "product update event"
        );

        if (converted != null) {
            publishToTopics(converted, Collections.singletonList(
                    "inventory-service.product.update"
            ));
        }
    }

    /**
     * Generic method to convert event data to specific Avro object
     *
     * @param data The event data as string
     * @param targetClass The class to convert to
     * @param schema The Avro schema
     * @param eventName Name of the event for logging
     * @return Converted object or null if conversion failed
     */
    private <T extends SpecificRecordBase> T convertEventData(String data, Class<T> targetClass, Schema schema, String eventName) {
        try {
            T converted = AvroConverter.convert(data, targetClass, schema);
            if (converted == null) {
                log.warn("({}){} is null", Thread.currentThread().getStackTrace()[2].getMethodName(), eventName);
            }
            return converted;
        } catch (IOException ex) {
            log.error(FAILED_CONVERT_OBJECT_MSG, ex);
            return null;
        }
    }

    /**
     * Publishes a message to multiple Kafka topics
     *
     * @param message The message to publish
     * @param topicKeys List of topic keys to publish to
     */
    private void publishToTopics(Object message, List<String> topicKeys) {
        for (String topicKey : topicKeys) {
            String topic = applicationKafkaProperties.getTopics().get(topicKey);
            kafkaTemplate.send(topic, message);
        }
    }
}