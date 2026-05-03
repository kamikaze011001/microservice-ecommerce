package org.aibles.ecommerce.bff_service.client;

import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;

import java.util.Map;

@FeignClient(name = "order-service")
public interface OrderFeignClient {

    @GetMapping("/v1/orders/{orderId}")
    BaseResponse getOrder(@RequestHeader("X-User-Id") String userId,
                          @PathVariable("orderId") String orderId);

    @GetMapping("/v1/shopping-carts")
    BaseResponse getCart(@RequestHeader("X-User-Id") String userId);

    @PostMapping("/v1/shopping-carts:add-item")
    BaseResponse addCartItem(@RequestHeader("X-User-Id") String userId,
                             @RequestBody Map<String, Object> body);

    @PatchMapping("/v1/shopping-carts:update-item")
    BaseResponse updateCartItem(@RequestBody Map<String, Object> body);

    @DeleteMapping("/v1/shopping-carts:delete-item")
    BaseResponse deleteCartItem(@RequestParam("itemId") String itemId);
}
