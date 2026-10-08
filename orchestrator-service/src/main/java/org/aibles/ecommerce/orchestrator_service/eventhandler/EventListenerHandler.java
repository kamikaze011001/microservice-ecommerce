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
import java.time.Duration;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import org.apache.avro.Schema;

@Component
@Slf4j
@RequiredArgsConstructor
public class EventListenerHandler {

    private final KafkaTemplate<String, Object> kafkaTemplate;
    private final ApplicationKafkaProperties applicationKafkaProperties;
    /** Bounded so a hung broker can't hold the CDC consumer past max.poll.interval.ms (5 min). */
    private static final Duration SEND_ACK_TIMEOUT = Duration.ofSeconds(10);
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
            publishToTopics(converted, converted.getProductId().toString(), Collections.singletonList(
                    "product-service.product.update-quantity"
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
            publishToTopics(converted, converted.getId().toString(), Collections.singletonList(
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
     * Publishes a message to each topic, keyed by {@code productId} so every update
     * of one product lands on one partition and is applied in order.
     *
     * Waits for the broker ack and throws if it doesn't come: this runs on the CDC
     * consumer thread, so the exception makes the container retry the CDC record.
     * Swallowing it would commit the offset and lose the update for good.
     *
     * @param message   The message to publish
     * @param productId Kafka record key
     * @param topicKeys List of topic keys to publish to
     */
    private void publishToTopics(Object message, String productId, List<String> topicKeys) {
        for (String topicKey : topicKeys) {
            String topic = applicationKafkaProperties.getTopics().get(topicKey);
            try {
                kafkaTemplate.send(topic, productId, message)
                        .get(SEND_ACK_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException("interrupted forwarding to " + topic + " productId=" + productId, e);
            } catch (ExecutionException | TimeoutException e) {
                throw new IllegalStateException("forward not acknowledged. topic=" + topic + " productId=" + productId, e);
            }
        }
    }
}