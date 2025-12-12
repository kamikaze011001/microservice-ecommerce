package org.aibles.order_service.entity;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.springframework.data.annotation.CreatedDate;
import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.index.CompoundIndex;
import org.springframework.data.mongodb.core.mapping.Document;

import java.time.LocalDateTime;

/**
 * Tracks processed payment events to ensure idempotency.
 * Prevents duplicate processing when Kafka delivers same event multiple times.
 *
 * MongoDB compound unique index on (orderId, eventType) ensures atomic deduplication.
 */
@Data
@NoArgsConstructor
@AllArgsConstructor
@Builder
@Document(collection = "processed_payment_events")
@CompoundIndex(
    name = "unique_order_event",
    def = "{'orderId': 1, 'eventType': 1}",
    unique = true
)
public class ProcessedPaymentEvent {

    @Id
    private String id;

    /**
     * Order ID that this event processed
     */
    private String orderId;

    /**
     * Type of payment event: PAYMENT_SUCCESS, PAYMENT_FAILED, PAYMENT_CANCELED
     */
    private String eventType;

    /**
     * When this event was first processed
     */
    @CreatedDate
    private LocalDateTime processedAt;

    /**
     * Kafka partition for debugging (optional)
     */
    private Integer kafkaPartition;

    /**
     * Kafka offset for debugging (optional)
     */
    private Long kafkaOffset;
}