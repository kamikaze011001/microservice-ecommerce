package org.aibles.order_service.repository;

import org.aibles.order_service.constant.OrderStatus;
import org.aibles.order_service.entity.Order;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.Optional;

@Repository
public interface OrderRepository extends JpaRepository<Order, String> {

    Page<Order> findAllByUserId(String userId, Pageable pageable);

    Optional<Order> findByIdAndUserId(String id, String userId);

    @Modifying
    @Query("update Order o set o.status = :status where o.id = :orderId")
    void updateStatus(String orderId, OrderStatus status);

    /**
     * State guard: moves the order to {@code to} only while it is still {@code from}.
     * Returns 1 for the one caller that made the transition, 0 for every redelivery,
     * concurrent duplicate, or out-of-order event (e.g. a cancel after COMPLETED).
     * The row lock taken by the UPDATE serializes concurrent consumers.
     */
    @Modifying
    @Query("update Order o set o.status = :to where o.id = :orderId and o.status = :from")
    int updateStatusIfCurrent(String orderId, OrderStatus from, OrderStatus to);
}
