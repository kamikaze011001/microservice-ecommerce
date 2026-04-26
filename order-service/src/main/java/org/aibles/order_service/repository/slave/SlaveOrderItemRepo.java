package org.aibles.order_service.repository.slave;

import org.aibles.order_service.entity.OrderItem;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface SlaveOrderItemRepo extends JpaRepository<OrderItem, String> {

    List<OrderItem> findAllByOrderId(String orderId);
}
