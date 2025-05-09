package org.aibles.payment_service.repository.master;

import org.aibles.payment_service.constant.PaymentStatus;
import org.aibles.payment_service.entity.Payment;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

@Repository
public interface MasterPaymentRepo extends JpaRepository<Payment, String> {

    @Modifying
    @Query(value = "update Payment p set p.status = :status where p.orderId = :orderId")
    void updateStatus(String orderId, PaymentStatus status);
}
