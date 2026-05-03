package org.aibles.payment_service.controller;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.payment_service.dto.PaymentResponse;
import org.aibles.payment_service.service.PaymentService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/v1/payments")
@Slf4j
public class PaymentController {

    private final PaymentService paymentService;

    public PaymentController(PaymentService paymentService) {
        this.paymentService = paymentService;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse purchase(@RequestParam("orderId") String orderId) {
        log.info("(purchase)orderId: {}", orderId);
        return paymentService.purchase(orderId);
    }

    @GetMapping("/by-order/{orderId}")
    @ResponseStatus(HttpStatus.OK)
    public PaymentResponse getByOrderId(@PathVariable("orderId") String orderId) {
        log.info("(getByOrderId)orderId: {}", orderId);
        return paymentService.getByOrderId(orderId);
    }
}
