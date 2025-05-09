package org.aibles.order_service.controller;

import jakarta.validation.Valid;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.order_service.dto.request.OrderRequest;
import org.aibles.order_service.service.OrderService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@Slf4j
@RestController
@RequestMapping("/v1/orders")
public class OrderController {

    private final OrderService orderService;

    public OrderController(OrderService orderService) {
        this.orderService = orderService;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public BaseResponse create(@RequestHeader("X-User-Id") String userId, @RequestBody @Valid OrderRequest request) {
        log.info("(create)request : {}", request);
        var response = orderService.create(userId, request);
        return BaseResponse.created(response);
    }
}
