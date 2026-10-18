package org.aibles.order_service.repository;

import org.aibles.order_service.entity.OrderItem;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.Collection;
import java.util.List;

@Repository
public interface OrderItemRepository extends JpaRepository<OrderItem, String> {

    List<OrderItem> findAllByOrderId(String orderId);

    /** One query for a whole page of orders (the order list used to run one per order). */
    List<OrderItem> findAllByOrderIdIn(Collection<String> orderIds);
}
