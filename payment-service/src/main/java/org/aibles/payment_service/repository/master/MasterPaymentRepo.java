package org.aibles.payment_service.repository.master;

import org.aibles.payment_service.constant.PaymentStatus;
import org.aibles.payment_service.entity.Payment;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.Optional;

@Repository
public interface MasterPaymentRepo extends JpaRepository<Payment, String> {

    @Modifying
    @Query(value = "update Payment p set p.status = :status where p.orderId = :orderId")
    void updateStatus(String orderId, PaymentStatus status);

    @Modifying
    @Query(value = "update Payment p set p.status = :status, p.captureId = :captureId where p.orderId = :orderId")
    void markSuccess(String orderId, PaymentStatus status, String captureId);

    // Read-your-writes lookups for the payment lifecycle (PayPal success/cancel
    // callbacks). These reads immediately follow the create-payment write and
    // drive state transitions, so they must hit the primary — a lagging replica
    // could miss the just-written row and drop a succeeded payment. The
    // user-facing getByOrderId query stays on the slave (eventual consistency OK).
    Optional<Payment> findByToken(String token);

    Optional<Payment> findByOrderId(String orderId);
}
