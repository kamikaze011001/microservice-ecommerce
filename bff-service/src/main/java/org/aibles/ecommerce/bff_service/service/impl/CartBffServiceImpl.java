package org.aibles.ecommerce.bff_service.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.bff_service.client.OrderFeignClient;
import org.aibles.ecommerce.bff_service.client.ProductFeignClient;
import org.aibles.ecommerce.bff_service.dto.response.CartItemView;
import org.aibles.ecommerce.bff_service.dto.response.CartView;
import org.aibles.ecommerce.bff_service.service.CartBffService;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.inventory.grpc.InventoryProduct;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

@Slf4j
public class CartBffServiceImpl implements CartBffService {

    private final OrderFeignClient orderFeignClient;
    private final ProductFeignClient productFeignClient;
    private final InventoryGrpcClientService inventoryGrpcClientService;

    public CartBffServiceImpl(OrderFeignClient orderFeignClient,
                              ProductFeignClient productFeignClient,
                              InventoryGrpcClientService inventoryGrpcClientService) {
        this.orderFeignClient = orderFeignClient;
        this.productFeignClient = productFeignClient;
        this.inventoryGrpcClientService = inventoryGrpcClientService;
    }

    @Override
    @SuppressWarnings("unchecked")
    public CartView getCart(String userId) {
        log.info("(getCart) userId: {}", userId);

        BaseResponse cartResp = orderFeignClient.getCart(userId);
        Map<String, Object> cartData = (Map<String, Object>) cartResp.getData();
        List<Map<String, Object>> rawRows = (List<Map<String, Object>>) cartData.getOrDefault("shoppingCarts", Collections.emptyList());

        if (rawRows.isEmpty()) {
            return CartView.builder()
                    .shoppingCartId("cart-" + userId)
                    .userId(userId)
                    .items(List.of())
                    .build();
        }

        Set<String> productIds = rawRows.stream()
                .map(r -> (String) r.get("productId"))
                .filter(java.util.Objects::nonNull)
                .collect(Collectors.toSet());

        Map<String, Map<String, Object>> productById = new HashMap<>();
        BaseResponse prodResp = productFeignClient.listByIds(productIds);
        List<Map<String, Object>> products = (List<Map<String, Object>>) prodResp.getData();
        if (products != null) {
            for (Map<String, Object> p : products) {
                productById.put((String) p.get("id"), p);
            }
        }

        Map<String, Long> stockById = new HashMap<>();
        for (InventoryProduct inv : inventoryGrpcClientService.fetchInventory(new ArrayList<>(productIds)).getInventoryProductsList()) {
            stockById.put(inv.getId(), inv.getQuantity());
        }

        List<CartItemView> items = new ArrayList<>();
        for (Map<String, Object> row : rawRows) {
            String productId = (String) row.get("productId");
            Map<String, Object> product = productById.get(productId);
            if (product == null) {
                log.warn("(getCart) product {} missing — dropping cart row {}", productId, row.get("id"));
                continue;
            }
            Object priceObj = row.get("price");
            Object qtyObj = row.get("quantity");
            items.add(CartItemView.builder()
                    .shoppingCartItemId((String) row.get("id"))
                    .productId(productId)
                    .name((String) product.get("name"))
                    .imageUrl((String) product.get("imageUrl"))
                    .unitPrice(priceObj != null ? ((Number) priceObj).doubleValue() : null)
                    .quantity(qtyObj != null ? ((Number) qtyObj).longValue() : 0L)
                    .availableStock(stockById.getOrDefault(productId, 0L))
                    .build());
        }

        return CartView.builder()
                .shoppingCartId("cart-" + userId)
                .userId(userId)
                .items(items)
                .build();
    }

    @Override
    public BaseResponse addItem(String userId, Map<String, Object> body) {
        log.info("(addItem) userId: {}, body: {}", userId, body);
        return orderFeignClient.addCartItem(userId, body);
    }

    @Override
    public BaseResponse updateItem(Map<String, Object> body) {
        log.info("(updateItem) body: {}", body);
        return orderFeignClient.updateCartItem(body);
    }

    @Override
    public BaseResponse deleteItem(String itemId) {
        log.info("(deleteItem) itemId: {}", itemId);
        return orderFeignClient.deleteCartItem(itemId);
    }
}
