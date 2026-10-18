package org.aibles.payment_service.service;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentFailed;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentSuccess;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.payment_service.constant.PaymentStatus;
import org.aibles.payment_service.constant.PaymentType;
import org.aibles.payment_service.entity.Payment;
import org.aibles.payment_service.repository.PaymentRepository;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.transaction.annotation.Transactional;

/**
 * Short transactional writes for the payment lifecycle. Lives in its own bean
 * (not PaymentServiceImpl) so @Transactional applies through the Spring proxy —
 * and so no PayPal HTTP call can ever run inside a DB transaction again
 * (Atomikos maxActives saturation, stress run 2026-06-10).
 */
@Slf4j
public class PaymentRecorder {

    private final PaymentRepository paymentRepository;

    private final ApplicationEventPublisher eventPublisher;

    public PaymentRecorder(PaymentRepository paymentRepository, ApplicationEventPublisher eventPublisher) {
        this.paymentRepository = paymentRepository;
        this.eventPublisher = eventPublisher;
    }

    @Transactional
    public void recordPurchase(String orderId, double totalPrice, String paypalToken) {
        // Upsert: reuse the existing Payment row for this order if one exists (the
        // user cancelled a prior attempt and is retrying). The whole lifecycle
        // assumes ONE Payment per order. Primary read (ProxySQL default) for read-your-writes.
        Payment payment = paymentRepository.findByOrderId(orderId)
                .map(existing -> {
                    existing.setType(PaymentType.PURCHASE);
                    existing.setStatus(PaymentStatus.PROCESSING);
                    existing.setToken(paypalToken);
                    existing.setTotalPrice(totalPrice);
                    existing.setCaptureId(null);
                    return existing;
                })
                .orElseGet(() -> Payment.builder()
                        .type(PaymentType.PURCHASE)
                        .orderId(orderId)
                        .status(PaymentStatus.PROCESSING)
                        .token(paypalToken)
                        .totalPrice(totalPrice)
                        .build());
        paymentRepository.save(payment);
    }

    @Transactional
    public void recordSuccess(String orderId, String captureId) {
        paymentRepository.markSuccess(orderId, PaymentStatus.SUCCESS, captureId);
        eventPublisher.publishEvent(new MongoSavedEvent(this,
                EcommerceEvent.PAYMENT_SUCCESS.getValue(),
                orderId,
                PaymentSuccess.newBuilder().setOrderId(orderId).build()));
    }

    @Transactional
    public void recordCancel(String orderId) {
        paymentRepository.updateStatus(orderId, PaymentStatus.CANCELED);
        eventPublisher.publishEvent(new MongoSavedEvent(this,
                EcommerceEvent.PAYMENT_CANCELED.getValue(),
                orderId,
                PaymentCanceled.newBuilder().setOrderId(orderId).build()));
    }

    @Transactional
    public void recordFailure(String orderId) {
        paymentRepository.updateStatus(orderId, PaymentStatus.FAILED);
        eventPublisher.publishEvent(new MongoSavedEvent(this,
                EcommerceEvent.PAYMENT_FAILED.getValue(),
                orderId,
                PaymentFailed.newBuilder().setOrderId(orderId).build()));
    }
}
