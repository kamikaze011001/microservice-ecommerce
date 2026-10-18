package org.aibles.payment_service.repository;

import org.aibles.payment_service.constant.PaymentStatus;
import org.aibles.payment_service.entity.Payment;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.Optional;

/**
 * One repository, one datasource (ProxySQL — ADR 0012). Every query here reads
 * the primary: payment is money, and each lookup either drives a state
 * transition or answers "did my payment go through?" right after a write.
 * None qualifies for {@code @ReplicaRead}.
 */
@Repository
public interface PaymentRepository extends JpaRepository<Payment, String> {

    @Modifying
    @Query(value = "update Payment p set p.status = :status where p.orderId = :orderId")
    void updateStatus(String orderId, PaymentStatus status);

    @Modifying
    @Query(value = "update Payment p set p.status = :status, p.captureId = :captureId where p.orderId = :orderId")
    void markSuccess(String orderId, PaymentStatus status, String captureId);

    Optional<Payment> findByToken(String token);

    Optional<Payment> findByOrderId(String orderId);
}
