package org.aibles.payment_service.service;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_paypal.dto.CreatePaypalOrderRequest;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalCaptureResponse;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderDetail;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderSimple;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalRestTemplateException;
import org.aibles.ecommerce.core_paypal.service.PaypalService;
import org.aibles.payment_service.dto.PaymentResponse;
import org.aibles.payment_service.entity.Payment;
import org.aibles.payment_service.exception.OrderInvalidException;
import org.aibles.payment_service.repository.master.MasterPaymentRepo;
import org.aibles.payment_service.repository.slave.SlavePaymentRepo;
import org.springframework.web.client.ResourceAccessException;

import java.util.List;
import java.util.Optional;

/**
 * Call-then-record: PayPal HTTP calls run OUTSIDE any transaction (a ~1.3s
 * HTTP call inside a JTA tx held Atomikos slots and saturated maxActives=50 —
 * stress run 2026-06-10). All DB writes + their events go through
 * {@link PaymentRecorder}'s short @Transactional methods. Do NOT add
 * @Transactional here — TransactionBoundaryTest guards this.
 */
@Slf4j
public class PaymentServiceImpl implements PaymentService {

    private final PaypalService paypalService;

    private final PendingOrderCacheRepository pendingOrderCacheRepository;

    private final MasterPaymentRepo masterPaymentRepo;

    private final SlavePaymentRepo slavePaymentRepo;

    private final PaymentRecorder paymentRecorder;

    public PaymentServiceImpl(PaypalService paypalService, PendingOrderCacheRepository pendingOrderCacheRepository, MasterPaymentRepo masterPaymentRepo, SlavePaymentRepo slavePaymentRepo, PaymentRecorder paymentRecorder) {
        this.paypalService = paypalService;
        this.pendingOrderCacheRepository = pendingOrderCacheRepository;
        this.masterPaymentRepo = masterPaymentRepo;
        this.slavePaymentRepo = slavePaymentRepo;
        this.paymentRecorder = paymentRecorder;
    }

    @Override
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
            paymentRecorder.recordFailure(orderId);
            return BaseResponse.from(e.getStatus(), e.getCode(), e.getMessage());
        } catch (ResourceAccessException e) {
            // Connect/read timeout — the error handler never ran (no response arrived)
            log.error("(purchase)paypal unreachable for orderId: {}", orderId, e);
            paymentRecorder.recordFailure(orderId);
            return BaseResponse.from(504, "PAYPAL_UNREACHABLE", e.getMessage());
        }

        paymentRecorder.recordPurchase(orderId, totalPrice, paypalOrderSimple.getId());

        return BaseResponse.ok(paypalOrderSimple);
    }

    @Override
    public String handleSuccessPayment(String token) {
        log.info("(handle paypal success)token: {}", token);
        String orderId;
        PaypalCaptureResponse paypalCaptureResponse;
        try {
            paypalCaptureResponse = paypalService.captureOrder(token);
            PaypalOrderDetail paypalOrderDetail = paypalService.getOrderDetails(token);
            orderId = paypalOrderDetail.getPurchaseUnits().get(0).getCustomId();
        } catch (PaypalRestTemplateException | ResourceAccessException | IndexOutOfBoundsException | NullPointerException e) {
            log.error("(handleSuccessPayment)paypal failure for token: {}", token, e);
            Optional<Payment> paymentOptional = masterPaymentRepo.findByToken(token);
            if (paymentOptional.isEmpty()) {
                return null;
            }
            paymentRecorder.recordFailure(paymentOptional.get().getOrderId());
            return paymentOptional.get().getOrderId();
        }

        log.info("(handle paypal success)orderId: {}", orderId);

        if (orderId == null) {
            log.error("(handleSuccessPayment)order is null from paypal service");
            Optional<Payment> paymentOptional = masterPaymentRepo.findByToken(token);
            if (paymentOptional.isEmpty()) {
                return null;
            }
            paymentRecorder.recordFailure(paymentOptional.get().getOrderId());
            return paymentOptional.get().getOrderId();
        }

        Optional<Payment> paymentOptional = masterPaymentRepo.findByOrderId(orderId);

        if (paymentOptional.isEmpty()) {
            log.error("(handleSuccessPayment)payment not found for order: {}", orderId);
            return orderId;
        }

        Payment payment = paymentOptional.get();
        String captureId = paypalCaptureResponse.getPurchaseUnits().get(0).getPayments().getCaptures().get(0).getId();
        paymentRecorder.recordSuccess(payment.getOrderId(), captureId);
        return orderId;
    }

    @Override
    public String handleCancelPayment(String token) {
        log.info("(handle paypal cancel)token: {}", token);
        String orderId;
        try {
            PaypalOrderDetail paypalOrderDetail = paypalService.getOrderDetails(token);
            orderId = paypalOrderDetail.getPurchaseUnits().get(0).getCustomId();
        } catch (PaypalRestTemplateException | ResourceAccessException | IndexOutOfBoundsException | NullPointerException e) {
            log.error("(handleCancelPayment)paypal failure for token: {}", token, e);
            Optional<Payment> paymentOptional = masterPaymentRepo.findByToken(token);
            if (paymentOptional.isEmpty()) {
                return null;
            }
            paymentRecorder.recordFailure(paymentOptional.get().getOrderId());
            return paymentOptional.get().getOrderId();
        }

        if (orderId == null) {
            log.error("(handleCancelPayment)order is null from paypal service");
            Optional<Payment> paymentOptional = masterPaymentRepo.findByToken(token);
            if (paymentOptional.isEmpty()) {
                return null;
            }
            paymentRecorder.recordFailure(paymentOptional.get().getOrderId());
            return paymentOptional.get().getOrderId();
        }

        paymentRecorder.recordCancel(orderId);
        return orderId;
    }

    @Override
    public PaymentResponse getByOrderId(String orderId) {
        log.info("(getByOrderId) orderId: {}", orderId);
        return slavePaymentRepo.findByOrderId(orderId)
                .map(PaymentResponse::from)
                .orElse(null);
    }
}
