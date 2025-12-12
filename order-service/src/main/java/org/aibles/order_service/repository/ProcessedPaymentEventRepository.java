package org.aibles.order_service.repository;

import org.aibles.order_service.entity.ProcessedPaymentEvent;
import org.springframework.data.mongodb.repository.MongoRepository;
import org.springframework.stereotype.Repository;

/**
 * Repository for tracking processed payment events to ensure idempotency.
 *
 * The unique compound index on (orderId, eventType) in the entity ensures
 * that attempting to insert a duplicate event will throw DuplicateKeyException.
 */
@Repository
public interface ProcessedPaymentEventRepository extends MongoRepository<ProcessedPaymentEvent, String> {
}