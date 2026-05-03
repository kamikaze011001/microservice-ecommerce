package org.aibles.payment_service.controller;

import java.net.URI;
import lombok.extern.slf4j.Slf4j;
import org.aibles.payment_service.service.PaymentService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@Slf4j
@RestController
@RequestMapping("/v1")
public class IPNPaypalController {

    private final PaymentService paymentService;
    private final String frontendBaseUrl;

    public IPNPaypalController(
            PaymentService paymentService,
            @Value("${application.frontend.base-url}") String frontendBaseUrl) {
        this.paymentService = paymentService;
        this.frontendBaseUrl = frontendBaseUrl;
    }

    @GetMapping("/paypal:success")
    public ResponseEntity<Void> ipnSuccess(@RequestParam("token") String token) {
        log.info("IPN PayPal success token={}", token);
        String orderId = paymentService.handleSuccessPayment(token);
        if (orderId == null) {
            log.warn("PayPal {} had no resolvable orderId for token={}", "success", token);
        }
        String suffix = orderId == null ? "" : "?orderId=" + orderId;
        URI location = URI.create(frontendBaseUrl + "/payment/success" + suffix);
        return ResponseEntity.status(HttpStatus.FOUND).location(location).build();
    }

    @GetMapping("/paypal:cancel")
    public ResponseEntity<Void> ipnCancel(@RequestParam("token") String token) {
        log.info("IPN PayPal cancel token={}", token);
        String orderId = paymentService.handleCancelPayment(token);
        if (orderId == null) {
            log.warn("PayPal {} had no resolvable orderId for token={}", "cancel", token);
        }
        String suffix = orderId == null ? "" : "?orderId=" + orderId;
        URI location = URI.create(frontendBaseUrl + "/payment/cancel" + suffix);
        return ResponseEntity.status(HttpStatus.FOUND).location(location).build();
    }
}
