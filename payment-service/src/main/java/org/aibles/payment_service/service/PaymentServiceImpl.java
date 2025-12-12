package org.aibles.payment_service.service;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentCanceled;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentFailed;
import org.aibles.ecommerce.common_dto.avro_kafka.PaymentSuccess;
import org.aibles.ecommerce.common_dto.event.EcommerceEvent;
import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.core_paypal.dto.CreatePaypalOrderRequest;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalCaptureResponse;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderDetail;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderSimple;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalRestTemplateException;
import org.aibles.ecommerce.core_paypal.service.PaypalService;
import org.aibles.ecommerce.core_redis.constant.RedisConstant;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.aibles.payment_service.constant.PaymentStatus;
import org.aibles.payment_service.constant.PaymentType;
import org.aibles.payment_service.entity.Payment;
import org.aibles.payment_service.exception.OrderInvalidException;
import org.aibles.payment_service.repository.master.MasterPaymentRepo;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Slf4j
public class PaymentServiceImpl implements PaymentService {

    private final PaypalService paypalService;

    private final RedisRepository redisRepository;

    private final MasterPaymentRepo masterPaymentRepo;

    private final ApplicationEventPublisher eventPublisher;

    public PaymentServiceImpl(PaypalService paypalService, RedisRepository redisRepository, MasterPaymentRepo masterPaymentRepo, ApplicationEventPublisher eventPublisher) {
        this.paypalService = paypalService;
        this.redisRepository = redisRepository;
        this.masterPaymentRepo = masterPaymentRepo;
        this.eventPublisher = eventPublisher;
    }

    @Override
    @Transactional
    public BaseResponse purchase(String orderId) {
        log.info("(purchase)orderId: {}", orderId);
        double totalPrice = redisRepository.getOrderPrice(orderId).orElse(0.0);

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
        try {
            paypalService.captureOrder(token);
            PaypalOrderDetail paypalOrderDetail = paypalService.getOrderDetails(token);
            orderId = paypalOrderDetail.getPurchaseUnits().get(0).getCustomId();
        } catch (PaypalRestTemplateException | IndexOutOfBoundsException | NullPointerException e) {
            log.error("(handle paypal failure)token: {}", token, e);
            return;
        }

        log.info("(handle paypal success)orderId: {}", orderId);

        masterPaymentRepo.updateStatus(orderId, PaymentStatus.SUCCESS);

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
            log.error("(handle paypal failure)token: {}", token, e);
            return;
        }

        masterPaymentRepo.updateStatus(orderId, PaymentStatus.CANCELED);

        PaymentCanceled paymentCanceled = PaymentCanceled.newBuilder()
                .setOrderId(orderId)
                .build();

        MongoSavedEvent mongoSavedEvent = new MongoSavedEvent(
                this, EcommerceEvent.PAYMENT_CANCELED.getValue(), paymentCanceled);

        eventPublisher.publishEvent(mongoSavedEvent);
    }
}
