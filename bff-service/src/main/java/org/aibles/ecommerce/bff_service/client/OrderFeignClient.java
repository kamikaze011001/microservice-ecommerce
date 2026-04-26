package org.aibles.ecommerce.bff_service.client;

import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestHeader;

@FeignClient(name = "order-service")
public interface OrderFeignClient {

    @GetMapping("/v1/orders/{orderId}")
    BaseResponse getOrder(@RequestHeader("X-User-Id") String userId,
                          @PathVariable("orderId") String orderId);
}
