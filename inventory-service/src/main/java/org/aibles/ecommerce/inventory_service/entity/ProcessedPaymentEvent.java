package org.aibles.ecommerce.inventory_service.entity;

import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.ecommerce.inventory_service.constant.PaymentEventType;

import java.time.LocalDateTime;

/**
 * Inbox row: one per (order, payment event) inventory-service has applied.
 *
 * Lives in MySQL and is written in the SAME transaction as the stock decrement and
 * ledger rows it guards. So the work and the "done" mark commit or roll back
 * together: a failure leaves no mark and the redelivery redoes the work, a success
 * leaves the mark and the redelivery skips it. The old marker sat in MongoDB, was
 * written BEFORE the work and outside the MySQL transaction, so a failure after it
 * turned the retry into a silent skip — the event was lost.
 *
 * The primary key is the uniqueness guarantee: no separate index to create.
 */
@Entity
@Table(name = "processed_payment_event")
@Data
@NoArgsConstructor
@AllArgsConstructor
public class ProcessedPaymentEvent {

    /** {@code <orderId>:<eventType>} */
    @Id
    private String id;

    private String orderId;

    @Enumerated(EnumType.STRING)
    private PaymentEventType eventType;

    private LocalDateTime processedAt;

    public static String idOf(String orderId, PaymentEventType eventType) {
        return orderId + ":" + eventType;
    }

    public static ProcessedPaymentEvent of(String orderId, PaymentEventType eventType) {
        return new ProcessedPaymentEvent(idOf(orderId, eventType), orderId, eventType, LocalDateTime.now());
    }
}
