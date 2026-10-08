package org.aibles.ecommerce.core_mongo_event.listener;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.core_mongo_event.entity.Event;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;

/**
 * Persists every {@link MongoSavedEvent} into the `event` collection, which the
 * CDC connector publishes to Kafka. Replaces the four per-service copies.
 *
 * Uses MongoTemplate rather than a repository: a repository in this package is
 * outside each service's scan root, and adding @EnableMongoRepositories here
 * would switch off auto-discovery of the services' own repositories.
 */
@Slf4j
public class MongoSavedEventListener {

    private final MongoTemplate mongoTemplate;

    public MongoSavedEventListener(MongoTemplate mongoTemplate) {
        this.mongoTemplate = mongoTemplate;
    }

    /**
     * AFTER_COMMIT: a rolled-back business transaction must not emit an event.
     * fallbackExecution: publishers with no transaction (product-service) would
     * otherwise be dropped silently. Deliberately NOT @Async: an async write can
     * land in Mongo after a later event of the same aggregate, and Kafka keys
     * cannot restore an order that was lost before Kafka saw it.
     */
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT, fallbackExecution = true)
    public void handle(final MongoSavedEvent event) {
        String aggregateId = event.getAggregateId();
        if (aggregateId == null || aggregateId.isBlank()) {
            // A blank id becomes a null Kafka key → round-robin partition → the
            // aggregate's ordering is silently lost. Fail at the write instead.
            throw new IllegalArgumentException(
                    "MongoSavedEvent " + event.getEventName() + " has no aggregateId");
        }

        mongoTemplate.insert(Event.builder()
                .name(event.getEventName())
                .aggregateId(aggregateId)
                .data(event.getData().toString())
                .build());
        log.debug("event written name={} aggregateId={}", event.getEventName(), aggregateId);
    }
}
