package org.aibles.ecommerce.bff_service.client;

import org.aibles.ecommerce.bff_service.dto.response.PaymentView;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;

@FeignClient(name = "payment-service")
public interface PaymentFeignClient {

    @GetMapping("/payment-service/v1/payments/by-order/{orderId}")
    PaymentView byOrderId(@PathVariable("orderId") String orderId);
}
