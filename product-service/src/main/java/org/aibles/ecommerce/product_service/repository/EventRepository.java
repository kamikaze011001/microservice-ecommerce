package org.aibles.ecommerce.product_service.repository;

import org.aibles.ecommerce.product_service.entity.Event;
import org.springframework.data.mongodb.repository.MongoRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface EventRepository extends MongoRepository<Event, String> {
}
