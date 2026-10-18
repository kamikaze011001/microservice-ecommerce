package org.aibles.order_service.repository.master;

import org.aibles.order_service.entity.OrderItem;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface MasterOrderItemRepo extends JpaRepository<OrderItem, String> {
}
