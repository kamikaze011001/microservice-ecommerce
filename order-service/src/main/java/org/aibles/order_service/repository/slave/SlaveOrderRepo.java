package org.aibles.order_service.repository.slave;

import org.aibles.order_service.entity.Order;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface SlaveOrderRepo extends JpaRepository<Order, String> {
}
