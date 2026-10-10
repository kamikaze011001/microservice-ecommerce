package org.aibles.ecommerce.orchestrator_service.entity;

/**
 * One line of the order the saga is running for. The saga receives the lines
 * with Order.Created and hands them to inventory with PaymentSuccess, so the
 * stock decrement never has to look the order up — in particular not in the
 * Redis pending-order index, which a Redis restart loses.
 */
public record SagaItem(String productId, long quantity) {
}
