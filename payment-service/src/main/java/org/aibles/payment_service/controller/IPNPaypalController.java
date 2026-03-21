package org.aibles.payment_service.controller;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.payment_service.service.PaymentService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@Slf4j
@RestController
@RequestMapping("/v1")
public class IPNPaypalController {

    private final PaymentService paymentService;

    public IPNPaypalController(PaymentService paymentService) {
        this.paymentService = paymentService;
    }

    @ResponseStatus(HttpStatus.OK)
    @GetMapping("/paypal:success")
    public void ipnSuccess(@RequestParam("token") String token) {
        log.info("IPN PayPal success");
        paymentService.handleSuccessPayment(token);
    }

    @ResponseStatus(HttpStatus.OK)
    @GetMapping("/paypal:cancel")
    public void ipnCancel(@RequestParam("token") String token) {
        log.info("IPN PayPal cancel");
        paymentService.handleCancelPayment(token);
    }
}
