package org.aibles.payment_service.service;

import org.aibles.ecommerce.core_order_cache.repository.PendingOrderCacheRepository;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalCaptureResponse;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderDetail;
import org.aibles.ecommerce.core_paypal.dto.paypal.PaypalOrderSimple;
import org.aibles.ecommerce.core_paypal.service.PaypalService;
import org.aibles.payment_service.entity.Payment;
import org.aibles.payment_service.repository.master.MasterPaymentRepo;
import org.aibles.payment_service.repository.slave.SlavePaymentRepo;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.RETURNS_DEEP_STUBS;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class PaymentServiceImplTest {

    private PaypalService paypalService;
    private PendingOrderCacheRepository pendingOrderCacheRepository;
    private MasterPaymentRepo masterPaymentRepo;
    private SlavePaymentRepo slavePaymentRepo;
    private PaymentRecorder paymentRecorder;
    private PaymentService sut;

    @BeforeEach
    void setUp() {
        paypalService = mock(PaypalService.class);
        pendingOrderCacheRepository = mock(PendingOrderCacheRepository.class);
        masterPaymentRepo = mock(MasterPaymentRepo.class);
        slavePaymentRepo = mock(SlavePaymentRepo.class);
        paymentRecorder = mock(PaymentRecorder.class);
        sut = new PaymentServiceImpl(paypalService, pendingOrderCacheRepository,
                masterPaymentRepo, slavePaymentRepo, paymentRecorder);
    }

    @Test
    void purchase_callsPaypalThenRecords() {
        when(pendingOrderCacheRepository.getOrderPrice("o-1")).thenReturn(Optional.of(99.0));
        PaypalOrderSimple order = new PaypalOrderSimple();
        order.setId("tok-1");
        when(paypalService.createOrder(anyList())).thenReturn(order);

        sut.purchase("o-1");

        InOrder inOrder = inOrder(paypalService, paymentRecorder);
        inOrder.verify(paypalService).createOrder(anyList());
        inOrder.verify(paymentRecorder).recordPurchase("o-1", 99.0, "tok-1");
        verifyNoInteractions(masterPaymentRepo); // impl no longer writes directly
    }

    @Test
    void handleSuccessPayment_capturesThenRecordsSuccess() {
        PaypalCaptureResponse capture = mock(PaypalCaptureResponse.class, RETURNS_DEEP_STUBS);
        when(capture.getPurchaseUnits().get(0).getPayments().getCaptures().get(0).getId())
                .thenReturn("cap-1");
        when(paypalService.captureOrder("tok-1")).thenReturn(capture);
        PaypalOrderDetail detail = mock(PaypalOrderDetail.class, RETURNS_DEEP_STUBS);
        when(detail.getPurchaseUnits().get(0).getCustomId()).thenReturn("o-1");
        when(paypalService.getOrderDetails("tok-1")).thenReturn(detail);
        when(masterPaymentRepo.findByOrderId("o-1"))
                .thenReturn(Optional.of(Payment.builder().orderId("o-1").build()));

        String orderId = sut.handleSuccessPayment("tok-1");

        assertEquals("o-1", orderId);
        verify(paymentRecorder).recordSuccess("o-1", "cap-1");
    }
}
