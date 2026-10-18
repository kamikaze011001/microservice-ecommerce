package org.aibles.ecommerce.inventory_service.repository;

import org.aibles.ecommerce.inventory_service.entity.ProcessedPaymentEvent;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

// Primary only (never @ReplicaRead): the "already applied?" check must see the commit of a delivery
// that finished a moment ago on another pod. A replica can lag seconds behind
// (15 s at peak in the 2026-06-10 stress run) and would say "not yet" → double decrement.
@Repository
public interface ProcessedPaymentEventRepository extends JpaRepository<ProcessedPaymentEvent, String> {
}
