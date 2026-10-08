package org.aibles.ecommerce.orchestrator_service.listener;

/**
 * The CDC record an in-process event was built from, used as the event's source.
 * Its coordinates identify the original database change: a redelivery of the same
 * CDC record carries the same topic/partition/offset, so anything forwarded from
 * it can be deduplicated downstream.
 */
public record CdcRecordSource(String topic, int partition, long offset) {

    public String eventId() {
        return topic + "-" + partition + "-" + offset;
    }
}
