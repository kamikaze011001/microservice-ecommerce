package org.aibles.ecommerce.orchestrator_service.entity;

import lombok.Getter;

/**
 * Why a saga is being compensated. The reason alone decides BOTH the topic and
 * the Avro record type, so a caller can no longer pair a topic with the wrong
 * payload (the PaymentFailed-on-canceled-status bug).
 */
@Getter
public enum CompensationReason {

    /** Payment declined, or a downstream send failed mid-saga → order FAILED. */
    PAYMENT_FAILED("order-service.order.failed-status"),

    /** Never paid before {@code expiresAt} → order CANCELED. */
    TIMED_OUT("order-service.order.canceled-status");

    private final String topicKey;

    CompensationReason(String topicKey) {
        this.topicKey = topicKey;
    }

}
