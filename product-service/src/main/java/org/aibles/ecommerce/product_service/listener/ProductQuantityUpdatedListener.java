package org.aibles.ecommerce.product_service.listener;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.ProductQuantityUpdated;
import org.aibles.ecommerce.common_dto.event.EventHeaders;
import org.aibles.ecommerce.product_service.entity.ProductQuantityHistory;
import org.aibles.ecommerce.product_service.repository.ProductQuantityHistoryRepo;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.messaging.handler.annotation.Payload;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;

@Component
@Slf4j
public class ProductQuantityUpdatedListener {

    private final ProductQuantityHistoryRepo productQuantityHistoryRepo;

    public ProductQuantityUpdatedListener(ProductQuantityHistoryRepo productQuantityHistoryRepo) {
        this.productQuantityHistoryRepo = productQuantityHistoryRepo;
    }

    /**
     * Appends one stock-ledger row per stock change — exactly once per source event.
     *
     * A ledger delta has no natural business key (two identical "−2" rows can both be
     * real), so the row's {@code _id} is the id of the event it came from: the
     * {@link EventHeaders#SOURCE_EVENT_ID} header the orchestrator copies from the CDC
     * record, or this record's own coordinates when the header is absent. A redelivery
     * — of this record, or of the CDC record that produced it — carries the same id,
     * hits Mongo's built-in unique {@code _id} index, and is skipped. No extra index needed.
     */
    @KafkaListener(groupId = "${application.kafka.group-id.product-service.product.update-quantity}",
    topics = "${application.kafka.topics.product-service.product.update-quantity}")
    public void handle(
            @Payload ProductQuantityUpdated productQuantityUpdated,
            @Header(name = EventHeaders.SOURCE_EVENT_ID, required = false) Object sourceEventId,
            @Header(KafkaHeaders.RECEIVED_TOPIC) String topic,
            @Header(KafkaHeaders.RECEIVED_PARTITION) Integer partition,
            @Header(KafkaHeaders.OFFSET) Long offset) {
        String eventId = sourceEventId != null
                ? asString(sourceEventId)
                : topic + "-" + partition + "-" + offset;

        ProductQuantityHistory productQuantityHistory = ProductQuantityHistory.builder()
                .id(eventId)
                .productId(productQuantityUpdated.getProductId().toString())
                .quantity(productQuantityUpdated.getQuantity())
                // set explicitly: with a caller-supplied id, auditing treats the row as
                // not-new and would leave @CreatedDate null
                .createdAt(LocalDateTime.now())
                .build();
        try {
            productQuantityHistoryRepo.insert(productQuantityHistory);
        } catch (DuplicateKeyException e) {
            log.info("stock-ledger row already written, skipping redelivery. eventId={} productId={}",
                    eventId, productQuantityHistory.getProductId());
        }
    }

    private static String asString(Object headerValue) {
        return headerValue instanceof byte[] bytes ? new String(bytes, StandardCharsets.UTF_8) : headerValue.toString();
    }
}
