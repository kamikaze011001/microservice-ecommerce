package org.aibles.ecommerce.bff_service.controller;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.bff_service.service.BffService;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@Slf4j
@RestController
public class BffController {

    private final BffService bffService;

    public BffController(BffService bffService) {
        this.bffService = bffService;
    }

    @GetMapping("/v1/products/{productId}")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse getProductDetail(@PathVariable String productId) {
        log.info("(getProductDetail) productId: {}", productId);
        return BaseResponse.ok(bffService.getProductDetail(productId));
    }

    @GetMapping("/v1/orders/{orderId}")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse getOrderDetail(@RequestHeader("X-User-Id") String userId,
                                       @PathVariable String orderId) {
        log.info("(getOrderDetail) userId: {}, orderId: {}", userId, orderId);
        return BaseResponse.ok(bffService.getOrderDetail(userId, orderId));
    }
}
