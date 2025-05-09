package org.aibles.order_service.repository.master;

import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.entity.Order;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

@Repository
public interface MasterOrderRepo extends JpaRepository<Order, String> {

    @Modifying
    @Query("update Order o set o.status = :status where o.id = :orderId")
    void updateStatus(String orderId, OrderStatus status);
}
