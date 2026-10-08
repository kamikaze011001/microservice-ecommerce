package org.aibles.ecommerce.core_mongo_event.entity;

import lombok.Builder;
import lombok.Data;
import org.springframework.data.annotation.CreatedDate;
import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.mapping.Document;

import java.time.LocalDateTime;

/**
 * One row of the Mongo `event` collection. The MongoDB source connector turns
 * every insert into a Kafka record on `ecommerce_db.ecommerce_inventory.event`.
 *
 * {@code aggregateId} is top-level on purpose: the connector can only project
 * top-level change-stream fields into the record KEY, and the key decides the
 * partition — so every event of one order/product lands on one partition, in order.
 */
@Data
@Document("event")
@Builder
public class Event {

    @Id
    private String id;

    private String name;

    /** orderId for saga events, productId for product events. Never blank. */
    private String aggregateId;

    private String data;

    @CreatedDate
    private LocalDateTime createdAt;
}
