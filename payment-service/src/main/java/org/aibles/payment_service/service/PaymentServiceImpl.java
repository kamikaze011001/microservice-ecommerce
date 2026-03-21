package org.aibles.payment_service.service;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentFailed;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentSuccess;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_paypal.dto.CreatePaypalOrderRequest;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalCaptureResponse;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderDetail;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderSimple;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalRestTemplateException;
import org.aibles.ecommerce.core_paypal.service.PaypalService;
import org.aibles.payment_service.constant.PaymentStatus;
import org.aibles.payment_service.constant.PaymentType;
import org.aibles.payment_service.entity.Payment;
import org.aibles.payment_service.exception.OrderInvalidException;
import org.aibles.payment_service.repository.master.MasterPaymentRepo;
import org.aibles.payment_service.repository.slave.SlavePaymentRepo;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Optional;

@Slf4j
public class PaymentServiceImpl implements PaymentService {

    private final PaypalService paypalService;

    private final PendingOrderCacheRepository pendingOrderCacheRepository;

    private final MasterPaymentRepo masterPaymentRepo;

    private final SlavePaymentRepo slavePaymentRepo;

    private final ApplicationEventPublisher eventPublisher;

    public PaymentServiceImpl(PaypalService paypalService, PendingOrderCacheRepository pendingOrderCacheRepository, MasterPaymentRepo masterPaymentRepo, SlavePaymentRepo slavePaymentRepo, ApplicationEventPublisher eventPublisher) {
        this.paypalService = paypalService;
        this.pendingOrderCacheRepository = pendingOrderCacheRepository;
        this.masterPaymentRepo = masterPaymentRepo;
        this.slavePaymentRepo = slavePaymentRepo;
        this.eventPublisher = eventPublisher;
    }

    @Override
    @Transactional
    public BaseResponse purchase(String orderId) {
        log.info("(purchase)orderId: {}", orderId);
        double totalPrice = pendingOrderCacheRepository.getOrderPrice(orderId).orElse(0.0);

        if (totalPrice == 0) {
            log.error("(purchase)orderId: {} is invalid", orderId);
            throw new OrderInvalidException(orderId);
        }

        CreatePaypalOrderRequest paymentRequest = new CreatePaypalOrderRequest();
        paymentRequest.setOrderId(orderId);
        paymentRequest.setAmount(totalPrice);

        PaypalOrderSimple paypalOrderSimple;

        try {
            paypalOrderSimple = paypalService.createOrder(List.of(paymentRequest));
        } catch (PaypalRestTemplateException e) {
            masterPaymentRepo.updateStatus(orderId, PaymentStatus.FAILED);
            PaymentFailed paymentFailed = PaymentFailed.newBuilder()
                    .setOrderId(orderId)
                    .build();
            MongoSavedEvent mongoSavedEvent = new MongoSavedEvent(
                    this,
                    EcommerceEvent.PAYMENT_FAILED.getValue(),
                    paymentFailed);
            eventPublisher.publishEvent(mongoSavedEvent);
            return BaseResponse.from(e.getStatus(), e.getCode(), e.getMessage());
        }

        Payment payment = Payment.builder()
                .type(PaymentType.PURCHASE)
                .orderId(orderId)
                .status(PaymentStatus.PROCESSING)
                .token(paypalOrderSimple.getId())
                .totalPrice(totalPrice)
                .build();

        masterPaymentRepo.save(payment);

        return BaseResponse.ok(paypalOrderSimple);
    }

    @Override
    @Transactional
    public void handleSuccessPayment(String token) {
        log.info("(handle paypal success)token: {}", token);
        String orderId;
        PaypalCaptureResponse paypalCaptureResponse;
        try {
            paypalCaptureResponse = paypalService.captureOrder(token);
            PaypalOrderDetail paypalOrderDetail = paypalService.getOrderDetails(token);
            orderId = paypalOrderDetail.getPurchaseUnits().get(0).getCustomId();
        } catch (PaypalRestTemplateException | IndexOutOfBoundsException | NullPointerException e) {
            log.error("(handleSuccessPayment)paypal failure for token: {}", token, e);
            Optional<Payment> paymentOptional = slavePaymentRepo.findByToken(token);
            if (paymentOptional.isEmpty()) {
                return;
            }
            handleFailedPayment(paymentOptional.get().getOrderId());
            return;
        }

        log.info("(handle paypal success)orderId: {}", orderId);

        if (orderId == null) {
            log.error("(handleSuccessPayment)order is null from paypal service");
            Optional<Payment> paymentOptional = slavePaymentRepo.findByToken(token);
            if (paymentOptional.isEmpty()) {
                return;
            }
            handleFailedPayment(paymentOptional.get().getOrderId());
            return;
        }

        Optional<Payment> paymentOptional = slavePaymentRepo.findByOrderId(orderId);

        if (paymentOptional.isEmpty()) {
            log.error("(handleSuccessPayment)payment not found for order: {}", orderId);
            return;
        }

        Payment payment = paymentOptional.get();
        payment.setStatus(PaymentStatus.SUCCESS);
        payment.setCaptureId(paypalCaptureResponse.getPurchaseUnits().get(0).getPayments().getCaptures().get(0).getId());

        PaymentSuccess paymentSuccess = PaymentSuccess.newBuilder()
                .setOrderId(orderId)
                .build();

        MongoSavedEvent mongoSavedEvent = new MongoSavedEvent(
                this,
                EcommerceEvent.PAYMENT_SUCCESS.getValue(),
                paymentSuccess
        );
        eventPublisher.publishEvent(mongoSavedEvent);
    }

    @Override
    @Transactional
    public void handleCancelPayment(String token) {
        log.info("(handle paypal cancel)token: {}", token);
        String orderId;
        try {
            PaypalOrderDetail paypalOrderDetail = paypalService.getOrderDetails(token);
            orderId = paypalOrderDetail.getPurchaseUnits().get(0).getCustomId();
        } catch (PaypalRestTemplateException | IndexOutOfBoundsException | NullPointerException e) {
            log.error("(handleCancelPayment)paypal failure for token: {}", token, e);
            Optional<Payment> paymentOptional = slavePaymentRepo.findByToken(token);
            if (paymentOptional.isEmpty()) {
                return;
            }
            handleFailedPayment(paymentOptional.get().getOrderId());
            return;
        }

        if (orderId == null) {
            log.error("(handleCancelPayment)order is null from paypal service");
            Optional<Payment> paymentOptional = slavePaymentRepo.findByToken(token);
            if (paymentOptional.isEmpty()) {
                return;
            }
            handleFailedPayment(paymentOptional.get().getOrderId());
            return;
        }

        PaymentCanceled paymentCanceled = PaymentCanceled.newBuilder()
                .setOrderId(orderId)
                .build();

        MongoSavedEvent mongoSavedEvent = new MongoSavedEvent(
                this, EcommerceEvent.PAYMENT_CANCELED.getValue(), paymentCanceled);

        eventPublisher.publishEvent(mongoSavedEvent);
    }

    private void handleFailedPayment(String orderId) {
        masterPaymentRepo.updateStatus(orderId, PaymentStatus.FAILED);

        PaymentFailed paymentFailed = PaymentFailed.newBuilder()
                .setOrderId(orderId)
                .build();

        MongoSavedEvent mongoSavedEvent = new MongoSavedEvent(
                this,
                EcommerceEvent.PAYMENT_FAILED.getValue(),
                paymentFailed
        );
        eventPublisher.publishEvent(mongoSavedEvent);
    }
}
