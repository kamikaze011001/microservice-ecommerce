package org.aibles.ecommerce.bff_service.controller;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.bff_service.service.CartBffService;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@Slf4j
@RestController
@RequestMapping("/v1/cart")
public class CartController {

    private final CartBffService cartBffService;

    public CartController(CartBffService cartBffService) {
        this.cartBffService = cartBffService;
    }

    @GetMapping
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse getCart(@RequestHeader("X-User-Id") String userId) {
        log.info("(getCart) userId: {}", userId);
        return BaseResponse.ok(cartBffService.getCart(userId));
    }

    @PostMapping(":add-item")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse addItem(@RequestHeader("X-User-Id") String userId,
                                @RequestBody Map<String, Object> body) {
        log.info("(addItem) userId: {}", userId);
        return cartBffService.addItem(userId, body);
    }

    @PatchMapping(":update-item")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse updateItem(@RequestBody Map<String, Object> body) {
        log.info("(updateItem)");
        return cartBffService.updateItem(body);
    }

    @DeleteMapping(":delete-item")
    @ResponseStatus(HttpStatus.OK)
    public BaseResponse deleteItem(@RequestParam("itemId") String itemId) {
        log.info("(deleteItem) itemId: {}", itemId);
        return cartBffService.deleteItem(itemId);
    }
}
