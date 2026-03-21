package org.aibles.payment_service.repository.slave;

import org.aibles.payment_service.entity.Payment;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.Optional;

@Repository
public interface SlavePaymentRepo extends JpaRepository<Payment, String> {

    Optional<Payment> findByToken(String token);

    Optional<Payment> findByOrderId(String orderId);
}
