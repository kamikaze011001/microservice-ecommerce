package org.aibles.ecommerce.inventory_service.service;

/**
 * A paid order's stock change could not be applied (no order lines, or the
 * stock floor). Thrown — never logged-and-skipped — so the transaction,
 * including the inbox row, rolls back and the Kafka consumer retries and then
 * dead-letters the event: visible on the DLT dashboard and replayable with
 * `make dlt-replay`, instead of silently marked as processed.
 */
public class PaymentStockNotAppliedException extends RuntimeException {

    public PaymentStockNotAppliedException(String message) {
        super(message);
    }
}
