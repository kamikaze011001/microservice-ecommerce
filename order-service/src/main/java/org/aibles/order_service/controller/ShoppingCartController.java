package org.aibles.order_service.controller;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.order_service.dto.request.ShoppingCartAddRequest;
import org.aibles.order_service.dto.request.ShoppingCartUpdateRequest;
import org.aibles.order_service.dto.response.ShoppingCartListResponse;
import org.aibles.order_service.service.ShoppingCartService;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/v1")
@RequiredArgsConstructor
public class ShoppingCartController {

    private final ShoppingCartService shoppingCartService;

    @PostMapping("/shopping-carts:add-item")
    public BaseResponse addItem(@RequestHeader("X-User-Id") String userId,
                                @RequestBody @Valid ShoppingCartAddRequest request) {
        shoppingCartService.addItem(userId, request);
        return BaseResponse.ok();
    }

    @GetMapping("/shopping-carts")
    public BaseResponse getShoppingCarts(@RequestHeader("X-User-Id") String userId) {
        ShoppingCartListResponse response = shoppingCartService.list(userId);
        return BaseResponse.ok(response);
    }

    @PatchMapping("/shopping-carts:update-item")
    public BaseResponse updateItem(@RequestBody @Valid ShoppingCartUpdateRequest request) {
        shoppingCartService.updateItem(request.getShoppingCartItemId(), request.getQuantity());
        return BaseResponse.ok();
    }

    @DeleteMapping("/shopping-carts:delete-item")
    public BaseResponse deleteItem(@RequestParam("itemId") String itemId) {
        shoppingCartService.deleteItem(itemId);
        return BaseResponse.ok();
    }
}
