package org.aibles.ecommerce.common_dto.event;

/** Kafka record header names shared between producers and consumers. */
public final class EventHeaders {

    /**
     * Stable id of the event a record was derived from — the same value on every
     * redelivery or re-forward of that event. Consumers whose side effect has no
     * natural business key (e.g. a stock-ledger row) use it to deduplicate.
     */
    public static final String SOURCE_EVENT_ID = "source-event-id";

    private EventHeaders() {
    }
}
